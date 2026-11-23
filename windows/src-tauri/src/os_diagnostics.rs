//! OS / distro / kernel for UI and support bundles (best-effort, no shell injection).

use serde::Serialize;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct OsDiagnostics {
    pub family: String,
    pub arch: String,
    pub distro: Option<String>,
    pub kernel: Option<String>,
}

fn unquote_os_release_value(raw: &str) -> String {
    let t = raw.trim();
    if (t.starts_with('"') && t.ends_with('"')) || (t.starts_with('\'') && t.ends_with('\'')) {
        t[1..t.len().saturating_sub(1)].to_string()
    } else {
        t.to_string()
    }
}

fn linux_distro_pretty() -> Option<String> {
    #[cfg(target_os = "linux")]
    {
        let content = std::fs::read_to_string("/etc/os-release").ok()?;
        let mut pretty: Option<String> = None;
        let mut name: Option<String> = None;
        let mut version_id: Option<String> = None;
        for line in content.lines() {
            if let Some(v) = line.strip_prefix("PRETTY_NAME=") {
                let u = unquote_os_release_value(v);
                if !u.is_empty() {
                    pretty = Some(u);
                    break;
                }
            }
            if let Some(v) = line.strip_prefix("NAME=") {
                let u = unquote_os_release_value(v);
                if !u.is_empty() && u != "Linux" {
                    name = Some(u);
                }
            }
            if let Some(v) = line.strip_prefix("VERSION_ID=") {
                let u = unquote_os_release_value(v);
                if !u.is_empty() {
                    version_id = Some(u);
                }
            }
        }
        if let Some(p) = pretty {
            return Some(p);
        }
        match (name, version_id) {
            (Some(n), Some(v)) => Some(format!("{n} {v}")),
            (Some(n), None) => Some(n),
            _ => None,
        }
    }
    #[cfg(not(target_os = "linux"))]
    {
        None
    }
}

fn kernel_release() -> Option<String> {
    #[cfg(unix)]
    {
        let out = std::process::Command::new("uname").arg("-r").output().ok()?;
        let s = String::from_utf8_lossy(&out.stdout).trim().to_string();
        if s.is_empty() {
            None
        } else {
            Some(s)
        }
    }
    #[cfg(not(unix))]
    None
}

pub fn collect() -> OsDiagnostics {
    OsDiagnostics {
        family: std::env::consts::OS.to_string(),
        arch: std::env::consts::ARCH.to_string(),
        distro: linux_distro_pretty(),
        kernel: kernel_release(),
    }
}

/// One line for startup logs (distro + kernel on Linux).
pub fn log_summary_one_line() -> String {
    let d = collect();
    if d.family == "linux" {
        let mut parts: Vec<String> = Vec::new();
        if let Some(dist) = &d.distro {
            parts.push(dist.clone());
        }
        if let Some(k) = &d.kernel {
            parts.push(format!("kernel {k}"));
        }
        parts.push(d.arch.clone());
        return parts.join(" · ");
    }
    let mut parts = vec![d.family.clone()];
    if let Some(k) = &d.kernel {
        parts.push(format!("kernel {k}"));
    }
    parts.push(d.arch);
    parts.join(" · ")
}

#[derive(Debug, Clone)]
pub struct AptabaseSystemProps {
    pub is_debug: bool,
    pub os_name: String,
    pub os_version: String,
    pub locale: String,
    pub engine_name: &'static str,
    pub engine_version: String,
}

