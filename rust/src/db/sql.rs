//! 通用 SQL 执行层（第一层）。
//!
//! 不感知业务实体、不建表、不做 schema 映射。Dart 第二层传入原始 SQL +
//! JSON 参数数组，这里只负责：
//! - 主连接上的同步 SQL 执行（查询返回 JSON 数组）；
//! - 显式事务连接（`BEGIN IMMEDIATE` / `BEGIN`），支持异步调用之间的事务隔离；
//! - `update_hook` 表级变更通知，主连接和所有事务连接共享同一个 ChangeBus。
//!
//! 为什么事务要独立连接：Dart 侧全部异步，`begin` 与 `commit` 之间可能插入
//! 其他调用。如果共用主连接，别的语句会意外加入当前事务。独立连接让事务
//! 拥有自己的 SQLite 连接和锁，其他业务继续走主连接。
//!
//! SQLite 使用 `rusqlite` 的 `bundled` 特性，源码随 crate 编译；不链接系统
//! 预装的 sqlite3 动态库。

use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicBool, AtomicI64, Ordering};
use std::sync::{Arc, LazyLock, Mutex, MutexGuard};

use anyhow::{Context, Result, anyhow, bail};
use base64::Engine;
use rusqlite::hooks::Action;
use rusqlite::types::ValueRef;
use rusqlite::{Connection, params_from_iter};
use serde_json::{Map, Number, Value, json};

pub type ChangeListener = Box<dyn Fn(Vec<String>) + Send + Sync>;

static NEXT_HANDLE: AtomicI64 = AtomicI64::new(1);
static REGISTRY: LazyLock<Mutex<HashMap<i64, Arc<DbHandle>>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

/// 事务提交后把去重后的表名广播给所有观察者。
#[derive(Default)]
pub struct ChangeBus {
    listeners: Mutex<Vec<ChangeListener>>,
}

impl ChangeBus {
    pub fn add_listener(&self, listener: ChangeListener) {
        if let Ok(mut listeners) = self.listeners.lock() {
            listeners.push(listener);
        }
    }

    fn publish(&self, tables: Vec<String>) {
        if tables.is_empty() {
            return;
        }
        let listeners = match self.listeners.lock() {
            Ok(listeners) => listeners,
            Err(_) => return,
        };
        for listener in listeners.iter() {
            listener(tables.clone());
        }
    }
}

enum HandleKind {
    Main,
    Tx { finished: AtomicBool },
}

pub struct DbHandle {
    pub id: i64,
    pub path: String,
    pub bus: Arc<ChangeBus>,
    conn: Mutex<Connection>,
    pending: Arc<Mutex<HashSet<String>>>,
    kind: HandleKind,
}

impl DbHandle {
    fn open_main(id: i64, path: &str) -> Result<Self> {
        let bus = Arc::new(ChangeBus::default());
        let (conn, pending) = open_connection(path, false)?;
        // auto_vacuum / journal_mode 是写进数据库头的库级设置，主连接
        // 打开时执行一次即可；事务连接不必每次建连都再检查一遍。
        conn.execute_batch(
            "PRAGMA auto_vacuum=INCREMENTAL;
             PRAGMA journal_mode=WAL;",
        )
        .context("configure SQLite database")?;
        Ok(Self {
            id,
            path: path.to_string(),
            bus,
            conn: Mutex::new(conn),
            pending,
            kind: HandleKind::Main,
        })
    }

    fn open_tx(id: i64, main: &DbHandle, write: bool) -> Result<Self> {
        // 只读事务连接启用 query_only：误写会在语句执行时直接报错，
        // 不会悄悄升级成写事务再撞 SQLITE_BUSY。
        let (conn, pending) = open_connection(&main.path, !write)?;
        {
            let conn = &conn;
            // 只读事务保持 DEFERRED：快照在第一条真实读语句时建立，
            // 不提前占住读锁、不阻塞 WAL checkpoint。
            conn.execute_batch(if write { "BEGIN IMMEDIATE" } else { "BEGIN" })
                .context("begin SQLite transaction")?;
        }
        Ok(Self {
            id,
            path: main.path.clone(),
            bus: main.bus.clone(),
            conn: Mutex::new(conn),
            pending,
            kind: HandleKind::Tx {
                finished: AtomicBool::new(false),
            },
        })
    }

