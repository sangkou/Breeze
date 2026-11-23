//! 第一层 SQLite API：通用、异步、无业务实体。
//!
//! Dart 第二层负责建表/索引 SQL、事务边界、模型转换和版本迁移。
//! 这里只执行 SQL 和广播表变更。

use anyhow::{Context, Result};
use flutter_rust_bridge::frb;
use serde_json::{Map, Value, json};

use crate::db::obx_archive::archive_objectbox_data;
use crate::db::obx_reader::read_objectbox_database;
use crate::db::plugin_config;
use crate::db::sql;
use crate::frb_generated::StreamSink;

/// 在 tokio 的 blocking 线程池执行 SQLite / LMDB 同步调用。
///
/// FRB 的 `async fn` 直接跑在共享 tokio runtime 上；rusqlite 的查询、
/// `BEGIN IMMEDIATE` 等锁、COMMIT fsync 和 WAL checkpoint 都是阻塞操作，
/// 留在 async worker 上会拖住同一 runtime 的 HTTP / QJS 任务。
async fn run_db<F, T>(f: F) -> Result<T>
where
    F: FnOnce() -> Result<T> + Send + 'static,
    T: Send + 'static,
{
    tokio::task::spawn_blocking(f)
        .await
        .context("database blocking task failed")?
}

#[frb]
pub async fn db_open(path: String) -> Result<i64> {
    run_db(move || sql::open(&path)).await
}

#[frb]
pub async fn db_close(handle: i64) -> Result<()> {
    run_db(move || sql::close(handle)).await
}

/// 合并写入插件配置，返回与旧 Dart 实现一致的 `{"ok":true}`。
#[frb]
pub async fn db_plugin_config_save(
    handle: i64,
    name: String,
    key: String,
    value: String,
) -> Result<String> {
    run_db(move || {
        plugin_config::save_value(handle, &name, &key, &value)?;
        Ok(plugin_config::save_response_string())
    })
    .await
}

/// 读取插件配置，返回 `{"ok":true,"value":...}`（value 为 JSON 文本内嵌）。
#[frb]
pub async fn db_plugin_config_load(
    handle: i64,
    name: String,
    key: String,
    fallback: String,
) -> Result<String> {
    run_db(move || {
        let value = plugin_config::load_value(handle, &name, &key, &fallback)?;
        Ok(plugin_config::load_response_string(value))
    })
    .await
}

/// 查询返回 JSON 数组：`[{"col": value, ...}, ...]`。
#[frb]
pub async fn db_query(handle: i64, sql_text: String, params_json: String) -> Result<String> {
    run_db(move || sql::get(handle)?.query_json(&sql_text, &params_json)).await
}

/// 执行单条语句，返回 `{"changes": n, "lastInsertId": id}`。
#[frb]
pub async fn db_execute(handle: i64, sql_text: String, params_json: String) -> Result<String> {
    run_db(move || sql::get(handle)?.execute(&sql_text, &params_json)).await
}

/// 执行多条语句（建表/索引/迁移脚本）。
#[frb]
pub async fn db_execute_script(handle: i64, sql_text: String) -> Result<()> {
    run_db(move || sql::get(handle)?.execute_script(&sql_text)).await
}

/// 事务使用独立连接；`write=false` 时是只读事务。
#[frb]
pub async fn db_begin(handle: i64, write: bool) -> Result<i64> {
    run_db(move || sql::begin(handle, write)).await
}

#[frb]
pub async fn db_commit(tx: i64) -> Result<()> {
    run_db(move || sql::commit(tx)).await
}

#[frb]
pub async fn db_rollback(tx: i64) -> Result<()> {
    run_db(move || sql::rollback(tx)).await
}

/// 订阅表变更。事务提交/主连接 autocommit 后推送一次去重表名列表。
#[frb]
pub fn db_watch_changes(handle: i64, sink: StreamSink<Vec<String>>) -> Result<()> {
    let db = sql::get(handle)?;
    db.bus.add_listener(Box::new(move |tables| {
        let _ = sink.add(tables);
    }));
    Ok(())
}

