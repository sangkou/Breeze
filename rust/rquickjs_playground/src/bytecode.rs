//! 插件 bundle 的 QuickJS 字节码缓存。
//!
//! 目标：插件脚本（常见 1~2MB）每次冷启动都要重新 parse + 生成字节码，是插件
//! 初始化最贵的一步。宿主把源码预编译成字节码落盘，下次启动直接
//! `JS_ReadObject` + `JS_EvalFunction`，跳过解析。
//!
//! 安全边界：
//! - 字节码格式由引擎的 `BC_VERSION`（[`engine_bytecode_version`]）界定，版本不符
//!   时 `JS_ReadObject` 会拒绝加载；`BC_VERSION` 只在字节码编码变化时才变。
//! - 我们的 fork 补丁可能在 `BC_VERSION` 不变的情况下改变生成的指令序列，
//!   所以落盘文件还额外记录了引擎版本串与应用版本；任一不符即视为失效。
//! - 还记录了源码指纹，插件更新（脚本变化但版本号没变）时旧字节码同样失效。
//!
//! 加载语义与现有的 `new Function("module", "exports", "require", source)`
//! 完全一致：编译的是 `(function (module, exports, require) {<source>\n})`，
//! 加载时执行这段程序拿到包装函数，再用同样的三个参数调用。

use std::ffi::{CString, c_void};
use std::sync::LazyLock;
use std::sync::mpsc;

use rquickjs::qjs;
use rquickjs::{AsyncContext, AsyncRuntime, Ctx, Value as JsValue};

use crate::host_runtime::AsyncHostRuntime;

/// 落盘文件头魔数。
const MAGIC: [u8; 4] = *b"BZBC";
/// 文件头布局版本（与引擎 `BC_VERSION` 无关，改文件头结构时才递增）。
const FORMAT: u8 = 1;
/// 引擎/应用版本串长度上限（u8 编码）。
const MAX_VERSION_LEN: usize = 255;

/// 落盘字节码头。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BundleBytecodeHeader {
    /// 引擎 `BC_VERSION`。
    pub bytecode_version: u32,
    /// quickjs 引擎版本串（`JS_GetVersion()`）。
    pub engine_version: String,
    /// 宿主应用版本；应用升级后旧字节码整体作废。
    pub app_version: String,
    /// 源码指纹（xxh3-64）。
    pub source_hash: u64,
}

/// 当前引擎的字节码格式版本（quickjs `BC_VERSION`）。
///
/// `JS_WriteObject` 会把它写在每个序列化对象的第一字节，`JS_ReadObject`
/// 读入时强校验，因此它同时是「写入格式」和「可读格式」的版本号。
pub fn engine_bytecode_version() -> u32 {
    // fork 导出的常量访问器，纯 C 常量读取，无副作用、无需 JS 上下文。
    unsafe { qjs::JS_GetBytecodeVersion() as u32 }
}

/// 当前引擎版本串（如 `2025-09-13`）。
static ENGINE_VERSION: std::sync::LazyLock<String> = std::sync::LazyLock::new(|| unsafe {
    let ptr = qjs::JS_GetVersion();
    if ptr.is_null() {
        return String::new();
    }
    std::ffi::CStr::from_ptr(ptr).to_string_lossy().into_owned()
});

pub fn engine_version() -> &'static str {
    ENGINE_VERSION.as_str()
}

/// 源码指纹。
pub fn source_fingerprint(source: &str) -> u64 {
    xxhash_rust::xxh3::xxh3_64(source.as_bytes())
}

/// bundle 名 → 脚本文件名。
///
/// 与 JS 侧 `sanitizeSourceName` 保持一致：只保留 `[A-Za-z0-9._-]`，截断 120。
/// 该名字会写进字节码，用于错误堆栈。
pub fn script_filename(bundle_name: &str) -> String {
    let mut name = String::with_capacity(bundle_name.len() + 4);
    for ch in bundle_name.chars() {
        if ch.is_ascii_alphanumeric() || matches!(ch, '.' | '_' | '-') {
            name.push(ch);
        } else {
            name.push('_');
        }
        if name.len() >= 120 {
            break;
        }
    }
    if name.is_empty() {
        name.push_str("bundle");
    }
    name.push_str(".cjs");
    name
}

