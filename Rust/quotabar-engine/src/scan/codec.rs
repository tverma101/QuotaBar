//! Compact binary encoding for persisted scan records.
//!
//! The Swift backend persisted parsed rows as property lists (≈116 MB for one machine's Claude and
//! Codex history). Rows here are a few varints and doubles, and strings repeated inside one blob
//! (model names, session ids) are written once and referenced by index afterwards, which also lets
//! the decoder share one `Arc<str>` per distinct value in memory.

use std::collections::HashMap;
use std::sync::Arc;

/// A value that can be persisted in a scan-cache blob.
pub trait Record: Sized {
    fn encode(&self, w: &mut Writer);
    /// `None` means the blob is corrupt or from an incompatible layout; the caller re-parses the file.
    fn decode(r: &mut Reader<'_>) -> Option<Self>;
}

impl Record for () {
    fn encode(&self, _w: &mut Writer) {}
    fn decode(_r: &mut Reader<'_>) -> Option<Self> {
        Some(())
    }
}

#[derive(Default)]
pub struct Writer {
    buf: Vec<u8>,
    strings: HashMap<Arc<str>, u64>,
}

impl Writer {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn into_bytes(self) -> Vec<u8> {
        self.buf
    }

    pub fn varint(&mut self, mut value: u64) {
        while value >= 0x80 {
            self.buf.push((value as u8) | 0x80);
            value >>= 7;
        }
        self.buf.push(value as u8);
    }

    pub fn i64(&mut self, value: i64) {
        self.varint(((value << 1) ^ (value >> 63)) as u64);
    }

    pub fn f64(&mut self, value: f64) {
        self.buf.extend_from_slice(&value.to_bits().to_le_bytes());
    }

    pub fn bool(&mut self, value: bool) {
        self.buf.push(value as u8);
    }

    pub fn bytes(&mut self, value: &[u8]) {
        self.varint(value.len() as u64);
        self.buf.extend_from_slice(value);
    }

    /// A string, written once per blob: later occurrences are an index into the earlier ones.
    pub fn str(&mut self, value: &str) {
        if let Some(index) = self.strings.get(value) {
            self.varint(index + 1);
            return;
        }
        let index = self.strings.len() as u64;
        self.strings.insert(Arc::from(value), index);
        self.varint(0);
        self.bytes(value.as_bytes());
    }

    pub fn opt_str(&mut self, value: Option<&str>) {
        match value {
            None => self.bool(false),
            Some(value) => {
                self.bool(true);
                self.str(value);
            }
        }
    }

    pub fn opt_f64(&mut self, value: Option<f64>) {
        match value {
            None => self.bool(false),
            Some(value) => {
                self.bool(true);
                self.f64(value);
            }
        }
    }

    pub fn seq<T: Record>(&mut self, items: &[T]) {
        self.varint(items.len() as u64);
        for item in items {
            item.encode(self);
        }
    }
}

pub struct Reader<'a> {
    buf: &'a [u8],
    strings: Vec<Arc<str>>,
}

impl<'a> Reader<'a> {
    pub fn new(buf: &'a [u8]) -> Self {
        Reader { buf, strings: Vec::new() }
    }

    pub fn is_empty(&self) -> bool {
        self.buf.is_empty()
    }

    pub fn varint(&mut self) -> Option<u64> {
        let mut value = 0u64;
        for shift in (0..64).step_by(7) {
            let (&byte, rest) = self.buf.split_first()?;
            self.buf = rest;
            value |= u64::from(byte & 0x7f) << shift;
            if byte & 0x80 == 0 {
                return Some(value);
            }
        }
        None
    }

    pub fn i64(&mut self) -> Option<i64> {
        let raw = self.varint()?;
        Some(((raw >> 1) as i64) ^ -((raw & 1) as i64))
    }

    pub fn f64(&mut self) -> Option<f64> {
        let (head, rest) = self.buf.split_at_checked(8)?;
        self.buf = rest;
        Some(f64::from_bits(u64::from_le_bytes(head.try_into().ok()?)))
    }

    pub fn bool(&mut self) -> Option<bool> {
        let (&byte, rest) = self.buf.split_first()?;
        self.buf = rest;
        match byte {
            0 => Some(false),
            1 => Some(true),
            _ => None,
        }
    }

