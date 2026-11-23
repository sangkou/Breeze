//! 直接读取 ObjectBox 的 LMDB 数据库，不依赖 `libobjectbox`。
//!
//! ObjectBox 在 LMDB 上定义了固定格式：
//! - object key：8/12 字节，prefix 编码 entity id，后跟 object id；
//! - object value：FlatBuffers 表，property id `p` 位于 vtable slot `p - 1`；
//! - meta key：前 4 字节为 0，key 低 4 字节为 entity id，value 是该 entity 的 schema。
//!
//! 这里只做「读取 + 解码」，不写 LMDB。格式细节与验证结论见
//! `objectbox-reader-src-0.1.0.zip` 内的参考实现（已在 ObjectBox core
//! 4.0.0/4.3.1/5.0.0/5.3.2 上对齐）。
//!
//! 解码输出使用数据库里的原始表示：date 为 Unix 毫秒整数，List<String>
//! 为 JSON 数组。迁移层再按目标 SQLite 列类型转换。

use std::collections::{BTreeMap, HashMap};
use std::path::Path;

use anyhow::{Context, Result, bail};
use lmdb::{Cursor, Environment, Transaction};
use serde_json::{Map, Value};

const KIND_OBJECT_PREFIX: u32 = 0x1800_0000;
const KIND_INDEX_PREFIX: u32 = 0x2000_0000;

const T_BOOL: u16 = 1;
const T_BYTE: u16 = 2;
const T_SHORT: u16 = 3;
const T_CHAR: u16 = 4;
const T_INT: u16 = 5;
const T_LONG: u16 = 6;
const T_FLOAT: u16 = 7;
const T_DOUBLE: u16 = 8;
const T_STRING: u16 = 9;
const T_DATE: u16 = 10;
const T_RELATION: u16 = 11;
const T_DATE_NANO: u16 = 12;
const T_FLEX: u16 = 13;
const T_BOOL_VECTOR: u16 = 22;
const T_BYTE_VECTOR: u16 = 23;
const T_SHORT_VECTOR: u16 = 24;
const T_CHAR_VECTOR: u16 = 25;
const T_INT_VECTOR: u16 = 26;
const T_LONG_VECTOR: u16 = 27;
const T_FLOAT_VECTOR: u16 = 28;
const T_DOUBLE_VECTOR: u16 = 29;
const T_STRING_VECTOR: u16 = 30;
const T_DATE_VECTOR: u16 = 31;
const T_DATE_NANO_VECTOR: u16 = 32;

#[derive(Debug, Clone)]
pub struct ObxProperty {
    pub id: u32,
    pub name: String,
    pub ty: u16,
}

#[derive(Debug, Clone)]
pub struct ObxEntity {
    pub id: u32,
    pub name: String,
    pub properties: Vec<ObxProperty>,
}

#[derive(Debug, Default)]
pub struct ObxSnapshot {
    pub entities: Vec<ObxEntity>,
    pub records: BTreeMap<String, Vec<Map<String, Value>>>,
    pub object_rows: u64,
    pub skipped_rows: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum KeyKind {
    Object,
    Index,
    Meta,
}

fn classify_key(key: &[u8]) -> Option<KeyKind> {
    if key.len() != 8 && key.len() != 12 {
        return None;
    }
    let prefix = u32::from_be_bytes(key[0..4].try_into().ok()?);
    if prefix & 0xFC00_0000 == KIND_OBJECT_PREFIX {
        return Some(KeyKind::Object);
    }
    if prefix & 0xFC00_0000 == KIND_INDEX_PREFIX {
        return Some(KeyKind::Index);
    }
    if prefix == 0 && key.len() == 8 {
        return Some(KeyKind::Meta);
    }
    None
}

fn parse_object_key(key: &[u8]) -> Option<(u32, u64)> {
    if key.len() != 8 && key.len() != 12 {
        return None;
    }
    let prefix = u32::from_be_bytes(key[0..4].try_into().ok()?);
    if prefix & 0xFC00_0000 != KIND_OBJECT_PREFIX {
        return None;
    }
    let entity_id = (prefix & 0x03FF_FFFC) >> 2;
    if entity_id == 0 {
        return None;
    }
    let object_id = match key.len() {
        8 => u32::from_be_bytes(key[4..8].try_into().ok()?) as u64,
        12 => u64::from_be_bytes(key[4..12].try_into().ok()?),
        _ => return None,
    };
    Some((entity_id, object_id))
}

fn parse_meta_entity_id(key: &[u8]) -> Option<u32> {
    if key.len() != 8 || key[0..4] != [0, 0, 0, 0] {
        return None;
    }
    Some(u32::from_be_bytes(key[4..8].try_into().ok()?))
}

fn open_env(db_dir: &Path) -> Result<Environment> {
    let data_path = db_dir.join("data.mdb");
    if !data_path.exists() {
        bail!(
            "ObjectBox database not found: {}",
            data_path.to_string_lossy()
        );
    }
    let file_len = std::fs::metadata(&data_path)
        .with_context(|| format!("stat {}", data_path.to_string_lossy()))?
        .len();
    let map_size = file_len.saturating_mul(2).max(64 * 1024 * 1024) as usize;

    let mut builder = Environment::new();
    builder
        .set_flags(lmdb::EnvironmentFlags::READ_ONLY | lmdb::EnvironmentFlags::NO_LOCK)
        .set_map_size(map_size);
    builder
        .open(db_dir)
        .with_context(|| format!("open LMDB env {}", db_dir.to_string_lossy()))
}

// ---------------------------------------------------------------------------
// FlatBuffers 最小读取器
// ---------------------------------------------------------------------------

fn read_slice<'a>(buf: &'a [u8], off: usize, len: usize, what: &str) -> Result<&'a [u8]> {
    let end = off
        .checked_add(len)
        .with_context(|| format!("{what}: offset overflow"))?;
    if end > buf.len() {
        bail!(
            "{what}: range {off}..{end} outside {}-byte buffer",
            buf.len()
        );
    }
    Ok(&buf[off..end])
}

