use std::env;
use std::ffi::OsString;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode};

fn main() -> ExitCode {
    match run() {
        Ok(code) => ExitCode::from(code),
        Err(message) => {
            eprintln!("ourocode.exe: {message}");
            ExitCode::from(1)
        }
    }
}

fn run() -> Result<u8, String> {
    let exe =
        env::current_exe().map_err(|error| format!("could not locate executable: {error}"))?;
    let exe_dir = exe
        .parent()
        .ok_or_else(|| format!("could not resolve executable directory: {}", exe.display()))?;
    let escript = resolve_escript(exe_dir)
        .ok_or_else(|| format!("could not find ourocode escript near {}", exe_dir.display()))?;
    let tty = resolve_tty(exe_dir);
    let escript_runner = resolve_escript_runner().ok_or_else(|| {
        "could not find escript.exe; set ESCRIPT or install Erlang/Elixir".to_owned()
    })?;

    let mut command = Command::new(escript_runner);
    command.arg(escript).args(env::args_os().skip(1));

    if env::var_os("OUROCODE_TTY").is_none() {
        if let Some(path) = tty {
            command.env("OUROCODE_TTY", path);
        }
    }

    let status = command
        .status()
        .map_err(|error| format!("failed to start escript.exe: {error}"))?;
    Ok(exit_code(status.code()))
}

fn exit_code(code: Option<i32>) -> u8 {
    match code {
        Some(value) if (0..=255).contains(&value) => value as u8,
        Some(_) => 1,
        None => 1,
    }
}

fn resolve_escript(exe_dir: &Path) -> Option<PathBuf> {
    candidate_escripts(exe_dir)
        .into_iter()
        .find(|candidate| candidate.is_file())
}

fn candidate_escripts(exe_dir: &Path) -> [PathBuf; 2] {
    [
        exe_dir.join("ourocode"),
        exe_dir.parent().map_or_else(
            || exe_dir.join("ourocode"),
            |parent| parent.join("ourocode"),
        ),
    ]
}

fn resolve_escript_runner() -> Option<OsString> {
    if let Some(path) = env::var_os("ESCRIPT") {
        return Some(path);
    }

    candidate_escript_runners()
        .into_iter()
        .find(|candidate| candidate.is_file())
        .map(PathBuf::into_os_string)
        .or_else(|| Some(OsString::from("escript.exe")))
}

fn candidate_escript_runners() -> Vec<PathBuf> {
    let mut candidates = path_escript_candidates();

    if let Some(user_profile) = env::var_os("USERPROFILE") {
        let otp_root = PathBuf::from(user_profile)
            .join(".elixir-install")
            .join("installs")
            .join("otp");
        candidates.extend(versioned_escript_candidates(&otp_root));
    }

    candidates.extend(program_files_escript_candidates("ProgramFiles"));
    candidates.extend(program_files_escript_candidates("ProgramFiles(x86)"));
    candidates
}

fn path_escript_candidates() -> Vec<PathBuf> {
    env::var_os("PATH")
        .map(|path| {
            env::split_paths(&path)
                .map(|entry| entry.join("escript.exe"))
                .collect()
        })
        .unwrap_or_default()
}

fn versioned_escript_candidates(root: &Path) -> Vec<PathBuf> {
    let mut versions = match fs::read_dir(root) {
        Ok(entries) => entries
            .filter_map(|entry| entry.ok().map(|entry| entry.path()))
            .collect::<Vec<_>>(),
        Err(_error) => Vec::new(),
    };

    versions.sort();
    versions.reverse();

    versions
        .into_iter()
        .flat_map(|version| version_escript_candidates(&version))
        .collect()
}

fn version_escript_candidates(version: &Path) -> Vec<PathBuf> {
    let mut candidates = vec![version.join("bin").join("escript.exe")];

    let mut erts_dirs = match fs::read_dir(version) {
        Ok(entries) => entries
            .filter_map(|entry| entry.ok().map(|entry| entry.path()))
            .filter(|path| {
                path.file_name()
                    .and_then(|name| name.to_str())
                    .is_some_and(|name| name.starts_with("erts-"))
            })
            .collect::<Vec<_>>(),
        Err(_error) => Vec::new(),
    };

    erts_dirs.sort();
    erts_dirs.reverse();
    candidates.extend(
        erts_dirs
            .into_iter()
            .map(|path| path.join("bin").join("escript.exe")),
    );
    candidates
}

fn program_files_escript_candidates(var_name: &str) -> Vec<PathBuf> {
    env::var_os(var_name)
        .map(|program_files| {
            vec![
                PathBuf::from(&program_files)
                    .join("Erlang OTP")
                    .join("bin")
                    .join("escript.exe"),
                PathBuf::from(program_files)
                    .join("Erlang OTP")
                    .join("erts-17.0.2")
                    .join("bin")
                    .join("escript.exe"),
            ]
        })
        .unwrap_or_default()
}

fn resolve_tty(exe_dir: &Path) -> Option<PathBuf> {
    candidate_ttys(exe_dir)
        .into_iter()
        .find(|candidate| candidate.is_file())
}

fn candidate_ttys(exe_dir: &Path) -> [PathBuf; 2] {
    [
        exe_dir.join("ourocode_tty.exe"),
        exe_dir.join("bin").join("ourocode_tty.exe"),
    ]
}

#[cfg(test)]
mod tests {
    use super::{candidate_escripts, candidate_ttys, exit_code, versioned_escript_candidates};
    use std::fs;
    use std::path::{Path, PathBuf};

    #[test]
    fn resolves_escript_candidates_for_source_and_installed_layouts() {
        let candidates = candidate_escripts(Path::new("C:/tools/ourocode/bin"));

        assert_eq!(candidates[0], Path::new("C:/tools/ourocode/bin/ourocode"));
        assert_eq!(candidates[1], Path::new("C:/tools/ourocode/ourocode"));
    }

    #[test]
    fn resolves_tty_candidates_for_source_and_installed_layouts() {
        let candidates = candidate_ttys(Path::new("C:/tools/ourocode"));

        assert_eq!(
            candidates[0],
            Path::new("C:/tools/ourocode/ourocode_tty.exe")
        );
        assert_eq!(
            candidates[1],
            Path::new("C:/tools/ourocode/bin/ourocode_tty.exe")
        );
    }

    #[test]
    fn normalizes_process_exit_codes() {
        assert_eq!(exit_code(Some(0)), 0);
        assert_eq!(exit_code(Some(255)), 255);
        assert_eq!(exit_code(Some(256)), 1);
        assert_eq!(exit_code(None), 1);
    }

    #[test]
    fn searches_newest_elixir_installed_otp_first() {
        let root = test_root("ourocode-launcher-otp");
        let old = root.join("28.0.1");
        let new = root.join("29.0.2");
        fs::create_dir_all(old.join("bin")).expect("create old bin");
        fs::create_dir_all(new.join("bin")).expect("create new bin");
        fs::create_dir_all(new.join("erts-17.0.2").join("bin")).expect("create erts bin");

        let candidates = versioned_escript_candidates(&root);

        assert_eq!(candidates[0], new.join("bin").join("escript.exe"));
        assert_eq!(
            candidates[1],
            new.join("erts-17.0.2").join("bin").join("escript.exe")
        );
        assert_eq!(candidates[2], old.join("bin").join("escript.exe"));

        fs::remove_dir_all(root).expect("remove test root");
    }

    fn test_root(name: &str) -> PathBuf {
        std::env::temp_dir().join(format!("{name}-{}", std::process::id()))
    }
}
