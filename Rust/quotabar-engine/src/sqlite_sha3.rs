//! `sha3` / `sha3_agg` for the bundled SQLite, matching the SQLite shell's `shathree.c`.
//!
//! - `sha3(X)` hashes a BLOB's bytes and TEXT's UTF-8 bytes; NULL is NULL.
//! - `sha3_agg(Y)` prefixes each value with its type: NULL is `N`, INTEGER is `I` plus big-endian
//!   64-bit, REAL is `F` plus big-endian IEEE-754 bits, TEXT is `T<bytes>:` plus UTF-8 bytes, BLOB
//!   is `B<bytes>:` plus bytes. An aggregate over zero rows is NULL.
//!
//! `sha3(X)` on a REAL rejects with a loud error rather than diverging from printf `%!.15g`.

use rusqlite::functions::{Aggregate, Context, FunctionFlags};
use rusqlite::types::ValueRef;
use rusqlite::{Connection, Error, Result};
use std::io;

const SHA3_SIZES: [usize; 4] = [224, 256, 384, 512];

pub fn register(connection: &Connection) -> Result<()> {
    let flags = FunctionFlags::SQLITE_UTF8 | FunctionFlags::SQLITE_INNOCUOUS | FunctionFlags::SQLITE_DETERMINISTIC;
    connection.create_scalar_function("sha3", 1, flags, |ctx| scalar_sha3(ctx, 0, 256))?;
    connection.create_scalar_function("sha3", 2, flags, |ctx| scalar_sha3(ctx, 0, context_integer(ctx, 1).unwrap_or(0)))?;
    connection.create_aggregate_function("sha3_agg", 1, flags, Sha3Aggregate)?;
    connection.create_aggregate_function("sha3_agg", 2, flags, Sha3Aggregate)?;
    Ok(())
}

fn context_integer(ctx: &Context<'_>, index: usize) -> Option<i64> {
    match ctx.get_raw(index) {
        ValueRef::Integer(value) => Some(value),
        ValueRef::Real(value) => Some(value as i64),
        _ => None,
    }
}

fn aggregate_size(ctx: &Context<'_>) -> usize {
    match ctx.len() {
        2 => match context_integer(ctx, 1) {
            Some(size) if size == 224 || size == 384 || size == 512 => size as usize,
            _ => 256,
        },
        _ => 256,
    }
}

fn scalar_sha3(ctx: &Context<'_>, index: usize, size: i64) -> Result<Option<Vec<u8>>> {
    let bits = usize::try_from(size)
        .ok()
        .filter(|bits| SHA3_SIZES.contains(bits))
        .ok_or_else(|| user_error("SHA3 size should be one of: 224 256 384 512"))?;
    match ctx.get_raw(index) {
        ValueRef::Null => Ok(None),
        ValueRef::Blob(bytes) | ValueRef::Text(bytes) => Ok(Some(sha3(bytes, bits))),
        ValueRef::Integer(value) => Ok(Some(sha3(value.to_string().as_bytes(), bits))),
        ValueRef::Real(_) => Err(user_error(
            "sha3: REAL arguments are not supported by the in-process engine; cast to TEXT or BLOB",
        )),
    }
}

fn user_error(message: &str) -> Error {
    Error::UserFunctionError(Box::new(io::Error::new(io::ErrorKind::InvalidInput, message)))
}

struct Sha3Aggregate;

impl Aggregate<Sha3, Option<Vec<u8>>> for Sha3Aggregate {
    fn init(&self, ctx: &mut Context<'_>) -> Result<Sha3> {
        Ok(Sha3::new(aggregate_size(ctx)))
    }

    fn step(&self, ctx: &mut Context<'_>, state: &mut Sha3) -> Result<()> {
        match ctx.get_raw(0) {
            ValueRef::Null => state.update(b"N"),
            ValueRef::Integer(value) => {
                let mut encoded = [0u8; 9];
                encoded[0] = b'I';
                encoded[1..].copy_from_slice(&value.to_be_bytes());
                state.update(&encoded);
            }
            ValueRef::Real(value) => {
                let mut encoded = [0u8; 9];
                encoded[0] = b'F';
                encoded[1..].copy_from_slice(&value.to_bits().to_be_bytes());
                state.update(&encoded);
            }
            ValueRef::Text(bytes) => {
                state.update(format!("T{}:", bytes.len()).as_bytes());
                state.update(bytes);
            }
            ValueRef::Blob(bytes) => {
                state.update(format!("B{}:", bytes.len()).as_bytes());
                state.update(bytes);
            }
        }
        Ok(())
    }

