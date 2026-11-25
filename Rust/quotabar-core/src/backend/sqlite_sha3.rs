//! `sha3` / `sha3_agg` for the bundled SQLite, matching the SQLite shell's `shathree.c`.
//!
//! Antigravity's cache fingerprints hash blobs and ordered text inside SQLite. `/usr/bin/sqlite3`
//! loads the shell extension that provides these functions; the bundled library did not, so every
//! changed modern database fell back to the bounded row verifier and re-read its whole history.
//! Registering them per connection closes that gap without changing a single provider statement.
//!
//! The encoding is the shell extension's, not just "SHA3 of the bytes":
//!
//! - `sha3(X)` hashes a BLOB's bytes and TEXT's UTF-8 bytes; NULL is NULL.
//! - `sha3_agg(Y)` prefixes each value with its type: NULL is `N`, INTEGER is `I` plus the
//!   big-endian two's-complement 64-bit value, REAL is `F` plus the big-endian IEEE-754 bits, TEXT
//!   is `T<bytes>:` plus the UTF-8 bytes, and BLOB is `B<bytes>:` plus the bytes. An aggregate over
//!   zero rows is NULL.
//!
//! A digest that differs from the CLI's by one byte would let caches keyed on it keep stale rows,
//! so every branch above is pinned against `/usr/bin/sqlite3` by tests in this module and by
//! `AntigravityRustParityTests.testSHA3MatchesSQLiteCLIOverAdversarialInputs`.
//!
//! `sha3(X)` on a REAL is the one unsupported input: SQLite renders it with printf's `%!.15g`,
//! which this module does not reproduce, and a silently different digest would be worse than a
//! loud error. No provider statement hashes a REAL (`sha3_agg`'s REAL encoding is binary and
//! exact), so the error cannot fire on a supported query.

use std::io;

use rusqlite::functions::{Aggregate, Context, FunctionFlags};
use rusqlite::types::ValueRef;
use rusqlite::{Connection, Error, Result};

const SHA3_SIZES: [usize; 4] = [224, 256, 384, 512];

pub(crate) fn register(connection: &Connection) -> Result<()> {
    let flags = FunctionFlags::SQLITE_UTF8
        | FunctionFlags::SQLITE_INNOCUOUS
        | FunctionFlags::SQLITE_DETERMINISTIC;
    // Both arities are registered because the shell extension accepts an optional output size;
    // the providers only use one argument, which defaults to SHA3-256.
    connection.create_scalar_function("sha3", 1, flags, |ctx| scalar_sha3(ctx, 0, 256))?;
    connection.create_scalar_function("sha3", 2, flags, |ctx| {
        scalar_sha3(ctx, 0, context_integer(ctx, 1).unwrap_or(0))
    })?;
    connection.create_aggregate_function("sha3_agg", 1, flags, Sha3Aggregate)?;
    connection.create_aggregate_function("sha3_agg", 2, flags, Sha3Aggregate)?;
    Ok(())
}

/// `sqlite3_value_int` semantics for the size argument, where only 224/384/512 select a variant
/// and everything else (including 256) is the default. The shell extension treats a malformed
/// `sha3_agg` size as 256 rather than raising, so this does too.
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
    Error::UserFunctionError(Box::new(io::Error::new(
        io::ErrorKind::InvalidInput,
        message,
    )))
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

/// SHA3 digest with `bits` output, as FIPS 202 defines it (and `shathree.c` implements it).
struct Sha3 {
    state: [u64; 25],
    rate: usize,
    output: usize,
    loaded: usize,
}

impl Sha3 {
    fn new(bits: usize) -> Self {
        let rate = (1600 - 2 * bits) / 8;
        Self {
            state: [0; 25],
            rate,
            output: bits / 8,
            loaded: 0,
        }
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
        // SHA3 domain separation: append 0x06 and the final 0x80 bit, which share a byte only when
        // exactly one byte of rate remains.
        self.state[self.loaded / 8] ^= 0x06u64 << (8 * (self.loaded % 8));
        let last = self.rate - 1;
        self.state[last / 8] ^= 0x80u64 << (8 * (last % 8));
        keccak_f1600(&mut self.state);

        (0..self.output)
            .map(|index| (self.state[index / 8] >> (8 * (index % 8))) as u8)
            .collect()
    }
}

fn sha3(data: &[u8], bits: usize) -> Vec<u8> {
    let mut hash = Sha3::new(bits);
    hash.update(data);
    hash.finalize()
}