#[cfg(any(target_os = "linux", test))]
fn map_os_release_id_to_aptabase_name(id: &str, name: Option<&str>) -> String {
    match id.trim().to_ascii_lowercase().as_str() {
        "almalinux" => "AlmaLinux".to_string(),
        "alpaquita" => "Alpaquita Linux".to_string(),
        "alpine" => "Alpine Linux".to_string(),
        "altlinux" | "alt" => "ALT Linux".to_string(),
        "amzn" | "amazon" => "Amazon Linux AMI".to_string(),
        "aosc" => "AOSC OS".to_string(),
        "arch" | "archarm" => "Arch Linux".to_string(),
        "artix" => "Artix Linux".to_string(),
        "azurelinux" => "Azure Linux".to_string(),
        "bazzite" => "Bazzite".to_string(),
        "bluefin" => "Bluefin".to_string(),
        "cachyos" => "CachyOS Linux".to_string(),
        "centos" => "CentOS".to_string(),
        "debian" => {
            if std::path::Path::new("/etc/rpi-issue").exists() {
                "Raspberry Pi OS".to_string()
            } else if name == Some("Parrot Security") {
                "Parrot OS".to_string()
            } else {
                "Debian".to_string()
            }
        }
        "elementary" => "Elementary OS".to_string(),
        "endeavouros" => "EndeavourOS".to_string(),
        "fedora" => "Fedora".to_string(),
        "garuda" => "Garuda Linux".to_string(),
        "gentoo" => "Gentoo Linux".to_string(),
        "instantos" => "instantOS".to_string(),
        "kali" => "Kali Linux".to_string(),
        "neon" => "KDE neon".to_string(),
        "linuxmint" | "mint" => "Linux Mint".to_string(),
        "mabox" | "maboxlinux" => "Mabox".to_string(),
        "manjaro" | "manjaro-arm" | "manjarolinux" => "Manjaro".to_string(),
        "mariner" => "Mariner".to_string(),
        "nixos" => "NixOS".to_string(),
        "nobara" | "nobaralinux" => "Nobara Linux".to_string(),
        "opencloudos" => "OpenCloudOS".to_string(),
        "openeuler" => "EulerOS".to_string(),
        "ol" | "oracleserver" => "Oracle Linux".to_string(),
        "opensuse" | "opensuse-leap" | "opensuse-microos" | "opensuse-tumbleweed" => {
            "openSUSE".to_string()
        }
        "parrot" => "Parrot OS".to_string(),
        "pika" | "pikaos" => "PikaOS".to_string(),
        "pop" => "Pop!_OS".to_string(),
        "raspbian" => "Raspberry Pi OS".to_string(),
        "rhel" | "redhatenterprise" | "redhatenterpriseserver" => {
            "Red Hat Enterprise Linux".to_string()
        }
        "rocky" => "Rocky Linux".to_string(),
        "solus" => "Solus".to_string(),
        "sled" | "sles" | "sles_sap" | "suse" => "SUSE Linux Enterprise Server".to_string(),
        "ubuntu" => "Ubuntu".to_string(),
        "ultramarine" | "ultramarinelinux" => "Ultramarine Linux".to_string(),
        "uos" => "UOS".to_string(),
        "void" | "voidlinux" => "Void Linux".to_string(),
        "zorin" => "Zorin OS".to_string(),
        _ => name
            .map(str::trim)
            .filter(|n| !n.is_empty())
            .unwrap_or("Linux")
            .to_string(),
    }
}

#[cfg(any(target_os = "linux", test))]
fn normalize_os_info_version(raw: Option<&str>) -> String {
    let Some(s) = raw.map(str::trim).filter(|s| !s.is_empty()) else {
        return "Unknown".to_string();
    };
    if s.eq_ignore_ascii_case("rolling") {
        return "Rolling Release".to_string();
    }
    let mut iter = s.split_terminator('.').fuse();
    if let Some(major) = iter.next().and_then(|v| v.parse::<u64>().ok()) {
        if let Some(minor) = iter.next().unwrap_or("0").parse::<u64>().ok() {
            if let Some(patch) = iter.next().unwrap_or("0").parse::<u64>().ok() {
                if iter.next().is_none() {
                    return format!("{major}.{minor}.{patch}");
                }
            }
        }
    }
    s.to_string()
}

#[cfg(any(target_os = "linux", test))]
fn parse_os_release_for_aptabase(content: &str) -> (String, String) {
    let mut id: Option<String> = None;
    let mut name: Option<String> = None;
    let mut version_id: Option<String> = None;
    let mut build_id: Option<String> = None;

    for line in content.lines() {
        let line = line.trim();
        if let Some(v) = line.strip_prefix("ID=") {
            let u = unquote_os_release_value(v);
            if !u.is_empty() {
                id = Some(u);
            }
        } else if let Some(v) = line.strip_prefix("NAME=") {
            let u = unquote_os_release_value(v);
            if !u.is_empty() {
                name = Some(u);
            }
        } else if let Some(v) = line.strip_prefix("VERSION_ID=") {
            let u = unquote_os_release_value(v);
            if !u.is_empty() {
                version_id = Some(u);
            }
        } else if let Some(v) = line.strip_prefix("BUILD_ID=") {
            let u = unquote_os_release_value(v);
            if !u.is_empty() {
                build_id = Some(u);
            }
        }
    }

    let os_name = map_os_release_id_to_aptabase_name(
        id.as_deref().unwrap_or(""),
        name.as_deref(),
    );
    let os_version = normalize_os_info_version(version_id.as_deref().or(build_id.as_deref()));
    (os_name, os_version)
}