    fn finalize(&self, _ctx: &mut Context<'_>, state: Option<Sha3>) -> Result<Option<Vec<u8>>> {
        Ok(state.map(Sha3::finalize))
    }
}

struct Sha3 {
    state: [u64; 25],
    rate: usize,
    output: usize,
    loaded: usize,
}

impl Sha3 {
    fn new(bits: usize) -> Self {
        let rate = (1600 - 2 * bits) / 8;
        Self { state: [0; 25], rate, output: bits / 8, loaded: 0 }
    }

    fn update(&mut self, mut data: &[u8]) {
        while !data.is_empty() {
            let take = (self.rate - self.loaded).min(data.len());
            for (offset, byte) in data[..take].iter().enumerate() {
                let position = self.loaded + offset;
                self.state[position / 8] ^= u64::from(*byte) << (8 * (position % 8));
            }
            self.loaded += take;
            data = &data[take..];
            if self.loaded == self.rate {
                keccak_f1600(&mut self.state);
                self.loaded = 0;
            }
        }
    }

    fn finalize(mut self) -> Vec<u8> {
        self.state[self.loaded / 8] ^= 0x06u64 << (8 * (self.loaded % 8));
        let last = self.rate - 1;
        self.state[last / 8] ^= 0x80u64 << (8 * (last % 8));
        keccak_f1600(&mut self.state);
        (0..self.output).map(|index| (self.state[index / 8] >> (8 * (index % 8))) as u8).collect()
    }
}

fn sha3(data: &[u8], bits: usize) -> Vec<u8> {
    let mut hash = Sha3::new(bits);
    hash.update(data);
    hash.finalize()
}