/// Keccak-f[1600] over A\[x + 5y\]; the same permutation the SQLite shell's `SHA3Context` runs.
fn keccak_f1600(a: &mut [u64; 25]) {
    const ROUND_CONSTANTS: [u64; 24] = [
        0x0000_0000_0000_0001,
        0x0000_0000_0000_8082,
        0x8000_0000_0000_808a,
        0x8000_0000_8000_8000,
        0x0000_0000_0000_808b,
        0x0000_0000_8000_0001,
        0x8000_0000_8000_8081,
        0x8000_0000_0000_8009,
        0x0000_0000_0000_008a,
        0x0000_0000_0000_0088,
        0x0000_0000_8000_8009,
        0x0000_0000_8000_000a,
        0x0000_0000_8000_808b,
        0x8000_0000_0000_008b,
        0x8000_0000_0000_8089,
        0x8000_0000_0000_8003,
        0x8000_0000_0000_8002,
        0x8000_0000_0000_0080,
        0x0000_0000_0000_800a,
        0x8000_0000_8000_000a,
        0x8000_0000_8000_8081,
        0x8000_0000_0000_8080,
        0x0000_0000_8000_0001,
        0x8000_0000_8000_8008,
    ];
    const ROTATIONS: [u32; 24] = [
        1, 3, 6, 10, 15, 21, 28, 36, 45, 55, 2, 14, 27, 41, 56, 8, 25, 43, 62, 18, 39, 61, 20, 44,
    ];
    const PI_LANES: [usize; 24] = [
        10, 7, 11, 17, 18, 3, 5, 16, 8, 21, 24, 4, 15, 23, 19, 13, 12, 2, 20, 14, 22, 9, 6, 1,
    ];

    for round in 0..24 {
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
            let row = [
                a[5 * y],
                a[5 * y + 1],
                a[5 * y + 2],
                a[5 * y + 3],
                a[5 * y + 4],
            ];
            for x in 0..5 {
                a[5 * y + x] = row[x] ^ ((!row[(x + 1) % 5]) & row[(x + 2) % 5]);
            }
        }

        a[0] ^= ROUND_CONSTANTS[round];
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::OpenFlags;
    use serde_json::{json, Value};
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::{SystemTime, UNIX_EPOCH};

    fn fixture_path() -> String {
        static SEQUENCE: AtomicU64 = AtomicU64::new(0);
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        std::env::temp_dir()
            .join(format!(
                "quotabar-sha3-{}-{nonce}-{}.db",
                std::process::id(),
                SEQUENCE.fetch_add(1, Ordering::Relaxed)
            ))
            .to_string_lossy()
            .into_owned()
    }

    fn seeded(sql: &str) -> String {
        let path = fixture_path();
        let connection = Connection::open(&path).expect("open fixture");
        connection.execute_batch(sql).expect("seed fixture");
        drop(connection);
        path
    }

    fn call(path: &str, sql: &str) -> Value {
        crate::backend::sqlite::query(&json!({ "path": path, "sql": sql })).expect("query")
    }

    fn hex(bytes: &[u8]) -> String {
        bytes.iter().map(|byte| format!("{byte:02X}")).collect()
    }

    #[test]
    fn known_sha3_vectors_match_fips_202() {
        assert_eq!(
            hex(&sha3(b"", 256)),
            "A7FFC6F8BF1ED76651C14756A061D662F580FF4DE43B49FA82D80A4B80F8434A"
        );
        assert_eq!(
            hex(&sha3(b"abc", 256)),
            "3A985DA74FE225B2045C172D6BD390BD855F086E3E9D525B46BFE24511431532"
        );
        assert_eq!(
            hex(&sha3(b"abc", 512)),
            "B751850B1A57168A5693CD924B6B096E08F621827444F70D884F5D0240D2712E10E116E9192AF3C91A7EC57647E3934057340B4CF408D5A56592F8274EEC53F0"
        );
        assert_eq!(
            hex(&sha3(b"abc", 224)),
            "E642824C3F8CF24AD09234EE7D3C766FC9A3A5168D0C94AD73B46FDF"
        );
    }

    /// SHA3-256's rate is 136 bytes, so absorption must be continuous across 134/135/136/137 and
    /// the padding must stay correct when exactly one byte of the rate remains. Expected digests
    /// come from `/usr/bin/sqlite3` (`hex(sha3(zeroblob? …))` over the same bytes).
    #[test]
    fn block_boundary_inputs_match_the_cli() {
        let cases = [
            (
                134usize,
                "DC08CF7A2561019DC6BEA3E6A8321FFB1D94618234EF605407246EE2D98503DD",
            ),
            (
                135,
                "D51927265CA4BF0CC8B4453387700918C03F8894E395AD437D4573F3BE4D2C34",
            ),
            (
                136,
                "0ADF6BFB359AE40019B67D8C49C361574B70242A6B752DE6F9E0D426CA177F7A",
            ),
            (
                137,
                "E2FA06EAA22FE60106AF67D5F6EA093FE58F07D2DCFB06D51057953F114849A7",
            ),
            (
                272,
                "C4742D97AD8FF950C0B5B078600AB1908C864C75B60F419E2D208DFC26A8BA11",
            ),
        ];
        for (length, expected) in cases {
            assert_eq!(
                hex(&sha3(&vec![0xA3; length], 256)),
                expected,
                "length {length}"
            );
        }
    }

    /// Multibyte text, embedded NULs, and bytes above 0x7F are hashed as UTF-8/binary, never as a
    /// C string, and never through a lossy conversion.
    #[test]
    fn binary_and_utf8_inputs_hash_without_transformation() {
        assert_eq!(
            hex(&sha3("héllo — 漢字".as_bytes(), 256)),
            "DB8D1D2DB81381690D1CC6BC64E8290F88D2C572403573DCDD1F10A5A8C262BB"
        );
        assert_eq!(
            hex(&sha3(b"a\0b", 256)),
            "B476FD9CC202C304856E5B838839A737FBAAA96A2F44808F8C28C8CFF135DB22"
        );
        assert_eq!(
            hex(&sha3(&[0x00, 0xFF, 0x80, 0x00], 256)),
            "27868B189BF05C8122C14D985220ABED980EF68F7BD402AA205FC6016975AFD8"
        );
    }

    /// The shell extension's aggregate encoding, verified against `/usr/bin/sqlite3`: TEXT and
    /// BLOB lengths are decimal ASCII prefixes, numbers are binary with a type tag, NULL still
    /// contributes `N`, and an aggregate over zero rows is NULL.
    #[test]
    fn aggregate_encoding_matches_the_cli() {
        let path = seeded(
            "CREATE TABLE text_values(v);\n             INSERT INTO text_values VALUES('xyzzy');\n             CREATE TABLE blob_values(v);\n             INSERT INTO blob_values VALUES(x'010203');\n             CREATE TABLE mixed(v);\n             INSERT INTO mixed VALUES('a' || char(233)), (NULL), (x''), ('');",
        );
        assert_eq!(
            call(&path, "SELECT hex(sha3_agg(v)) FROM text_values;")["value"],
            "F0EE07121659E51396268FFD44F6CF5A846D0F3AFCC8CAFD3DF355B5C39B7714"
        );
        assert_eq!(
            call(&path, "SELECT hex(sha3_agg(v)) FROM blob_values;")["value"],
            "BFBB654D136BB56C5D89B6AC613976B305CCE3C742E2258ACCACBC02E2A66636"
        );
        assert_eq!(
            call(&path, "SELECT hex(sha3_agg(v)) FROM mixed;")["value"],
            "DBE6E4CBCE7E950DDB8B81215EA1DFB23425FF4098C4C1C10E875C426746B310"
        );
        assert_eq!(
            call(
                &path,
                "SELECT hex(sha3_agg(x)) FROM (SELECT 0x123456 AS x);"
            )["value"],
            "E51F3BCBD00CCF1309C51998EFF295424A2316BAB7AC77A3B3108ACE2750D668"
        );
        assert_eq!(
            call(
                &path,
                "SELECT hex(sha3_agg(x)) FROM (SELECT 100.015625 AS x);"
            )["value"],
            "68FD5A3E7E1937BCB6CBCA67982D56270F0DC302AAD76FF4CBF88654462486EB"
        );
        assert_eq!(
            call(&path, "SELECT hex(sha3_agg(x)) FROM (SELECT NULL AS x);")["value"],
            "345BAAA13BBE3A40695DB7697FBE3F64206323B77CF3635902106F9F29667361"
        );
        let empty = call(&path, "SELECT hex(sha3_agg(v)) FROM text_values WHERE 0;");
        assert!(empty["value"].is_null());
        assert!(empty["error"].is_null());
        let _ = std::fs::remove_file(path);
    }

    /// Scalar `sha3` hashes a BLOB's bytes, TEXT's UTF-8 bytes, and an INTEGER's decimal text;
    /// NULL is NULL. This is the same mapping the CLI documents (`sha3('hello') = sha3(x'68656c6c6f')`).
    #[test]
    fn scalar_values_use_content_and_text_rendering() {
        let path = seeded("CREATE TABLE t(v);");
        assert_eq!(
            call(&path, "SELECT hex(sha3(x'68656c6c6f'));")["value"],
            "3338BE694F50C5F338814986CDF0686453A888B84F424D792AF4B9202398F392"
        );
        assert_eq!(
            call(&path, "SELECT hex(sha3('hello'));")["value"],
            "3338BE694F50C5F338814986CDF0686453A888B84F424D792AF4B9202398F392"
        );
        assert_eq!(
            call(&path, "SELECT hex(sha3(1));")["value"],
            "67B176705B46206614219F47A05AEE7AE6A3EDBE850BBBE214C536B989AEA4D2"
        );
        assert_eq!(
            call(&path, "SELECT hex(sha3(-7));"),
            call(&path, "SELECT hex(sha3('-7'));")
        );
        let null = call(&path, "SELECT hex(sha3(NULL));");
        assert!(null["value"].is_null());
        assert!(null["error"].is_null());
        let invalid = call(&path, "SELECT hex(sha3('x', 200));");
        assert!(invalid["value"].is_null());
        assert!(invalid["error"]
            .as_str()
            .expect("error string")
            .contains("SHA3 size should be one of"));
        let _ = std::fs::remove_file(path);
    }

    /// The functions are registered on every connection the primitive opens, including the
    /// read-write retry, and registration must not turn a read-only open into a write.
    #[test]
    #[ignore = "temporary measurement"]
    fn measure_digest_cost() {
        let path = fixture_path();
        let connection = Connection::open(&path).unwrap();
        connection
            .execute_batch(
                "CREATE TABLE gen_metadata(idx INTEGER PRIMARY KEY, data BLOB);\n                 CREATE TABLE steps(idx INTEGER PRIMARY KEY, metadata BLOB);",
            )
            .unwrap();
        let blob: Vec<u8> = (0..150u32).map(|i| (i % 251) as u8).collect();
        let step: Vec<u8> = (0..120u32).map(|i| (i % 241) as u8).collect();
        connection.execute_batch("BEGIN").unwrap();
        {
            let mut gen = connection
                .prepare("INSERT INTO gen_metadata VALUES(?, ?)")
                .unwrap();
            let mut steps = connection
                .prepare("INSERT INTO steps VALUES(?, ?)")
                .unwrap();
            for index in 0..10_000i64 {
                gen.execute(rusqlite::params![index, blob]).unwrap();
                steps.execute(rusqlite::params![index, step]).unwrap();
            }
        }
        connection.execute_batch("COMMIT").unwrap();
        register(&connection).unwrap();

        let start = std::time::Instant::now();
        let digest: String = connection
            .query_row(
                "WITH rows AS MATERIALIZED (\n                    SELECT g.idx, length(g.data) AS byteCount,\n                        CASE WHEN length(g.data) <= 1048576\n                            THEN hex(sha3(g.data, 256)) ELSE 'oversized' END AS rowDigest,\n                        COALESCE((SELECT CASE WHEN metadata IS NULL THEN 'missing' WHEN length(metadata) <= 1048576 THEN hex(sha3(metadata, 256)) ELSE 'oversized' END FROM steps WHERE idx = g.idx), 'missing') AS stepDigest\n                    FROM gen_metadata g\n                    WHERE g.data IS NOT NULL\n                )\n                SELECT COALESCE(MAX(idx), -1) || '|' ||\n                    COALESCE(hex(sha3_agg(CASE WHEN idx <= 9999 THEN printf('%d:%d:%s:%s;', idx, byteCount, rowDigest, stepDigest) END ORDER BY idx)), '') || '|' ||\n                    COALESCE(hex(sha3_agg(printf('%d:%d:%s:%s;', idx, byteCount, rowDigest, stepDigest) ORDER BY idx)), '')\n                FROM rows",
                [],
                |row| row.get(0),
            )
            .unwrap();
        let digest_ms = start.elapsed().as_secs_f64() * 1000.0;

        let start = std::time::Instant::now();
        let _: i64 = connection
            .query_row("SELECT COUNT(*) FROM gen_metadata", [], |row| row.get(0))
            .unwrap();
        let count_ms = start.elapsed().as_secs_f64() * 1000.0;

        let start = std::time::Instant::now();
        let bytes: i64 = connection
            .query_row("SELECT SUM(length(hex(data))) FROM gen_metadata", [], |row| {
                row.get(0)
            })
            .unwrap();
        let hex_ms = start.elapsed().as_secs_f64() * 1000.0;

        let start = std::time::Instant::now();
        let mut hash = Sha3::new(256);
        for _ in 0..10_000 {
            hash.update(&blob);
        }
        let hash_ms = start.elapsed().as_secs_f64() * 1000.0;
        let _ = hash.finalize();

        println!(
            "TMP_BENCH digest_ms={digest_ms:.1} count_ms={count_ms:.1} hex_ms={hex_ms:.1} hash_ms={hash_ms:.1} bytes={} digest_len={}",
            bytes,
            digest.len()
        );
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn functions_are_available_on_read_only_connections() {
        let path = seeded("CREATE TABLE t(v); INSERT INTO t VALUES('value');");
        let connection = Connection::open_with_flags(&path, OpenFlags::SQLITE_OPEN_READ_ONLY)
            .expect("open read-only");
        register(&connection).expect("register");
        let digest: String = connection
            .query_row("SELECT hex(sha3('value'))", [], |row| row.get(0))
            .expect("query");
        assert_eq!(digest.len(), 64);
        let _ = std::fs::remove_file(path);
    }
}
