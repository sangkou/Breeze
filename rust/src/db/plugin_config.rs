//! 插件配置持久化。
//!
//! 表结构：`"PluginConfig"("id", "name", "config")`，`config` 是一个 JSON 对象。
//! 这里负责与旧 Dart 实现一致的合并/读取语义，QJS 宿主路由和 Dart UI 共用：
//! - save 把 `key` 合并进配置对象，值先按 JSON 解析，失败则按原始字符串保存；
//! - load 读取 `key`，缺失时返回 fallback（同样先按 JSON 解析）；
//! - 空 `key` 表示整个配置对象；
//! - 配置内容不是合法 JSON 对象时按空对象处理。

use std::sync::Mutex;

use anyhow::{Context, Result};
use serde_json::{Map, Value, json};

use crate::db::sql::{self, DbHandle};

const SELECT_CONFIG_BY_NAME: &str =
    r#"SELECT "id", "config" FROM "PluginConfig" WHERE "name" = ? LIMIT 1"#;
const UPDATE_CONFIG_BY_ID: &str = r#"UPDATE "PluginConfig" SET "config" = ? WHERE "id" = ?"#;
const INSERT_CONFIG: &str = r#"INSERT INTO "PluginConfig" ("name", "config") VALUES (?, ?)"#;

/// 串行化读-改-写，避免并发 save（例如 JM 登录的 Promise.all）互相覆盖。
static SAVE_LOCK: Mutex<()> = Mutex::new(());

/// QJS 宿主路由使用的应用主库句柄（Rust 侧自动解析，无需 Flutter 注册）。
pub(crate) fn app_handle() -> Result<i64> {
    sql::main_handle()
}

fn decode_object_map(raw: &str) -> Map<String, Value> {
    let text = raw.trim();
    if text.is_empty() {
        return Map::new();
    }
    match serde_json::from_str::<Value>(text) {
        Ok(Value::Object(map)) => map,
        _ => Map::new(),
    }
}

fn decode_maybe_json(value: &str) -> Value {
    let text = value.trim();
    if text.is_empty() {
        return Value::String(value.to_string());
    }
    serde_json::from_str(text).unwrap_or_else(|_| Value::String(value.to_string()))
}

fn query_config_row(db: &DbHandle, name: &str) -> Result<Option<(i64, String)>> {
    let params = serde_json::to_string(&[name])?;
    let rows_json = db.query_json(SELECT_CONFIG_BY_NAME, &params)?;
    let rows: Vec<Value> =
        serde_json::from_str(&rows_json).context("解析 PluginConfig 查询结果失败")?;
    let Some(row) = rows.first() else {
        return Ok(None);
    };
    let id = row
        .get("id")
        .and_then(Value::as_i64)
        .context("PluginConfig.id 无效")?;
    let config = row
        .get("config")
        .and_then(Value::as_str)
        .unwrap_or_default();
    Ok(Some((id, config.to_string())))
}

/// 合并写入配置。空 `key` 只确保行存在，配置内容不变。
pub fn save_value(handle: i64, name: &str, key: &str, value: &str) -> Result<()> {
    let _guard = SAVE_LOCK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let db = sql::get(handle)?;
    let existing = query_config_row(&db, name)?;
    let mut data = match &existing {
        Some((_, config)) => decode_object_map(config),
        None => Map::new(),
    };
    if !key.is_empty() {
        data.insert(key.to_string(), decode_maybe_json(value));
    }
    let config = Value::Object(data).to_string();
    if let Some((id, _)) = existing {
        db.execute(UPDATE_CONFIG_BY_ID, &json!([config, id]).to_string())?;
    } else {
        db.execute(INSERT_CONFIG, &json!([name, config]).to_string())?;
    }
    Ok(())
}

/// 读取配置。空 `key` 返回整个配置对象；缺失 key 返回解析后的 fallback。
pub fn load_value(handle: i64, name: &str, key: &str, fallback: &str) -> Result<Value> {
    let db = sql::get(handle)?;
    let data = query_config_row(&db, name)?
        .map(|(_, config)| decode_object_map(&config))
        .unwrap_or_default();
    if key.is_empty() {
        Ok(Value::Object(data))
    } else {
        Ok(data
            .get(key)
            .cloned()
            .unwrap_or_else(|| decode_maybe_json(fallback)))
    }
}

/// 与旧 Dart bridge 完全一致的保存响应字符串。
pub fn save_response_string() -> String {
    r#"{"ok":true}"#.to_string()
}

