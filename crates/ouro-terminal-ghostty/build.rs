use std::env;
use std::path::PathBuf;
use std::process::Command;

fn run(command: &mut Command, description: &str) {
    let status = command
        .status()
        .unwrap_or_else(|error| panic!("failed to launch {description}: {error}"));
    assert!(status.success(), "{description} failed with {status}");
}

fn main() {
    let manifest = PathBuf::from(env::var_os("CARGO_MANIFEST_DIR").unwrap());
    let gate0 = manifest.join("../../spikes/libghostty-gate0");
    let adapter = gate0.join("src/ouro_ghostty_adapter.c");
    let adapter_header = gate0.join("include/ouro_terminal_engine.h");
    let ghostty_prefix = PathBuf::from(
        env::var_os("GHOSTTY_VT_PREFIX")
            .expect("GHOSTTY_VT_PREFIX must point to the exact Gate-0 libghostty install prefix"),
    );
    let ghostty_header = ghostty_prefix.join("include/ghostty/vt.h");
    let ghostty_archive = ghostty_prefix.join("lib/libghostty-vt.a");
    assert!(
        ghostty_header.is_file(),
        "missing {}",
        ghostty_header.display()
    );
    assert!(
        ghostty_archive.is_file(),
        "missing {}",
        ghostty_archive.display()
    );

    let out = PathBuf::from(env::var_os("OUT_DIR").unwrap());
    let object = out.join("ouro_ghostty_adapter.o");
    let archive = out.join("libouro_ghostty_adapter.a");

    run(
        &mut {
            let mut command = Command::new("cc");
            command
                .arg("-std=c11")
                .arg("-Wall")
                .arg("-Wextra")
                .arg("-Werror")
                .arg("-O2");
            if cfg!(target_os = "macos") {
                let minimum =
                    env::var("MACOSX_DEPLOYMENT_TARGET").unwrap_or_else(|_| "13.0".to_string());
                command.arg(format!("-mmacosx-version-min={minimum}"));
            }
            command
                .arg(format!("-I{}", gate0.join("include").display()))
                .arg(format!("-I{}", ghostty_prefix.join("include").display()))
                .arg("-c")
                .arg(&adapter)
                .arg("-o")
                .arg(&object);
            command
        },
        "compile Gate-0 adapter",
    );
    if cfg!(target_os = "macos") {
        // Darwin's linker may resolve `-l static=ghostty-vt` to the sibling
        // dylib despite Cargo's static modifier. Merge the exact-pin archive
        // into our adapter archive so downstream binaries have no runtime
        // libghostty load command and the dependency propagates through rlibs.
        run(
            Command::new("libtool")
                .arg("-static")
                .arg("-o")
                .arg(&archive)
                .arg(&object)
                .arg(&ghostty_archive),
            "combine Gate-0 adapter and libghostty archives",
        );
    } else {
        run(
            Command::new("ar").arg("crus").arg(&archive).arg(&object),
            "archive Gate-0 adapter",
        );
    }

    println!("cargo:rerun-if-changed={}", adapter.display());
    println!("cargo:rerun-if-changed={}", adapter_header.display());
    println!("cargo:rerun-if-env-changed=GHOSTTY_VT_PREFIX");
    println!("cargo:rerun-if-env-changed=MACOSX_DEPLOYMENT_TARGET");
    println!("cargo:rustc-link-search=native={}", out.display());
    println!("cargo:rustc-link-lib=static=ouro_ghostty_adapter");
    // A raw rustc-link-arg only reaches final targets in this package and is
    // lost when this crate is linked into the broker. Export a static native
    // library dependency so every downstream final binary receives it.
    if !cfg!(target_os = "macos") {
        println!(
            "cargo:rustc-link-search=native={}",
            ghostty_prefix.join("lib").display()
        );
        println!("cargo:rustc-link-lib=static=ghostty-vt");
    }
}