fn keccak_f1600(a: &mut [u64; 25]) {
    const ROUND_CONSTANTS: [u64; 24] = [
        0x0000_0000_0000_0001, 0x0000_0000_0000_8082, 0x8000_0000_0000_808a, 0x8000_0000_8000_8000,
        0x0000_0000_0000_808b, 0x0000_0000_8000_0001, 0x8000_0000_8000_8081, 0x8000_0000_0000_8009,
        0x0000_0000_0000_008a, 0x0000_0000_0000_0088, 0x0000_0000_8000_8009, 0x0000_0000_8000_000a,
        0x0000_0000_8000_808b, 0x8000_0000_0000_008b, 0x8000_0000_0000_8089, 0x8000_0000_0000_8003,
        0x8000_0000_0000_8002, 0x8000_0000_0000_0080, 0x0000_0000_0000_800a, 0x8000_0000_8000_000a,
        0x8000_0000_8000_8081, 0x8000_0000_0000_8080, 0x0000_0000_8000_0001, 0x8000_0000_8000_8008,
    ];
    const ROTATIONS: [u32; 24] = [1, 3, 6, 10, 15, 21, 28, 36, 45, 55, 2, 14, 27, 41, 56, 8, 25, 43, 62, 18, 39, 61, 20, 44];
    const PI_LANES: [usize; 24] = [10, 7, 11, 17, 18, 3, 5, 16, 8, 21, 24, 4, 15, 23, 19, 13, 12, 2, 20, 14, 22, 9, 6, 1];

    for rc in ROUND_CONSTANTS {
        let mut columns = [0u64; 5];
        for (x, column) in columns.iter_mut().enumerate() {
            *column = a[x] ^ a[x + 5] ^ a[x + 10] ^ a[x + 15] ^ a[x + 20];
        }
        for x in 0..5 {
            let delta = columns[(x + 4) % 5] ^ columns[(x + 1) % 5].rotate_left(1);
            for y in 0..5 {
                a[x + 5 * y] ^= delta;
            }
        }
        let mut carried = a[1];
        for lane in 0..24 {
            let target = PI_LANES[lane];
            let next = a[target];
            a[target] = carried.rotate_left(ROTATIONS[lane]);
            carried = next;
        }
        for y in 0..5 {
            let row = [a[5 * y], a[5 * y + 1], a[5 * y + 2], a[5 * y + 3], a[5 * y + 4]];
            for x in 0..5 {
                a[5 * y + x] = row[x] ^ ((!row[(x + 1) % 5]) & row[(x + 2) % 5]);
            }
        }
        a[0] ^= rc;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sqlite::{open_read_only, query_text};
    use tempfile::NamedTempFile;

    fn seeded(sql: &str) -> NamedTempFile {
        let file = NamedTempFile::new().unwrap();
        let conn = Connection::open(file.path()).unwrap();
        conn.execute_batch(sql).unwrap();
        file
    }

    fn hex(bytes: &[u8]) -> String {
        bytes.iter().map(|b| format!("{b:02X}")).collect()
    }

    #[test]
    fn known_sha3_vectors_match_fips_202() {
        assert_eq!(hex(&sha3(b"", 256)), "A7FFC6F8BF1ED76651C14756A061D662F580FF4DE43B49FA82D80A4B80F8434A");
        assert_eq!(hex(&sha3(b"abc", 256)), "3A985DA74FE225B2045C172D6BD390BD855F086E3E9D525B46BFE24511431532");
        assert_eq!(hex(&sha3(b"abc", 512)), "B751850B1A57168A5693CD924B6B096E08F621827444F70D884F5D0240D2712E10E116E9192AF3C91A7EC57647E3934057340B4CF408D5A56592F8274EEC53F0");
        assert_eq!(hex(&sha3(b"abc", 224)), "E642824C3F8CF24AD09234EE7D3C766FC9A3A5168D0C94AD73B46FDF");
    }

    #[test]
    fn block_boundary_and_binary_inputs_hash_exact_bytes() {
        assert_eq!(hex(&sha3(&vec![0xA3; 134], 256)), "DC08CF7A2561019DC6BEA3E6A8321FFB1D94618234EF605407246EE2D98503DD");
        assert_eq!(hex(&sha3(&vec![0xA3; 135], 256)), "D51927265CA4BF0CC8B4453387700918C03F8894E395AD437D4573F3BE4D2C34");
        assert_eq!(hex(&sha3(&vec![0xA3; 136], 256)), "0ADF6BFB359AE40019B67D8C49C361574B70242A6B752DE6F9E0D426CA177F7A");
        assert_eq!(hex(&sha3(&vec![0xA3; 137], 256)), "E2FA06EAA22FE60106AF67D5F6EA093FE58F07D2DCFB06D51057953F114849A7");
        assert_eq!(hex(&sha3("héllo — 漢字".as_bytes(), 256)), "DB8D1D2DB81381690D1CC6BC64E8290F88D2C572403573DCDD1F10A5A8C262BB");
        assert_eq!(hex(&sha3(b"a\0b", 256)), "B476FD9CC202C304856E5B838839A737FBAAA96A2F44808F8C28C8CFF135DB22");
    }

    #[test]
    fn aggregate_and_scalar_encoding_match_cli() {
        let db = seeded(
            "CREATE TABLE text_values(v); INSERT INTO text_values VALUES('xyzzy');
             CREATE TABLE blob_values(v); INSERT INTO blob_values VALUES(x'010203');
             CREATE TABLE mixed(v); INSERT INTO mixed VALUES('a' || char(233)), (NULL), (x''), ('');",
        );
        let q = |sql: &str| query_text(db.path(), sql, false).unwrap();
        assert_eq!(q("SELECT hex(sha3_agg(v)) FROM text_values;").as_deref(), Some("F0EE07121659E51396268FFD44F6CF5A846D0F3AFCC8CAFD3DF355B5C39B7714"));
        assert_eq!(q("SELECT hex(sha3_agg(v)) FROM blob_values;").as_deref(), Some("BFBB654D136BB56C5D89B6AC613976B305CCE3C742E2258ACCACBC02E2A66636"));
        assert_eq!(q("SELECT hex(sha3_agg(v)) FROM mixed;").as_deref(), Some("DBE6E4CBCE7E950DDB8B81215EA1DFB23425FF4098C4C1C10E875C426746B310"));
        assert_eq!(q("SELECT hex(sha3_agg(x)) FROM (SELECT 100.015625 AS x);").as_deref(), Some("68FD5A3E7E1937BCB6CBCA67982D56270F0DC302AAD76FF4CBF88654462486EB"));
        assert_eq!(q("SELECT hex(sha3_agg(x)) FROM (SELECT NULL AS x);").as_deref(), Some("345BAAA13BBE3A40695DB7697FBE3F64206323B77CF3635902106F9F29667361"));
        assert_eq!(q("SELECT hex(sha3_agg(v)) FROM text_values WHERE 0;"), None);
        assert_eq!(q("SELECT hex(sha3('hello'));").as_deref(), Some("3338BE694F50C5F338814986CDF0686453A888B84F424D792AF4B9202398F392"));
        assert_eq!(q("SELECT hex(sha3(1));").as_deref(), Some("67B176705B46206614219F47A05AEE7AE6A3EDBE850BBBE214C536B989AEA4D2"));
        assert_eq!(q("SELECT hex(sha3(NULL));"), None);
        assert!(query_text(db.path(), "SELECT hex(sha3('x', 200));", false).is_err());

        let conn = open_read_only(db.path()).unwrap().unwrap();
        let digest: String = conn.query_row("SELECT hex(sha3('hello'))", [], |row| row.get(0)).unwrap();
        assert_eq!(digest.len(), 64);
    }
}