    pub fn query_json(&self, sql: &str, params_json: &str) -> Result<String> {
        let params = parse_params(params_json)?;
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn
            .prepare_cached(sql)
            .with_context(|| format!("prepare SQL: {sql}"))?;
        let mut rows = stmt
            .query(params_from_iter(params.iter()))
            .with_context(|| format!("execute query: {sql}"))?;
        let mut out = Vec::new();
        // 缓存的语句在 schema 变化后由 SQLite 在第一次 step 时自动重编译；
        // 列名必须在这之后读取，否则 `SELECT *` 可能沿用旧列集合。
        let mut names: Option<Vec<String>> = None;
        while let Some(row) = rows.next()? {
            let stmt = row.as_ref();
            if names.is_none() {
                names = Some(
                    (0..stmt.column_count())
                        .map(|i| stmt.column_name(i).map(str::to_owned).unwrap_or_default())
                        .collect(),
                );
            }
            let names = names.as_ref().expect("column names initialized");
            let mut map = Map::new();
            for (i, name) in names.iter().enumerate() {
                map.insert(name.clone(), sql_value_to_json(row.get_ref(i)?));
            }
            out.push(Value::Object(map));
        }
        Ok(serde_json::to_string(&out)?)
    }

    /// 执行单条语句。返回 `{"changes": n, "lastInsertId": id}`。
    pub fn execute(&self, sql: &str, params_json: &str) -> Result<String> {
        let params = parse_params(params_json)?;
        let (changes, last_id) = {
            let conn = self.conn.lock().unwrap();
            let mut stmt = conn
                .prepare_cached(sql)
                .with_context(|| format!("prepare SQL: {sql}"))?;
            let changes = stmt
                .execute(params_from_iter(params.iter()))
                .with_context(|| format!("execute SQL: {sql}"))?;
            (changes, conn.last_insert_rowid())
        };
        self.after_statement();
        Ok(json!({ "changes": changes, "lastInsertId": last_id }).to_string())
    }

    /// 执行多条语句（DDL / 迁移脚本），不返回结果集。
    pub fn execute_script(&self, sql: &str) -> Result<()> {
        {
            let conn = self.conn.lock().unwrap();
            conn.execute_batch(sql)
                .with_context(|| format!("execute SQL script: {sql}"))?;
        }
        self.after_statement();
        Ok(())
    }

    fn after_statement(&self) {
        // 只有主连接是 autocommit，执行成功即可发布；事务连接等 commit。
        if matches!(&self.kind, HandleKind::Main) {
            self.publish_pending();
        }
    }

    fn publish_pending(&self) {
        let tables = take_pending(&self.pending);
        if !tables.is_empty() {
            self.bus.publish(tables);
        }
    }

    fn discard_pending(&self) {
        if let Ok(mut pending) = self.pending.lock() {
            pending.clear();
        }
    }

    pub fn commit(&self) -> Result<()> {
        let HandleKind::Tx { finished } = &self.kind else {
            bail!("handle {} is not a transaction", self.id);
        };
        if finished.swap(true, Ordering::SeqCst) {
            bail!("transaction {} already finished", self.id);
        }
        let result = {
            let conn = self.conn.lock().unwrap();
            conn.execute_batch("COMMIT")
                .context("commit SQLite transaction")
        };
        match result {
            Ok(()) => {
                self.publish_pending();
                Ok(())
            }
            Err(error) => {
                // COMMIT 失败时事务可能仍然开着；立刻回滚，避免连接和
                // WAL 快照泄漏。句柄随后由 registry 移除。
                let _ = self.conn.lock().unwrap().execute_batch("ROLLBACK");
                self.discard_pending();
                Err(error)
            }
        }
    }