macro_rules! read_num {
    ($name:ident, $ty:ty, $len:expr) => {
        fn $name(buf: &[u8], off: usize) -> Result<$ty> {
            let s = read_slice(buf, off, $len, stringify!($name))?;
            let mut a = [0u8; $len];
            a.copy_from_slice(s);
            Ok(<$ty>::from_le_bytes(a))
        }
    };
}

read_num!(read_u16, u16, 2);
read_num!(read_i16, i16, 2);
read_num!(read_u32, u32, 4);
read_num!(read_i32, i32, 4);
read_num!(read_i64, i64, 8);
read_num!(read_f32, f32, 4);
read_num!(read_f64, f64, 8);

fn read_u8(buf: &[u8], off: usize) -> Result<u8> {
    Ok(read_slice(buf, off, 1, "u8")?[0])
}

#[derive(Debug, Clone, Copy)]
struct Table<'a> {
    buf: &'a [u8],
    pos: usize,
    vtable: usize,
    vtable_len: usize,
}

impl<'a> Table<'a> {
    fn root(buf: &'a [u8]) -> Result<Self> {
        if buf.len() < 4 {
            bail!("buffer too short for a FlatBuffers root");
        }
        Self::at(buf, read_u32(buf, 0)? as usize)
    }

    fn at(buf: &'a [u8], pos: usize) -> Result<Self> {
        let soffset = read_i32(buf, pos)? as i64;
        let vtable = pos as i64 - soffset;
        if vtable < 0 {
            bail!("invalid negative vtable offset");
        }
        let vtable = vtable as usize;
        let vtable_len = read_u16(buf, vtable)? as usize;
        if vtable_len < 4 || vtable_len % 2 != 0 {
            bail!("invalid vtable length {vtable_len}");
        }
        read_slice(buf, vtable, vtable_len, "vtable")?;
        Ok(Self {
            buf,
            pos,
            vtable,
            vtable_len,
        })
    }

    fn field(&self, slot: usize) -> Result<Option<usize>> {
        let vtoff = slot
            .checked_mul(2)
            .and_then(|v| v.checked_add(4))
            .context("vtable slot overflow")?;
        if vtoff + 2 > self.vtable_len {
            return Ok(None);
        }
        let rel = read_u16(self.buf, self.vtable + vtoff)? as usize;
        if rel == 0 {
            return Ok(None);
        }
        let field = self.pos.checked_add(rel).context("field offset overflow")?;
        if field >= self.buf.len() {
            bail!("field {slot} offset outside buffer");
        }
        Ok(Some(field))
    }
}

fn read_string(buf: &[u8], field: usize) -> Result<String> {
    let p = field
        .checked_add(read_u32(buf, field)? as usize)
        .context("string offset overflow")?;
    let len = read_u32(buf, p)? as usize;
    let bytes = read_slice(buf, p + 4, len, "string")?;
    Ok(String::from_utf8_lossy(bytes).into_owned())
}