/// 把 CommonJS 源码包成可缓存的「程序」。
///
/// 返回值是一个求值后得到包装函数的表达式，语义等价于
/// `new Function("module", "exports", "require", source)`；源码从第一行开始
/// 紧贴 `{` 之后，保持行号不变。
pub fn wrap_module_source(source: &str) -> String {
    let mut wrapped = String::with_capacity(source.len() + 48);
    wrapped.push_str("(function (module, exports, require) {");
    wrapped.push_str(source);
    wrapped.push_str("\n})");
    wrapped
}

/// 把源码编译成字节码（不执行），返回可落盘的完整 blob。
pub async fn compile_bundle(
    bundle_name: &str,
    source: &str,
    app_version: &str,
) -> Result<Vec<u8>, String> {
    let header = BundleBytecodeHeader {
        bytecode_version: engine_bytecode_version(),
        engine_version: engine_version().to_string(),
        app_version: app_version.to_string(),
        source_hash: source_fingerprint(source),
    };
    let payload =
        compile_script(&script_filename(bundle_name), &wrap_module_source(source)).await?;
    Ok(encode(&header, &payload))
}

/// 校验 blob 头（格式 / 引擎字节码版本 / 引擎版本 / 应用版本）。
fn validate_header<'a>(
    blob: &'a [u8],
    app_version: &str,
) -> Result<(BundleBytecodeHeader, &'a [u8]), String> {
    let (header, payload) = decode(blob)?;

    let expected_version = engine_bytecode_version();
    if header.bytecode_version != expected_version {
        return Err(crate::tr!(
            "bytecode-version-mismatch",
            expected = expected_version,
            actual = header.bytecode_version
        )
        .to_string());
    }

    let expected_engine = engine_version();
    if header.engine_version != expected_engine {
        return Err(crate::tr!(
            "bytecode-engine-mismatch",
            expected = expected_engine,
            actual = header.engine_version
        )
        .to_string());
    }

    if header.app_version != app_version {
        return Err(crate::tr!(
            "bytecode-app-version-mismatch",
            expected = app_version,
            actual = header.app_version
        )
        .to_string());
    }

    Ok((header, payload))
}

/// 校验 blob 是否可用于当前源码，返回裸 JS 字节码。
///
/// 任一维度不符都返回具体原因，调用方据此回退源码并重新编译。
pub fn validate<'a>(blob: &'a [u8], source: &str, app_version: &str) -> Result<&'a [u8], String> {
    let (header, payload) = validate_header(blob, app_version)?;

    let expected_hash = source_fingerprint(source);
    if header.source_hash != expected_hash {
        return Err(crate::tr!(
            "bytecode-source-mismatch",
            expected = format!("{:016x}", expected_hash),
            actual = format!("{:016x}", header.source_hash)
        )
        .to_string());
    }

    Ok(payload)
}

/// 不比对源码指纹的校验。
///
/// 只有宿主用脚本 revision 给字节码命名、能保证文件对应当前脚本时才可用；
/// 引擎与应用版本仍然强校验。返回裸 JS 字节码。
pub fn validate_without_source<'a>(blob: &'a [u8], app_version: &str) -> Result<&'a [u8], String> {
    validate_header(blob, app_version).map(|(_, payload)| payload)
}

/// 用字节码加载 bundle。
///
/// 先做缓存头校验（版本 / 引擎 / 应用版本 / 源码指纹），通过后进入
/// `JS_ReadObject` + `JS_EvalFunction` 快速路径；任何一步失败都返回错误，
/// 由调用方回退到源码加载。
pub async fn load_bundle(
    runtime: &AsyncHostRuntime,
    name: &str,
    source: &str,
    app_version: &str,
    blob: &[u8],
) -> Result<(), String> {
    let payload = validate(blob, source, app_version)?;
    runtime.bundle_load_bytecode(name, source, payload).await
}