    pub fn rollback(&self) -> Result<()> {
        let HandleKind::Tx { finished } = &self.kind else {
            bail!("handle {} is not a transaction", self.id);
        };
        if finished.swap(true, Ordering::SeqCst) {
            return Ok(());
        }
        {
            let conn = self.conn.lock().unwrap();
            let _ = conn.execute_batch("ROLLBACK");
        }
        self.discard_pending();
        Ok(())
    }

    pub fn close(&self) -> Result<()> {
        if matches!(&self.kind, HandleKind::Tx { .. }) {
            self.rollback()?;
        } else {
            let conn = self.conn.lock().unwrap();
            // 关闭前刷新查询规划器统计信息；analysis_limit 限制单表采样量，
            // 避免大表拖慢退出。失败不影响关闭。
            let _ = conn.execute_batch("PRAGMA analysis_limit=400; PRAGMA optimize;");
            let _ = conn.execute_batch("PRAGMA wal_checkpoint(TRUNCATE);");
        }
        Ok(())
    }
}

fn open_connection(
    path: &str,
    read_only: bool,
) -> Result<(Connection, Arc<Mutex<HashSet<String>>>)> {
    let mut conn = Connection::open(path).with_context(|| format!("open SQLite {path}"))?;
    conn.busy_timeout(std::time::Duration::from_secs(5))?;
    conn.execute_batch(
        "PRAGMA synchronous=NORMAL;
         PRAGMA foreign_keys=ON;
         PRAGMA temp_store=MEMORY;
         PRAGMA cache_size=-8000;",
    )
    .context("configure SQLite pragmas")?;
    if read_only {
        // 在引擎层禁止写入；只读事务不应存在锁升级路径。
        conn.execute_batch("PRAGMA query_only=ON;")
            .context("configure read-only SQLite pragmas")?;
    }
    // 仓库 SQL 形态固定，默认 16 条缓存不够用；配合 prepare_cached 避免
    // 高频语句每次重新解析。
    conn.set_prepared_statement_cache_capacity(64);

    let pending = Arc::new(Mutex::new(HashSet::new()));
    if !read_only {
        // 只读连接不会有写操作，不需要注册 hook。
        let sink = pending.clone();
        conn.update_hook(Some(
            move |action: Action, _db: &str, table: &str, _rowid: i64| {
                if !matches!(
                    action,
                    Action::SQLITE_INSERT | Action::SQLITE_UPDATE | Action::SQLITE_DELETE
                ) {
                    return;
                }
                // hook 在 SQLite 执行线程内同步调用：只入队，绝不查询/等待。
                // 批量写入时同一张表会被回调上万次，先查后插避免重复分配。
                if let Ok(mut buf) = sink.lock() {
                    if !buf.contains(table) {
                        buf.insert(table.to_owned());
                    }
                }
            },
        ))?;
    }
    Ok((conn, pending))
}

fn take_pending(pending: &Arc<Mutex<HashSet<String>>>) -> Vec<String> {
    let mut pending = match pending.lock() {
        Ok(pending) => pending,
        Err(_) => return Vec::new(),
    };
    let mut tables: Vec<String> = pending.drain().collect();
    tables.sort();
    tables
}

fn parse_params(params_json: &str) -> Result<Vec<rusqlite::types::Value>> {
    let text = params_json.trim();
    if text.is_empty() || text == "null" {
        return Ok(Vec::new());
    }
    let value: Value = serde_json::from_str(text).context("parse SQL params JSON")?;
    let Value::Array(values) = value else {
        bail!("SQL params must be a JSON array");
    };
    values.iter().map(json_to_sql).collect()
}