fn read_vector(buf: &[u8], field: usize) -> Result<(usize, usize)> {
    let p = field
        .checked_add(read_u32(buf, field)? as usize)
        .context("vector offset overflow")?;
    let count = read_u32(buf, p)? as usize;
    if count > buf.len() {
        bail!("vector count {count} exceeds buffer size");
    }
    Ok((p + 4, count))
}

fn read_string_vector(buf: &[u8], field: usize) -> Result<Vec<Value>> {
    let (start, count) = read_vector(buf, field)?;
    read_slice(buf, start, count.saturating_mul(4), "string vector")?;
    let mut out = Vec::with_capacity(count);
    for i in 0..count {
        let elem = start + i * 4;
        let rel = read_u32(buf, elem)? as usize;
        if rel == 0 {
            out.push(Value::Null);
            continue;
        }
        let p = elem
            .checked_add(rel)
            .context("string vector element offset overflow")?;
        let len = read_u32(buf, p)? as usize;
        let bytes = read_slice(buf, p + 4, len, "string vector element")?;
        out.push(Value::String(String::from_utf8_lossy(bytes).into_owned()));
    }
    Ok(out)
}

// ---------------------------------------------------------------------------
// schema meta 行
// ---------------------------------------------------------------------------

fn parse_property(buf: &[u8], pos: usize) -> Result<ObxProperty> {
    let table = Table::at(buf, pos)?;
    let id = read_u32(
        buf,
        table
            .field(1)?
            .context("native schema: missing property ID")?,
    )?;
    let name = read_string(
        buf,
        table
            .field(6)?
            .context("native schema: missing property name")?,
    )?;
    let ty = read_u16(
        buf,
        table
            .field(7)?
            .context("native schema: missing property type")?,
    )?;
    // ID 字段的 flags 在 slot 9；只用来确认 schema 合法性。
    let _flags = table
        .field(9)?
        .map(|f| read_u32(buf, f))
        .transpose()?
        .unwrap_or(0);
    if name.is_empty() {
        bail!("native schema: property ID {id} has an empty name");
    }
    if ty == 0 || ty > T_DATE_NANO_VECTOR {
        bail!("native schema: property {name:?} has unknown type {ty}");
    }
    Ok(ObxProperty { id, name, ty })
}

fn parse_entity(buf: &[u8], expected_id: u32) -> Result<ObxEntity> {
    let root = Table::root(buf)?;
    let name = read_string(
        buf,
        root.field(3)?
            .context("native schema: missing entity name")?,
    )?;
    if name.is_empty() {
        bail!("native schema: entity has an empty name");
    }
    let props_field = root
        .field(4)?
        .context("native schema: missing entity properties")?;
    let (start, count) = read_vector(buf, props_field)?;
    let mut properties = Vec::with_capacity(count);
    for i in 0..count {
        let elem = start + i.saturating_mul(4);
        let target = elem
            .checked_add(read_u32(buf, elem)? as usize)
            .context("property table offset overflow")?;
        properties.push(parse_property(buf, target)?);
    }
    properties.sort_by_key(|p| p.id);
    properties.dedup_by_key(|p| p.id);
    Ok(ObxEntity {
        id: expected_id,
        name,
        properties,
    })
}

fn load_schema(env: &Environment) -> Result<HashMap<u32, ObxEntity>> {
    let db = env.open_db(None)?;
    let txn = env.begin_ro_txn()?;
    let mut cursor = txn.open_ro_cursor(db)?;
    let mut entities = HashMap::new();
    for (key, value) in cursor.iter() {
        if classify_key(key) != Some(KeyKind::Meta) {
            continue;
        }
        let Some(entity_id) = parse_meta_entity_id(key) else {
            continue;
        };
        // key 0 是 platform model 行，没有 entity schema。
        if entity_id == 0 {
            continue;
        }
        let entity = parse_entity(value, entity_id)
            .with_context(|| format!("parse schema meta for entity id {entity_id}"))?;
        if entities.insert(entity.id, entity).is_some() {
            bail!("native schema: duplicate entity ID {entity_id}");
        }
    }
    if entities.is_empty() {
        bail!("no entity schemas found in ObjectBox meta rows");
    }
    Ok(entities)
}

// ---------------------------------------------------------------------------
// object value 解码
// ---------------------------------------------------------------------------