/// 组装落盘 blob。
pub fn encode(header: &BundleBytecodeHeader, payload: &[u8]) -> Vec<u8> {
    let engine = header.engine_version.as_bytes();
    let app = header.app_version.as_bytes();
    let engine_len = engine.len().min(MAX_VERSION_LEN);
    let app_len = app.len().min(MAX_VERSION_LEN);

    let mut out = Vec::with_capacity(4 + 1 + 4 + 1 + engine_len + 1 + app_len + 8 + payload.len());
    out.extend_from_slice(&MAGIC);
    out.push(FORMAT);
    out.extend_from_slice(&header.bytecode_version.to_le_bytes());
    out.push(engine_len as u8);
    out.extend_from_slice(&engine[..engine_len]);
    out.push(app_len as u8);
    out.extend_from_slice(&app[..app_len]);
    out.extend_from_slice(&header.source_hash.to_le_bytes());
    out.extend_from_slice(payload);
    out
}

/// 解析落盘 blob。
pub fn decode(blob: &[u8]) -> Result<(BundleBytecodeHeader, &[u8]), String> {
    let mut cursor = Cursor::new(blob);

    if cursor.take(4)? != MAGIC {
        return Err(crate::tr!("bytecode-bad-magic").to_string());
    }
    let format = cursor.u8()?;
    if format != FORMAT {
        return Err(crate::tr!(
            "bytecode-format-mismatch",
            expected = FORMAT,
            actual = format
        )
        .to_string());
    }
    let bytecode_version = cursor.u32()?;
    let engine_version = cursor.version_string()?;
    let app_version = cursor.version_string()?;
    let source_hash = cursor.u64()?;
    let payload = &blob[cursor.pos..];
    Ok((
        BundleBytecodeHeader {
            bytecode_version,
            engine_version,
            app_version,
            source_hash,
        },
        payload,
    ))
}

struct Cursor<'a> {
    bytes: &'a [u8],
    pos: usize,
}

impl<'a> Cursor<'a> {
    fn new(bytes: &'a [u8]) -> Self {
        Self { bytes, pos: 0 }
    }

    fn take(&mut self, len: usize) -> Result<&'a [u8], String> {
        let end = self
            .pos
            .checked_add(len)
            .ok_or_else(|| crate::tr!("bytecode-blob-truncated").to_string())?;
        if end > self.bytes.len() {
            return Err(crate::tr!("bytecode-blob-truncated").to_string());
        }
        let slice = &self.bytes[self.pos..end];
        self.pos = end;
        Ok(slice)
    }

    fn u8(&mut self) -> Result<u8, String> {
        Ok(self.take(1)?[0])
    }

    fn u32(&mut self) -> Result<u32, String> {
        let raw = self.take(4)?;
        Ok(u32::from_le_bytes([raw[0], raw[1], raw[2], raw[3]]))
    }

    fn u64(&mut self) -> Result<u64, String> {
        let raw = self.take(8)?;
        Ok(u64::from_le_bytes([
            raw[0], raw[1], raw[2], raw[3], raw[4], raw[5], raw[6], raw[7],
        ]))
    }

    fn version_string(&mut self) -> Result<String, String> {
        let len = self.u8()? as usize;
        let raw = self.take(len)?;
        String::from_utf8(raw.to_vec())
            .map_err(|e| crate::tr!("bytecode-version-not-utf8", err = e).to_string())
    }
}

struct CompileJob {
    filename: String,
    script: String,
    reply: tokio::sync::oneshot::Sender<Result<Vec<u8>, String>>,
}

/// 全局单 worker 编译池：所有插件共用同一个操作系统线程，同一时刻最多编译一个。
///
/// 编译任务通过 channel 排队，worker 线程持有独立的 current-thread tokio runtime；
/// 每个任务内部仍创建独立的 QuickJS runtime，任务之间不共享 JS 状态。
static COMPILE_WORKER: LazyLock<Result<mpsc::Sender<CompileJob>, String>> = LazyLock::new(|| {
    let (tx, rx) = mpsc::channel::<CompileJob>();
    std::thread::Builder::new()
        .name("qjs-bytecode-compile".to_string())
        .spawn(move || run_compile_worker(rx))
        .map(|_| tx)
        .map_err(|e| crate::tr!("failed-to-spawn-bytecode-compile-thread", e = e).to_string())
});