fn json_to_sql(value: &Value) -> Result<rusqlite::types::Value> {
    use rusqlite::types::Value as SqlValue;
    Ok(match value {
        Value::Null => SqlValue::Null,
        Value::Bool(v) => SqlValue::Integer(i64::from(*v)),
        Value::Number(n) => {
            if let Some(v) = n.as_i64() {
                SqlValue::Integer(v)
            } else if let Some(v) = n.as_f64() {
                SqlValue::Real(v)
            } else {
                bail!("unsupported number in SQL params: {n}");
            }
        }
        Value::String(v) => SqlValue::Text(v.clone()),
        Value::Array(_) | Value::Object(_) => SqlValue::Text(serde_json::to_string(value)?),
    })
}

fn sql_value_to_json(value: ValueRef<'_>) -> Value {
    match value {
        ValueRef::Null => Value::Null,
        ValueRef::Integer(v) => Value::Number(v.into()),
        ValueRef::Real(v) => Number::from_f64(v)
            .map(Value::Number)
            .unwrap_or(Value::Null),
        ValueRef::Text(v) => Value::String(String::from_utf8_lossy(v).into_owned()),
        ValueRef::Blob(v) => Value::String(base64::engine::general_purpose::STANDARD.encode(v)),
    }
}

// ---------------------------------------------------------------------------
// handle registry
// ---------------------------------------------------------------------------

pub fn open(path: &str) -> Result<i64> {
    let id = NEXT_HANDLE.fetch_add(1, Ordering::SeqCst);
    let handle = Arc::new(DbHandle::open_main(id, path)?);
    lock_registry()?.insert(id, handle);
    Ok(id)
}

pub fn begin(handle: i64, write: bool) -> Result<i64> {
    let main = get(handle)?;
    if !matches!(&main.kind, HandleKind::Main) {
        bail!("cannot begin a transaction on transaction handle {handle}");
    }
    let id = NEXT_HANDLE.fetch_add(1, Ordering::SeqCst);
    let tx = Arc::new(DbHandle::open_tx(id, &main, write)?);
    lock_registry()?.insert(id, tx);
    Ok(id)
}

pub fn get(handle: i64) -> Result<Arc<DbHandle>> {
    lock_registry()?
        .get(&handle)
        .cloned()
        .with_context(|| format!("unknown DB handle {handle}"))
}

/// 当前打开的应用主库（非事务连接）句柄。
///
/// 应用运行期只有一个主连接；进程内测试可能同时打开多个临时库，
/// 这里取最早打开的主连接，保证在单库场景下稳定。
pub fn main_handle() -> Result<i64> {
    lock_registry()?
        .iter()
        .filter(|(_, handle)| matches!(handle.kind, HandleKind::Main))
        .map(|(id, _)| *id)
        .min()
        .context("no open SQLite main database")
}

pub fn commit(handle: i64) -> Result<()> {
    let tx = get(handle)?;
    let is_tx = matches!(&tx.kind, HandleKind::Tx { .. });
    let result = tx.commit();
    if is_tx {
        // commit 失败也移除句柄：底层已在出错时回滚，handle 不应继续可用。
        lock_registry()?.remove(&handle);
    }
    result
}

pub fn rollback(handle: i64) -> Result<()> {
    let tx = get(handle)?;
    tx.rollback()?;
    lock_registry()?.remove(&handle);
    Ok(())
}

pub fn close(handle: i64) -> Result<()> {
    let handle = lock_registry()?.remove(&handle);
    if let Some(handle) = handle {
        handle.close()?;
    }
    Ok(())
}