fn decode_value(prop: &ObxProperty, buf: &[u8], field: usize) -> Result<Value> {
    Ok(match prop.ty {
        T_BOOL => Value::Bool(read_u8(buf, field)? != 0),
        T_BYTE => Value::Number((read_u8(buf, field)? as i8 as i64).into()),
        T_SHORT => Value::Number((read_i16(buf, field)? as i64).into()),
        T_CHAR => Value::Number((read_u16(buf, field)? as u64).into()),
        T_INT => Value::Number((read_i32(buf, field)? as i64).into()),
        T_LONG | T_RELATION => Value::Number(read_i64(buf, field)?.into()),
        T_FLOAT => float_value(read_f32(buf, field)? as f64),
        T_DOUBLE => float_value(read_f64(buf, field)?),
        T_STRING => Value::String(read_string(buf, field)?),
        T_DATE | T_DATE_NANO => Value::Number(read_i64(buf, field)?.into()),
        T_FLEX | T_BYTE_VECTOR => {
            let (start, count) = read_vector(buf, field)?;
            let raw = read_slice(buf, start, count, "byte vector")?;
            Value::Array(raw.iter().map(|b| Value::from(*b)).collect())
        }
        T_BOOL_VECTOR => {
            let (start, count) = read_vector(buf, field)?;
            let raw = read_slice(buf, start, count, "bool vector")?;
            Value::Array(raw.iter().map(|b| Value::Bool(*b != 0)).collect())
        }
        T_SHORT_VECTOR => {
            let (start, count) = read_vector(buf, field)?;
            let raw = read_slice(buf, start, count.saturating_mul(2), "short vector")?;
            Value::Array(
                raw.chunks_exact(2)
                    .map(|c| Value::from(i16::from_le_bytes([c[0], c[1]]) as i64))
                    .collect(),
            )
        }
        T_CHAR_VECTOR => {
            let (start, count) = read_vector(buf, field)?;
            let raw = read_slice(buf, start, count.saturating_mul(2), "char vector")?;
            Value::Array(
                raw.chunks_exact(2)
                    .map(|c| Value::from(u16::from_le_bytes([c[0], c[1]]) as u64))
                    .collect(),
            )
        }
        T_INT_VECTOR => {
            let (start, count) = read_vector(buf, field)?;
            let raw = read_slice(buf, start, count.saturating_mul(4), "int vector")?;
            Value::Array(
                raw.chunks_exact(4)
                    .map(|c| Value::from(i32::from_le_bytes([c[0], c[1], c[2], c[3]]) as i64))
                    .collect(),
            )
        }
        T_LONG_VECTOR => {
            let (start, count) = read_vector(buf, field)?;
            let raw = read_slice(buf, start, count.saturating_mul(8), "long vector")?;
            Value::Array(
                raw.chunks_exact(8)
                    .map(|c| Value::from(i64::from_le_bytes(c.try_into().unwrap())))
                    .collect(),
            )
        }
        T_FLOAT_VECTOR => {
            let (start, count) = read_vector(buf, field)?;
            let raw = read_slice(buf, start, count.saturating_mul(4), "float vector")?;
            Value::Array(
                raw.chunks_exact(4)
                    .map(|c| float_value(f32::from_le_bytes([c[0], c[1], c[2], c[3]]) as f64))
                    .collect(),
            )
        }
        T_DOUBLE_VECTOR => {
            let (start, count) = read_vector(buf, field)?;
            let raw = read_slice(buf, start, count.saturating_mul(8), "double vector")?;
            Value::Array(
                raw.chunks_exact(8)
                    .map(|c| float_value(f64::from_le_bytes(c.try_into().unwrap())))
                    .collect(),
            )
        }
        T_STRING_VECTOR => Value::Array(read_string_vector(buf, field)?),
        T_DATE_VECTOR | T_DATE_NANO_VECTOR => {
            let (start, count) = read_vector(buf, field)?;
            let raw = read_slice(buf, start, count.saturating_mul(8), "date vector")?;
            Value::Array(
                raw.chunks_exact(8)
                    .map(|c| Value::from(i64::from_le_bytes(c.try_into().unwrap())))
                    .collect(),
            )
        }
        other => bail!("unsupported property type {other} ({})", prop.name),
    })
}

fn float_value(v: f64) -> Value {
    if v.is_finite() {
        serde_json::Number::from_f64(v)
            .map(Value::Number)
            .unwrap_or(Value::Null)
    } else if v.is_nan() {
        Value::String("NaN".into())
    } else if v.is_sign_positive() {
        Value::String("Infinity".into())
    } else {
        Value::String("-Infinity".into())
    }
}