/// 只读取旧 ObjectBox LMDB，不写 SQLite。
///
/// 返回格式：
/// `{"objectRows":55,"skippedRows":0,"entities":{"UserSetting":[{...}]}}`
/// 日期为 Unix 毫秒整数，List<String> 为 JSON 数组。
#[frb]
pub async fn db_inspect_objectbox(old_dir: String) -> Result<String> {
    run_db(move || {
        let snapshot = read_objectbox_database(std::path::Path::new(&old_dir))?;
        let mut entities = Map::new();
        for (name, records) in snapshot.records {
            entities.insert(
                name,
                Value::Array(records.into_iter().map(Value::Object).collect()),
            );
        }
        Ok(json!({
            "objectRows": snapshot.object_rows,
            "skippedRows": snapshot.skipped_rows,
            "entities": entities,
        })
        .to_string())
    })
    .await
}

/// 压缩迁移完成后的旧 ObjectBox `data.mdb`。
///
/// 归档写到同目录的 `data.mdb.7z`；只有完整解压并核对 MD5 与原文件一致后
/// 才会删除 `data.mdb`。失败时保留原文件，调用方可在下次启动重试。
#[frb]
pub async fn db_archive_objectbox_data(old_dir: String) -> Result<String> {
    run_db(move || {
        let outcome = archive_objectbox_data(std::path::Path::new(&old_dir))?;
        Ok(json!({
            "status": outcome.status.as_str(),
            "oldDir": old_dir,
            "originalBytes": outcome.original_bytes,
            "archiveBytes": outcome.archive_bytes,
        })
        .to_string())
    })
    .await
}

#[cfg(test)]
mod tests {
    use std::time::{SystemTime, UNIX_EPOCH};

    use super::*;

    #[tokio::test(flavor = "current_thread")]
    async fn run_db_leaves_the_async_worker_free() {
        let caller = std::thread::current().id();
        let worker = run_db(|| Ok::<_, anyhow::Error>(std::thread::current().id()))
            .await
            .unwrap();
        assert_ne!(caller, worker, "SQLite 调用必须在 blocking 线程池执行");
    }

    #[tokio::test(flavor = "current_thread")]
    async fn database_api_crud_and_transaction() {
        let dir = std::env::temp_dir().join("breeze_database_api_tests");
        std::fs::create_dir_all(&dir).unwrap();
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path = dir.join(format!("api_{}_{unique}.sqlite3", std::process::id()));

        let handle = db_open(path.to_string_lossy().into_owned()).await.unwrap();
        db_execute_script(
            handle,
            "CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT)".into(),
        )
        .await
        .unwrap();
        let inserted = db_execute(
            handle,
            "INSERT INTO t(v) VALUES(?1)".into(),
            r#"["a"]"#.into(),
        )
        .await
        .unwrap();
        assert!(inserted.contains(r#""lastInsertId":1"#), "{inserted}");
        assert_eq!(
            db_query(handle, "SELECT COUNT(*) AS c FROM t".into(), "[]".into())
                .await
                .unwrap(),
            r#"[{"c":1}]"#
        );

        let tx = db_begin(handle, true).await.unwrap();
        db_execute(tx, "INSERT INTO t(v) VALUES(?1)".into(), r#"["b"]"#.into())
            .await
            .unwrap();
        db_commit(tx).await.unwrap();
        assert_eq!(
            db_query(handle, "SELECT COUNT(*) AS c FROM t".into(), "[]".into())
                .await
                .unwrap(),
            r#"[{"c":2}]"#
        );

        let read_tx = db_begin(handle, false).await.unwrap();
        assert_eq!(
            db_query(read_tx, "SELECT COUNT(*) AS c FROM t".into(), "[]".into())
                .await
                .unwrap(),
            r#"[{"c":2}]"#
        );
        db_rollback(read_tx).await.unwrap();

        db_close(handle).await.unwrap();
        let _ = std::fs::remove_file(path);
    }
}