fn lock_registry() -> Result<MutexGuard<'static, HashMap<i64, Arc<DbHandle>>>> {
    REGISTRY
        .lock()
        .map_err(|_| anyhow!("DB registry lock poisoned"))
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_db(name: &str) -> String {
        let dir = std::env::temp_dir().join("breeze_sql_layer_tests");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join(format!(
            "{name}_{}_{}.sqlite3",
            std::process::id(),
            NEXT_HANDLE.load(Ordering::SeqCst)
        ));
        let _ = std::fs::remove_file(&path);
        path.to_string_lossy().into_owned()
    }

    #[test]
    fn fresh_database_uses_incremental_auto_vacuum() {
        let path = temp_db("auto_vacuum");
        let handle = open(&path).unwrap();
        let db = get(handle).unwrap();
        let read = |db: &DbHandle| -> i64 {
            let rows: Value =
                serde_json::from_str(&db.query_json("PRAGMA auto_vacuum", "[]").unwrap()).unwrap();
            rows[0]["auto_vacuum"].as_i64().unwrap()
        };
        assert_eq!(read(&db), 2);
        db.execute_script("CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT)")
            .unwrap();
        assert_eq!(read(&db), 2, "建表后仍保持 INCREMENTAL");
        close(handle).unwrap();
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn binds_params_as_values() {
        let handle = open(&temp_db("params")).unwrap();
        let db = get(handle).unwrap();
        db.execute_script("CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT)")
            .unwrap();
        db.execute("INSERT INTO t(id, v) VALUES(1, ?1)", r#"["x' OR 1=1 --"]"#)
            .unwrap();
        let rows = db
            .query_json("SELECT v FROM t WHERE v = ?1", r#"["x' OR 1=1 --"]"#)
            .unwrap();
        assert_eq!(rows, r#"[{"v":"x' OR 1=1 --"}]"#);
        // 注入串作为值不会扩大结果集。
        let injected = db
            .query_json("SELECT v FROM t WHERE v = ?1", r#"["' OR 1=1 --"]"#)
            .unwrap();
        assert_eq!(injected, "[]");
        close(handle).unwrap();
    }

    #[test]
    fn change_bus_sees_main_and_tx_commits() {
        let handle = open(&temp_db("bus")).unwrap();
        let db = get(handle).unwrap();
        db.execute_script("CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT)")
            .unwrap();
        let events = Arc::new(Mutex::new(Vec::<Vec<String>>::new()));
        let sink = events.clone();
        db.bus.add_listener(Box::new(move |tables| {
            sink.lock().unwrap().push(tables);
        }));

        db.execute("INSERT INTO t(id, v) VALUES(1, 'main')", "[]")
            .unwrap();
        assert_eq!(events.lock().unwrap().as_slice(), &[vec!["t".to_string()]]);

        let tx = begin(handle, true).unwrap();
        let tx_handle = get(tx).unwrap();
        tx_handle
            .execute("INSERT INTO t(id, v) VALUES(2, 'tx')", "[]")
            .unwrap();
        assert_eq!(events.lock().unwrap().len(), 1, "tx commit 前不应发布");
        commit(tx).unwrap();
        assert_eq!(events.lock().unwrap().len(), 2);

        let tx = begin(handle, true).unwrap();
        get(tx)
            .unwrap()
            .execute("INSERT INTO t(id, v) VALUES(3, 'rollback')", "[]")
            .unwrap();
        rollback(tx).unwrap();
        assert_eq!(events.lock().unwrap().len(), 2, "回滚不应发布");
        close(handle).unwrap();
    }

    #[test]
    fn read_only_transaction_rejects_writes() {
        let path = temp_db("read_only_tx");
        let handle = open(&path).unwrap();
        let db = get(handle).unwrap();
        db.execute_script("CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT)")
            .unwrap();
        db.execute("INSERT INTO t(id, v) VALUES(1, 'main')", "[]")
            .unwrap();

        let tx = begin(handle, false).unwrap();
        let tx_handle = get(tx).unwrap();
        let error = tx_handle
            .execute("INSERT INTO t(id, v) VALUES(2, 'tx')", "[]")
            .unwrap_err();
        assert!(
            format!("{error:#}").contains("readonly"),
            "只读事务必须由 query_only 拒绝写入: {error:#}"
        );
        assert_eq!(
            tx_handle
                .query_json("SELECT COUNT(*) AS c FROM t", "[]")
                .unwrap(),
            r#"[{"c":1}]"#
        );
        rollback(tx).unwrap();
        close(handle).unwrap();
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn read_only_transaction_keeps_a_stable_snapshot() {
        let path = temp_db("read_only_snapshot");
        let handle = open(&path).unwrap();
        let db = get(handle).unwrap();
        db.execute_script("CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT)")
            .unwrap();
        db.execute("INSERT INTO t(id, v) VALUES(1, 'before')", "[]")
            .unwrap();

        let tx = begin(handle, false).unwrap();
        let tx_handle = get(tx).unwrap();
        // 第一条真实读语句建立快照。
        assert_eq!(
            tx_handle
                .query_json("SELECT COUNT(*) AS c FROM t", "[]")
                .unwrap(),
            r#"[{"c":1}]"#
        );
        db.execute("INSERT INTO t(id, v) VALUES(2, 'after')", "[]")
            .unwrap();
        assert_eq!(
            tx_handle
                .query_json("SELECT COUNT(*) AS c FROM t", "[]")
                .unwrap(),
            r#"[{"c":1}]"#,
            "只读事务内的多次读取必须看到同一快照"
        );
        assert_eq!(
            db.query_json("SELECT COUNT(*) AS c FROM t", "[]").unwrap(),
            r#"[{"c":2}]"#
        );
        rollback(tx).unwrap();
        close(handle).unwrap();
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn cached_statements_see_schema_changes() {
        let path = temp_db("cached_schema");
        let handle = open(&path).unwrap();
        let db = get(handle).unwrap();
        db.execute_script("CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT)")
            .unwrap();
        assert_eq!(db.query_json("SELECT * FROM t", "[]").unwrap(), "[]");
        db.execute_script("ALTER TABLE t ADD COLUMN extra TEXT")
            .unwrap();
        db.execute("INSERT INTO t(id, v, extra) VALUES(1, 'v', 'e')", "[]")
            .unwrap();
        assert_eq!(
            db.query_json("SELECT * FROM t", "[]").unwrap(),
            r#"[{"extra":"e","id":1,"v":"v"}]"#,
            "缓存的语句必须在 schema 变化后重新准备"
        );
        close(handle).unwrap();
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn query_execute_and_transaction() {
        let handle = open(&temp_db("crud")).unwrap();
        let db = get(handle).unwrap();
        db.execute_script("CREATE TABLE t(id INTEGER PRIMARY KEY AUTOINCREMENT, v TEXT)")
            .unwrap();
        let result = db
            .execute("INSERT INTO t(v) VALUES(?1)", r#"["a"]"#)
            .unwrap();
        let result: Value = serde_json::from_str(&result).unwrap();
        assert_eq!(result["changes"], 1);
        assert_eq!(result["lastInsertId"], 1);

        let rows = db.query_json("SELECT * FROM t ORDER BY id", "[]").unwrap();
        assert_eq!(rows, r#"[{"id":1,"v":"a"}]"#);

        let tx = begin(handle, true).unwrap();
        let tx_handle = get(tx).unwrap();
        tx_handle
            .execute("INSERT INTO t(v) VALUES(?1)", r#"["b"]"#)
            .unwrap();
        rollback(tx).unwrap();
        assert_eq!(
            db.query_json("SELECT COUNT(*) AS c FROM t", "[]").unwrap(),
            r#"[{"c":1}]"#
        );
        close(handle).unwrap();
    }

    #[test]
    fn transaction_isolation_with_async_style_calls() {
        let handle = open(&temp_db("iso")).unwrap();
        let db = get(handle).unwrap();
        db.execute_script("CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT)")
            .unwrap();
        let tx = begin(handle, true).unwrap();
        let tx_handle = get(tx).unwrap();
        tx_handle
            .execute("INSERT INTO t(id, v) VALUES(1, 'tx')", "[]")
            .unwrap();

        // 事务未提交时，主连接看不到未提交数据。
        assert_eq!(
            db.query_json("SELECT COUNT(*) AS c FROM t", "[]").unwrap(),
            r#"[{"c":0}]"#
        );
        commit(tx).unwrap();
        assert_eq!(
            db.query_json("SELECT COUNT(*) AS c FROM t", "[]").unwrap(),
            r#"[{"c":1}]"#
        );
        close(handle).unwrap();
    }
}
