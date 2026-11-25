//! Locate Antigravity's local language server (`Services/LanguageServerDiscovery`).
//!
//! A native port of the Tauri host's `ls.discover`: scan the process table, match the executable +
//! marker flags, read the CSRF token and listening ports. Blocking subprocess work; callers run it
//! on the engine's refresh thread.

use std::process::{Command, Stdio};

#[derive(Clone, Debug)]
pub struct Options {
    pub process_name: &'static str,
    pub markers: &'static [&'static str],
    pub csrf_flag: &'static str,
    pub port_flag: Option<&'static str>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Discovered {
    pub pid: i32,
    pub csrf: String,
    pub ports: Vec<u16>,
    pub extension_port: Option<u16>,
}

pub fn process_snapshot() -> Option<String> {
    let output = Command::new("/bin/ps")
        .args(["-ax", "-o", "pid=,command="])
        .stdin(Stdio::null())
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    String::from_utf8(output.stdout).ok()
}

pub fn discover(options: &Options, snapshot: &str) -> Option<Discovered> {
    let candidates = ranked_candidates(snapshot, options);
    if candidates.is_empty() {
        return None;
    }
    let lsof = ["/usr/sbin/lsof", "/usr/bin/lsof"]
        .into_iter()
        .find(|path| std::path::Path::new(path).exists())?;
    for (pid, command) in candidates {
        let csrf = if options.csrf_flag.is_empty() {
            String::new()
        } else {
            match extract_flag(&command, options.csrf_flag) {
                Some(value) => value,
                None => continue,
            }
        };
        let extension_port = options
            .port_flag
            .and_then(|flag| extract_flag(&command, flag))
            .and_then(|value| value.parse::<u16>().ok());
        let ports = Command::new(lsof)
            .args(["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", &pid.to_string()])
            .stdin(Stdio::null())
            .output()
            .ok()
            .filter(|output| output.status.success())
            .map(|output| parse_listening_ports(&String::from_utf8_lossy(&output.stdout)))
            .unwrap_or_default();
        if ports.is_empty() && extension_port.is_none() {
            continue;
        }
        return Some(Discovered {
            pid,
            csrf,
            ports,
            extension_port,
        });
    }
    None
}

pub fn ranked_candidates(snapshot: &str, options: &Options) -> Vec<(i32, String)> {
    let process = options.process_name.to_lowercase();
    let markers: Vec<String> = options
        .markers
        .iter()
        .map(|marker| marker.trim().to_lowercase())
        .filter(|marker| !marker.is_empty())
        .collect();
    let mut ranked = Vec::new();
    for line in snapshot.lines() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let Some((pid, command)) = line.split_once(char::is_whitespace) else {
            continue;
        };
        let Ok(pid) = pid.parse::<i32>() else {
            continue;
        };
        let command = command.trim();
        if !command_matches_process(command, &process) {
            continue;
        }
        let Some(rank) = marker_rank(command, &markers) else {
            continue;
        };
        ranked.push((rank, pid, command.to_string()));
    }
    ranked.sort_by_key(|(rank, _, _)| *rank);
    ranked
        .into_iter()
        .map(|(_, pid, command)| (pid, command))
        .collect()
}

pub fn extract_flag(command: &str, flag: &str) -> Option<String> {
    let parts: Vec<&str> = command.split_whitespace().collect();
    let prefix = format!("{flag}=");
    for (index, part) in parts.iter().enumerate() {
        if *part == flag {
            return parts.get(index + 1).map(|value| (*value).to_string());
        }
        if let Some(value) = part.strip_prefix(&prefix) {
            return Some(value.to_string());
        }
    }
    None
}

fn marker_rank(command: &str, markers: &[String]) -> Option<usize> {
    if markers.is_empty() {
        return Some(0);
    }
    let ide = extract_flag(command, "--ide_name").map(|value| value.to_lowercase());
    let override_ide =
        extract_flag(command, "--override_ide_name").map(|value| value.to_lowercase());
    let app_data = extract_flag(command, "--app_data_dir").map(|value| value.to_lowercase());
    if ide.is_some() || override_ide.is_some() || app_data.is_some() {
        let matches = markers.iter().any(|marker| {
            ide.as_deref() == Some(marker)
                || override_ide.as_deref() == Some(marker)
                || app_data.as_deref() == Some(marker)
        });
        return matches.then_some(0);
    }
    let lower = command.to_lowercase();
    markers
        .iter()
        .any(|marker| lower.contains(&format!("/{marker}/")))
        .then_some(1)
}

fn argv0(command: &str) -> &str {
    let trimmed = command.trim_start();
    if let Some(quote) = trimmed.chars().next().filter(|c| *c == '"' || *c == '\'') {
        let rest = &trimmed[quote.len_utf8()..];
        if let Some(end) = rest.find(quote) {
            return &rest[..end];
        }
    }
    trimmed.split_whitespace().next().unwrap_or("")
}

fn command_matches_process(command: &str, process: &str) -> bool {
    if process.is_empty() {
        return false;
    }
    let exe = argv0(command)
        .rsplit('/')
        .next()
        .unwrap_or("")
        .to_lowercase();
    if exe == process {
        return true;
    }
    let lower = command.to_lowercase();
    if process.len() >= 8 {
        return exe.starts_with(&format!("{process}_")) || lower.contains(process);
    }
    lower.ends_with(&format!("/{process}"))
        || lower.contains(&format!("/{process} "))
        || lower.contains(&format!("/{process}\t"))
}

pub fn parse_listening_ports(output: &str) -> Vec<u16> {
    let mut ports = std::collections::BTreeSet::new();
    for line in output.lines() {
        if !line.contains("LISTEN") {
            continue;
        }
        for token in line.split_whitespace().rev() {
            if let Some((_, port)) = token.rsplit_once(':') {
                if let Ok(port) = port.parse::<u16>() {
                    if port > 0 {
                        ports.insert(port);
                        break;
                    }
                }
            }
        }
    }
    ports.into_iter().collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    const OPTIONS: Options = Options {
        process_name: "language_server",
        markers: &["antigravity"],
        csrf_flag: "--csrf_token",
        port_flag: Some("--extension_server_port"),
    };

    #[test]
    fn ranks_exact_markers_before_path_markers_and_matches_name() {
        let ps = "  10 /Applications/Antigravity.app/language_server --ide_name antigravity --csrf_token a --extension_server_port 2\n\
                  11 /tmp/antigravity/language_server --csrf_token b\n\
                  12 /usr/bin/other --ide_name antigravity --csrf_token c\n";
        let candidates = ranked_candidates(ps, &OPTIONS);
        assert_eq!(candidates.len(), 2);
        assert_eq!(candidates[0].0, 10);
        assert_eq!(candidates[1].0, 11);
        assert_eq!(
            extract_flag(&candidates[0].1, "--csrf_token").as_deref(),
            Some("a")
        );
        assert_eq!(
            parse_listening_ports("x TCP 127.0.0.1:8080 (LISTEN)\ny TCP [::1]:9090 (LISTEN)"),
            vec![8080, 9090]
        );
    }
}