    pub fn bytes(&mut self) -> Option<&'a [u8]> {
        let len = usize::try_from(self.varint()?).ok()?;
        let (head, rest) = self.buf.split_at_checked(len)?;
        self.buf = rest;
        Some(head)
    }

    pub fn str(&mut self) -> Option<Arc<str>> {
        match self.varint()? {
            0 => {
                let text: Arc<str> = Arc::from(std::str::from_utf8(self.bytes()?).ok()?);
                self.strings.push(text.clone());
                Some(text)
            }
            index => self.strings.get(usize::try_from(index - 1).ok()?).cloned(),
        }
    }

    pub fn opt_str(&mut self) -> Option<Option<Arc<str>>> {
        if self.bool()? {
            Some(Some(self.str()?))
        } else {
            Some(None)
        }
    }

    pub fn opt_f64(&mut self) -> Option<Option<f64>> {
        if self.bool()? {
            Some(Some(self.f64()?))
        } else {
            Some(None)
        }
    }

    pub fn seq<T: Record>(&mut self) -> Option<Vec<T>> {
        let count = usize::try_from(self.varint()?).ok()?;
        // A corrupt length must not trigger a huge allocation: every record takes at least one byte.
        let mut items = Vec::with_capacity(count.min(self.buf.len()));
        for _ in 0..count {
            items.push(T::decode(self)?);
        }
        Some(items)
    }
}

/// Encode one value into a standalone blob.
pub fn to_bytes<T: Record>(value: &T) -> Vec<u8> {
    let mut w = Writer::new();
    value.encode(&mut w);
    w.into_bytes()
}

/// Decode a standalone blob; trailing bytes count as corruption.
pub fn from_bytes<T: Record>(bytes: &[u8]) -> Option<T> {
    let mut r = Reader::new(bytes);
    let value = T::decode(&mut r)?;
    r.is_empty().then_some(value)
}

/// A sequence blob (`Vec<T>` is not itself a `Record`, so callers use these helpers).
pub fn seq_to_bytes<T: Record>(items: &[T]) -> Vec<u8> {
    let mut w = Writer::new();
    w.seq(items);
    w.into_bytes()
}

pub fn seq_from_bytes<T: Record>(bytes: &[u8]) -> Option<Vec<T>> {
    let mut r = Reader::new(bytes);
    let items = r.seq()?;
    r.is_empty().then_some(items)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Debug, PartialEq)]
    struct Row {
        n: i64,
        x: f64,
        model: Option<Arc<str>>,
        cost: Option<f64>,
    }

    impl Record for Row {
        fn encode(&self, w: &mut Writer) {
            w.i64(self.n);
            w.f64(self.x);
            w.opt_str(self.model.as_deref());
            w.opt_f64(self.cost);
        }
        fn decode(r: &mut Reader<'_>) -> Option<Self> {
            Some(Row { n: r.i64()?, x: r.f64()?, model: r.opt_str()?, cost: r.opt_f64()? })
        }
    }

    #[test]
    fn round_trips_and_shares_repeated_strings() {
        let rows = vec![
            Row { n: -5, x: 1.5, model: Some("claude-opus-4".into()), cost: None },
            Row { n: i64::MAX, x: -0.0, model: Some("claude-opus-4".into()), cost: Some(0.25) },
            Row { n: 0, x: f64::MAX, model: None, cost: Some(1e12) },
        ];
        let blob = seq_to_bytes(&rows);
        let decoded: Vec<Row> = seq_from_bytes(&blob).unwrap();
        assert_eq!(decoded, rows);
        assert!(Arc::ptr_eq(decoded[0].model.as_ref().unwrap(), decoded[1].model.as_ref().unwrap()));
        // The second occurrence is a one-byte back reference, not a second copy.
        assert_eq!(blob.windows(13).filter(|w| *w == b"claude-opus-4").count(), 1);
    }

    #[test]
    fn corrupt_blobs_decode_to_none() {
        let blob = seq_to_bytes(&[Row { n: 1, x: 2.0, model: Some("m".into()), cost: None }]);
        assert!(seq_from_bytes::<Row>(&blob[..blob.len() - 1]).is_none());
        let mut trailing = blob.clone();
        trailing.push(0);
        assert!(seq_from_bytes::<Row>(&trailing).is_none());
        // An absurd element count fails without allocating for it.
        assert!(seq_from_bytes::<Row>(&[0xff, 0xff, 0xff, 0xff, 0x0f]).is_none());
    }
}
