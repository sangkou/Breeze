//! 字节码缓存：编译 → 落盘格式 → 校验 → 加载 的端到端验证。

use crate::bytecode;
use crate::host_runtime::AsyncHostRuntime;
use serde_json::json;

const PLUGIN_SOURCE: &str = r#"
const helper = (x) => x * 2;
module.exports = {
  answer() { return 42; },
  doubled(v) { return helper(v); },
  hasRequire() { return typeof require; },
};
"#;

async fn build_runtime(name: &str) -> AsyncHostRuntime {
    AsyncHostRuntime::builder(name)
        .http_config_override(Some(super::support::private_network_http_config()))
        .build()
        .expect("build runtime")
}

#[test]
fn engine_bytecode_version_is_positive() {
    // 版本号来自 fork 导出的 BC_VERSION，必须是确定的正整数。
    assert!(bytecode::engine_bytecode_version() > 0);
    assert!(!bytecode::engine_version().is_empty());
}

#[tokio::test]
async fn compile_and_load_bytecode_matches_source_loading() {
    let blob = bytecode::compile_bundle("test-bytecode", PLUGIN_SOURCE, "3.0.0")
        .await
        .expect("compile bytecode");
    let (header, payload) = bytecode::decode(&blob).expect("decode header");
    assert_eq!(header.bytecode_version, bytecode::engine_bytecode_version());
    assert_eq!(header.engine_version, bytecode::engine_version());
    assert_eq!(header.app_version, "3.0.0");
    assert_eq!(
        header.source_hash,
        bytecode::source_fingerprint(PLUGIN_SOURCE)
    );
    assert!(!payload.is_empty());

    let source_runtime = build_runtime("test-bytecode-source").await;
    source_runtime
        .bundle_load("test-bytecode", PLUGIN_SOURCE)
        .await
        .expect("load source");
    let from_source: serde_json::Value = source_runtime
        .bundle_call("test-bytecode", "answer", &json!([]))
        .await
        .expect("call source bundle");
    let source_type: serde_json::Value = source_runtime
        .bundle_call("test-bytecode", "hasRequire", &json!([]))
        .await
        .expect("call source bundle");

    let bytecode_runtime = build_runtime("test-bytecode-blob").await;
    bytecode::load_bundle(
        &bytecode_runtime,
        "test-bytecode",
        PLUGIN_SOURCE,
        "3.0.0",
        &blob,
    )
    .await
    .expect("load bytecode");
    let from_bytecode: serde_json::Value = bytecode_runtime
        .bundle_call("test-bytecode", "answer", &json!([]))
        .await
        .expect("call bytecode bundle");
    let doubled: serde_json::Value = bytecode_runtime
        .bundle_call("test-bytecode", "doubled", &json!([21]))
        .await
        .expect("call bytecode bundle");
    let bytecode_type: serde_json::Value = bytecode_runtime
        .bundle_call("test-bytecode", "hasRequire", &json!([]))
        .await
        .expect("call bytecode bundle");

    assert_eq!(from_source, json!(42));
    assert_eq!(from_bytecode, json!(42));
    assert_eq!(doubled, json!(42));
    // 源码路径与字节码路径的包装参数必须一致。
    assert_eq!(source_type, bytecode_type);
}

#[test]
fn validate_rejects_stale_or_foreign_blobs() {
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("test runtime");
    let blob = runtime
        .block_on(bytecode::compile_bundle(
            "test-validate",
            PLUGIN_SOURCE,
            "3.0.0",
        ))
        .expect("compile bytecode");

    // 正常命中。
    assert!(bytecode::validate(&blob, PLUGIN_SOURCE, "3.0.0").is_ok());

    // 应用升级。
    let error = bytecode::validate(&blob, PLUGIN_SOURCE, "3.0.1").expect_err("app version");
    assert!(error.contains("3.0.1"), "unexpected error: {error}");

    // 插件源码变化。
    let changed = format!("{PLUGIN_SOURCE}\n// patched");
    let error = bytecode::validate(&blob, &changed, "3.0.0").expect_err("source change");
    assert!(
        error.contains("fingerprint") || error.contains("指纹"),
        "unexpected error: {error}"
    );

    // 缓存头被截断。
    let truncated_header = &blob[..20];
    assert!(bytecode::validate(truncated_header, PLUGIN_SOURCE, "3.0.0").is_err());

    // 魔数损坏。
    let mut corrupted = blob.clone();
    corrupted[0] = b'X';
    assert!(bytecode::validate(&corrupted, PLUGIN_SOURCE, "3.0.0").is_err());
}

#[tokio::test]
async fn truncated_payload_fails_cleanly_before_fallback() {
    let blob = bytecode::compile_bundle("test-truncated", PLUGIN_SOURCE, "3.0.0")
        .await
        .expect("compile bytecode");
    let (header, payload) = bytecode::decode(&blob).expect("decode header");
    // 头部完好，扣掉尾部字节 → 校验通过缓存头，但 JS_ReadObject 必须干净失败。
    let truncated_payload = &payload[..payload.len() - 8];
    let broken = bytecode::encode(&header, truncated_payload);

    let runtime = build_runtime("test-bytecode-truncated").await;
    let result =
        bytecode::load_bundle(&runtime, "test-truncated", PLUGIN_SOURCE, "3.0.0", &broken).await;
    assert!(result.is_err(), "truncated bytecode must not load");

    // 失败后同一 runtime 仍可正常加载源码（异常已被清理）。
    runtime
        .bundle_load("test-truncated", PLUGIN_SOURCE)
        .await
        .expect("source fallback after failed bytecode");
    let answer: serde_json::Value = runtime
        .bundle_call("test-truncated", "answer", &json!([]))
        .await
        .expect("call after fallback");
    assert_eq!(answer, json!(42));
}
