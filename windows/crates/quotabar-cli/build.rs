use std::env;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

fn should_skip_file(name: &str) -> bool {
    name.ends_with(".test.js") || name == "test-helpers.js" || name.ends_with(".md")
}

fn copy_dir_filtered(src: &Path, dst: &Path, is_root: bool) -> io::Result<()> {
    fs::create_dir_all(dst)?;
    for entry in fs::read_dir(src)? {
        let entry = entry?;
        let name = entry.file_name();
        let name_str = name.to_string_lossy();
        let path = entry.path();
        let dest_path = dst.join(&name);
        if path.is_dir() {
            if is_root && name_str == "mock" {
                continue;
            }
            copy_dir_filtered(&path, &dest_path, false)?;
        } else if path.is_file() {
            if should_skip_file(&name_str) {
                continue;
            }
            fs::copy(&path, &dest_path)?;
        }
    }
    Ok(())
}

fn main() {
    let manifest_dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR"));
    let plugins_src = manifest_dir.join("../../plugins");
    println!("cargo:rerun-if-changed={}", plugins_src.display());

    let out_dir = PathBuf::from(env::var("OUT_DIR").expect("OUT_DIR"));
    let bundled_dst = out_dir.join("bundled_plugins");
    if bundled_dst.exists() {
        let _ = fs::remove_dir_all(&bundled_dst);
    }
    copy_dir_filtered(&plugins_src, &bundled_dst, true)
        .expect("failed to stage runtime plugins into OUT_DIR/bundled_plugins");
}