fn detect_system_locale() -> String {
    for key in ["LC_ALL", "LC_MESSAGES", "LANG"] {
        if let Ok(val) = std::env::var(key) {
            let trimmed = val.trim();
            if !trimmed.is_empty() && trimmed != "C" && !trimmed.starts_with("C.") && trimmed != "POSIX" {
                let base = trimmed
                    .split('.')
                    .next()
                    .unwrap_or(trimmed)
                    .split('@')
                    .next()
                    .unwrap_or(trimmed)
                    .replace('_', "-");
                if !base.is_empty() {
                    return base;
                }
            }
        }
    }
    "en-US".to_string()
}

pub fn collect_aptabase_system_props() -> AptabaseSystemProps {
    #[cfg(target_os = "linux")]
    let (os_name, os_version, engine_name) = {
        let is_flatpak = std::env::var("FLATPAK_ID").is_ok()
            || std::env::var("container")
                .map(|x| x.trim().eq_ignore_ascii_case("flatpak"))
                .unwrap_or(false);
        let (parsed_name, parsed_ver) = std::fs::read_to_string("/etc/os-release")
            .ok()
            .map(|c| parse_os_release_for_aptabase(&c))
            .unwrap_or_else(|| ("Linux".to_string(), "Unknown".to_string()));
        let final_name = if is_flatpak {
            "Flatpak".to_string()
        } else {
            parsed_name
        };
        (final_name, parsed_ver, "WebKitGTK")
    };

    #[cfg(target_os = "windows")]
    let (os_name, os_version, engine_name) = {
        let ver = windows_os_version().unwrap_or_else(|| "10.0.0".to_string());
        ("Windows".to_string(), ver, "WebView2")
    };

    #[cfg(target_os = "macos")]
    let (os_name, os_version, engine_name) = {
        let ver = std::process::Command::new("sw_vers")
            .arg("-productVersion")
            .output()
            .ok()
            .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| "Unknown".to_string());
        ("macOS".to_string(), ver, "WebKit")
    };

    AptabaseSystemProps {
        is_debug: cfg!(debug_assertions),
        os_name,
        os_version,
        locale: detect_system_locale(),
        engine_name,
        engine_version: tauri::webview_version().unwrap_or_default(),
    }
}

#[cfg(target_os = "windows")]
fn windows_os_version() -> Option<String> {
    #[repr(C)]
    struct OsVersionInfoExW {
        dw_os_version_info_size: u32,
        dw_major_version: u32,
        dw_minor_version: u32,
        dw_build_number: u32,
        dw_platform_id: u32,
        sz_csd_version: [u16; 128],
        w_service_pack_major: u16,
        w_service_pack_minor: u16,
        w_suite_mask: u16,
        w_product_type: u8,
        w_reserved: u8,
    }
    #[link(name = "ntdll")]
    unsafe extern "system" {
        fn RtlGetVersion(lp_version_information: *mut OsVersionInfoExW) -> i32;
    }
    unsafe {
        let mut info: OsVersionInfoExW = std::mem::zeroed();
        info.dw_os_version_info_size = std::mem::size_of::<OsVersionInfoExW>() as u32;
        if RtlGetVersion(&mut info) == 0 {
            Some(format!(
                "{}.{}.{}",
                info.dw_major_version, info.dw_minor_version, info.dw_build_number
            ))
        } else {
            None
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{
        collect_aptabase_system_props, parse_os_release_for_aptabase, unquote_os_release_value,
    };

    #[test]
    fn unquote_strips_double_quotes() {
        assert_eq!(unquote_os_release_value("\"Ubuntu 24.04 LTS\""), "Ubuntu 24.04 LTS");
    }

    #[test]
    fn parses_pop_os_release_for_aptabase() {
        let sample = "NAME=\"Pop!_OS\"\nVERSION=\"24.04 LTS\"\nID=pop\nVERSION_ID=\"24.04\"\n";
        let (name, ver) = parse_os_release_for_aptabase(sample);
        assert_eq!(name, "Pop!_OS");
        assert_eq!(ver, "24.4.0");
    }

    #[test]
    fn parses_arch_and_cachyos_for_aptabase() {
        let arch = "NAME=\"Arch Linux\"\nID=arch\nBUILD_ID=rolling\n";
        assert_eq!(
            parse_os_release_for_aptabase(arch),
            ("Arch Linux".to_string(), "Rolling Release".to_string())
        );

        let cachy = "NAME=\"CachyOS Linux\"\nID=cachyos\nBUILD_ID=rolling\n";
        assert_eq!(
            parse_os_release_for_aptabase(cachy),
            ("CachyOS Linux".to_string(), "Rolling Release".to_string())
        );
    }

    #[test]
    fn collects_non_empty_aptabase_system_props() {
        let props = collect_aptabase_system_props();
        assert!(!props.os_name.is_empty());
        assert!(!props.os_version.is_empty());
        assert!(!props.locale.is_empty());
        assert!(!props.engine_name.is_empty());
    }
}