/// 与旧 Dart bridge 完全一致的读取响应字符串。
pub fn load_response_string(value: Value) -> String {
    json!({ "ok": true, "value": value }).to_string()
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, Ordering};

    use super::*;

    static TEST_SEQ: AtomicU64 = AtomicU64::new(0);

    fn temp_db(name: &str) -> (i64, PathBuf) {
        let dir = std::env::temp_dir().join("breeze_plugin_config_tests");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join(format!(
            "{name}_{}_{}.sqlite3",
            std::process::id(),
            TEST_SEQ.fetch_add(1, Ordering::SeqCst)
        ));
        let _ = std::fs::remove_file(&path);
        let handle = sql::open(path.to_str().unwrap()).unwrap();
        sql::get(handle)
            .unwrap()
            .execute_script(
                r#"CREATE TABLE "PluginConfig" (
                    "id" INTEGER PRIMARY KEY AUTOINCREMENT,
                    "name" TEXT NOT NULL DEFAULT '',
                    "config" TEXT NOT NULL DEFAULT ''
                )"#,
            )
            .unwrap();
        (handle, path)
    }

    fn envelope(raw: &str) -> Value {
        let value: Value = serde_json::from_str(raw).unwrap();
        assert_eq!(value["ok"], true);
        value
    }

    #[test]
    fn save_and_load_roundtrip_matches_dart_semantics() {
        let (handle, path) = temp_db("roundtrip");
        save_value(handle, "plugin", "theme", r#""dark""#).unwrap();
        save_value(handle, "plugin", "meta", r#"{"a":1,"b":[true,null]}"#).unwrap();
        save_value(handle, "plugin", "raw", "not-json").unwrap();
        save_value(handle, "plugin", "blank", "   ").unwrap();

        assert_eq!(
            load_value(handle, "plugin", "theme", "null").unwrap(),
            json!("dark")
        );
        assert_eq!(
            load_value(handle, "plugin", "meta", "null").unwrap(),
            json!({"a": 1, "b": [true, null]})
        );
        assert_eq!(
            load_value(handle, "plugin", "raw", "null").unwrap(),
            json!("not-json")
        );
        assert_eq!(
            load_value(handle, "plugin", "blank", "null").unwrap(),
            json!("   ")
        );
        assert_eq!(
            load_value(handle, "plugin", "missing", r#"{"x":2}"#).unwrap(),
            json!({"x": 2})
        );
        assert_eq!(
            load_value(handle, "plugin", "", "null").unwrap(),
            json!({"theme": "dark", "meta": {"a": 1, "b": [true, null]}, "raw": "not-json", "blank": "   "})
        );

        let response = envelope(&load_response_string(
            load_value(handle, "plugin", "missing", r#""fallback""#).unwrap(),
        ));
        assert_eq!(response["value"], json!("fallback"));
        assert_eq!(save_response_string(), r#"{"ok":true}"#);

        sql::close(handle).unwrap();
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn concurrent_saves_do_not_lose_keys() {
        let (handle, path) = temp_db("concurrent");
        let mut threads = Vec::new();
        for i in 0..16 {
            threads.push(std::thread::spawn(move || {
                save_value(handle, "plugin", &format!("k{i}"), &i.to_string()).unwrap();
            }));
        }
        for thread in threads {
            thread.join().unwrap();
        }

        let config = load_value(handle, "plugin", "", "null").unwrap();
        let object = config.as_object().expect("config object");
        assert_eq!(object.len(), 16);
        for i in 0..16 {
            assert_eq!(object[&format!("k{i}")], json!(i));
        }

        sql::close(handle).unwrap();
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn empty_key_creates_row_without_changing_config() {
        let (handle, path) = temp_db("empty_key");
        save_value(handle, "plugin", "", "123").unwrap();

        assert_eq!(load_value(handle, "plugin", "", "null").unwrap(), json!({}));
        let rows = sql::get(handle)
            .unwrap()
            .query_json(r#"SELECT COUNT(*) AS c FROM "PluginConfig""#, "[]")
            .unwrap();
        assert_eq!(rows, r#"[{"c":1}]"#);

        sql::close(handle).unwrap();
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn malformed_existing_config_is_treated_as_empty() {
        let (handle, path) = temp_db("malformed");
        sql::get(handle)
            .unwrap()
            .execute(
                "INSERT INTO \"PluginConfig\" (\"name\", \"config\") VALUES (?, ?)",
                r#"["plugin","not a json object"]"#,
            )
            .unwrap();

        assert_eq!(load_value(handle, "plugin", "", "null").unwrap(), json!({}));
        save_value(handle, "plugin", "k", "7").unwrap();
        assert_eq!(
            load_value(handle, "plugin", "", "null").unwrap(),
            json!({"k": 7})
        );

        sql::close(handle).unwrap();
        let _ = std::fs::remove_file(path);
    }
}