fn compile_worker_sender() -> Result<&'static mpsc::Sender<CompileJob>, String> {
    COMPILE_WORKER.as_ref().map_err(|err| err.clone())
}

fn run_compile_worker(rx: mpsc::Receiver<CompileJob>) {
    let rt = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(rt) => rt,
        Err(e) => {
            let message =
                crate::tr!("failed-to-create-bytecode-compile-runtime", e = e).to_string();
            for job in rx {
                let _ = job.reply.send(Err(message.clone()));
            }
            return;
        }
    };

    while let Ok(job) = rx.recv() {
        let outcome = rt.block_on(compile_job(&job.filename, &job.script));
        let _ = job.reply.send(outcome);
    }
}

async fn compile_job(filename: &str, script: &str) -> Result<Vec<u8>, String> {
    let runtime = AsyncRuntime::new()
        .map_err(|e| crate::tr!("failed-to-initialize-asyncruntime", e = e).to_string())?;
    let context = AsyncContext::full(&runtime)
        .await
        .map_err(|e| crate::tr!("failed-to-initialize-asynccontext", e = e).to_string())?;
    let bytecode = context
        .with(|ctx| write_compiled_bytecode(&ctx, script, filename))
        .await;
    drop(context);
    drop(runtime);
    bytecode
}

/// 把编译任务投递给全局单 worker，并等待结果。
async fn compile_script(filename: &str, script: &str) -> Result<Vec<u8>, String> {
    let (tx, rx) = tokio::sync::oneshot::channel::<Result<Vec<u8>, String>>();
    compile_worker_sender()?
        .send(CompileJob {
            filename: filename.to_owned(),
            script: script.to_owned(),
            reply: tx,
        })
        .map_err(|_| crate::tr!("bytecode-compile-thread-exited").to_string())?;

    rx.await
        .map_err(|_| crate::tr!("bytecode-compile-thread-exited").to_string())?
}

fn write_compiled_bytecode(ctx: &Ctx<'_>, script: &str, filename: &str) -> Result<Vec<u8>, String> {
    let script_c = CString::new(script)
        .map_err(|e| crate::tr!("bytecode-source-contains-nul", e = e).to_string())?;
    let filename_c = CString::new(filename)
        .map_err(|e| crate::tr!("bytecode-filename-contains-nul", e = e).to_string())?;

    let raw = unsafe {
        qjs::JS_Eval(
            ctx.as_raw().as_ptr(),
            script_c.as_ptr(),
            script.len() as qjs::size_t,
            filename_c.as_ptr(),
            (qjs::JS_EVAL_TYPE_GLOBAL | qjs::JS_EVAL_FLAG_COMPILE_ONLY) as ::core::ffi::c_int,
        )
    };
    if unsafe { qjs::JS_IsException(raw) } {
        return Err(take_exception_text(ctx));
    }

    // 编译产物所有权交给 Value，drop 时释放。
    let value = unsafe { JsValue::from_raw(ctx.clone(), raw) };
    let mut size: qjs::size_t = 0;
    let buffer = unsafe {
        qjs::JS_WriteObject(
            ctx.as_raw().as_ptr(),
            &mut size,
            value.as_raw(),
            qjs::JS_WRITE_OBJ_BYTECODE as ::core::ffi::c_int,
        )
    };
    if buffer.is_null() {
        return Err(take_exception_text(ctx));
    }
    let bytes = unsafe { std::slice::from_raw_parts(buffer, size as usize) }.to_vec();
    unsafe { qjs::js_free(ctx.as_raw().as_ptr(), buffer.cast::<c_void>()) };
    Ok(bytes)
}

/// 取走当前挂起的 JS 异常并格式化为诊断文本。
pub(crate) fn take_exception_text(ctx: &Ctx<'_>) -> String {
    let value = ctx.catch();
    if let Some(exception) = value.as_exception() {
        if let Some(message) = exception.message() {
            return message;
        }
    }
    if let Some(text) = value.as_string().and_then(|text| text.to_string().ok()) {
        return text;
    }
    crate::tr!("bytecode-unknown-engine-error").to_string()
}