fn decode_object(entity: &ObxEntity, buf: &[u8], object_id: u64) -> Result<Map<String, Value>> {
    let table = Table::root(buf)?;
    let mut out = Map::new();
    for prop in &entity.properties {
        // vtable slot = property ID - 1（ID 字段本身也写在 value 里，
        // 但 LMDB key 中的 object id 才是权威值）。
        let Some(slot) = prop.id.checked_sub(1).map(|id| id as usize) else {
            bail!("entity {} property {} has ID 0", entity.name, prop.name);
        };
        let Some(field) = table.field(slot)? else {
            continue;
        };
        out.insert(prop.name.clone(), decode_value(prop, buf, field)?);
    }
    out.insert("id".to_string(), Value::Number(object_id.into()));

    // 对少数 ID 字段不叫 `id` 的实体（目前没有）保留原值即可。
    Ok(out)
}

// ---------------------------------------------------------------------------
// public API
// ---------------------------------------------------------------------------

pub fn read_objectbox_database(db_dir: &Path) -> Result<ObxSnapshot> {
    let env = open_env(db_dir)?;
    let entities = load_schema(&env)?;
    let db = env.open_db(None)?;
    let txn = env.begin_ro_txn()?;
    let mut cursor = txn.open_ro_cursor(db)?;

    let mut names: HashMap<u32, String> = HashMap::new();
    for entity in entities.values() {
        names.insert(entity.id, entity.name.clone());
    }

    let mut records: BTreeMap<String, Vec<Map<String, Value>>> = BTreeMap::new();
    let mut object_rows = 0u64;
    let mut skipped_rows = 0u64;

    for (key, value) in cursor.iter() {
        if classify_key(key) != Some(KeyKind::Object) {
            continue;
        }
        let Some((entity_id, object_id)) = parse_object_key(key) else {
            skipped_rows += 1;
            continue;
        };
        let Some(entity) = entities.get(&entity_id) else {
            skipped_rows += 1;
            continue;
        };
        let record = decode_object(entity, value, object_id).with_context(|| {
            format!(
                "decode {} id={} ({} bytes)",
                entity.name,
                object_id,
                value.len()
            )
        })?;
        records.entry(entity.name.clone()).or_default().push(record);
        object_rows += 1;
    }

    let mut entities: Vec<ObxEntity> = entities.into_values().collect();
    entities.sort_by_key(|e| e.id);
    for list in records.values_mut() {
        list.sort_by_key(|record| record.get("id").and_then(Value::as_u64).unwrap_or(0));
    }

    Ok(ObxSnapshot {
        entities,
        records,
        object_rows,
        skipped_rows,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 用真实 App 数据库验证。需要手动指定：
    /// `BREEZE_OBJECTBOX_TEST_DB=D:/.../breeze_db cargo test --offline -- --ignored`
    #[test]
    #[ignore]
    fn reads_real_objectbox_db() {
        let dir = std::env::var("BREEZE_OBJECTBOX_TEST_DB")
            .expect("set BREEZE_OBJECTBOX_TEST_DB to the ObjectBox db directory");
        let snapshot = read_objectbox_database(Path::new(&dir)).unwrap();
        println!(
            "entities={} object_rows={} skipped={}",
            snapshot.entities.len(),
            snapshot.object_rows,
            snapshot.skipped_rows
        );
        for entity in &snapshot.entities {
            let count = snapshot
                .records
                .get(&entity.name)
                .map(Vec::len)
                .unwrap_or(0);
            println!("{} (id={}): {count}", entity.name, entity.id);
        }
        if let Some(rows) = snapshot.records.get("UnifiedComicHistory") {
            if let Some(row) = rows.first() {
                println!("history0 keys: {:?}", row.keys().collect::<Vec<_>>());
                for key in [
                    "id",
                    "uniqueKey",
                    "chapterId",
                    "chapterOrder",
                    "pageIndex",
                    "lastReadAt",
                    "deleted",
                    "createdAt",
                    "updatedAt",
                ] {
                    println!("history0 {key} = {:?}", row.get(key));
                }
            }
        }
        assert!(!snapshot.records.is_empty());
    }

    #[test]
    fn parses_object_keys() {
        assert_eq!(
            parse_object_key(&[0x18, 0x00, 0x00, 0x20, 0x00, 0x00, 0x00, 0x01]),
            Some((8, 1))
        );
        assert_eq!(
            parse_object_key(&[
                0x18, 0x00, 0x00, 0x20, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x02
            ]),
            Some((8, 0x1_0000_0002))
        );
        assert_eq!(
            classify_key(&[0x20, 0x00, 0x00, 0x04, 0, 0, 0, 0]),
            Some(KeyKind::Index)
        );
    }
}
