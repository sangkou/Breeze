//! 本地存储层。
//!
//! - [`obx_reader`]：不依赖 libobjectbox，直接从 LMDB 读取旧 ObjectBox 数据。
//! - [`obx_archive`]：迁移完成后压缩旧 `data.mdb`。
//! - `sql`：应用运行期的 SQLite 连接、参数化执行、事务与表变更观察者。

pub mod obx_archive;
pub mod obx_reader;
pub mod plugin_config;
pub mod sql;
