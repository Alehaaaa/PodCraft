// `cargo build` in app/: builds the native SwiftUI app and packages it as app/PodCraft.app (build-app.sh: FFmpeg,
// icon, the latest iPhone IPA, signing) before the launcher is built. `cargo run` then opens it.
use std::{env, process::Command};

fn main() {
    for path in ["Package.swift", "Sources", "Info.plist", "Resources", "build-app.sh", "iOS/dist"] {
        println!("cargo:rerun-if-changed={path}");
    }
    println!("cargo:rerun-if-env-changed=PODCRAFT_SIGN_IDENTITY");

    let root = env::var("CARGO_MANIFEST_DIR").unwrap();
    let mut build = Command::new("/bin/sh");
    build.arg(format!("{root}/build-app.sh")).current_dir(&root);
    remove_cargo_environment(&mut build);
    let status = build.status().expect("could not run build-app.sh (Xcode and the Swift toolchain are needed)");
    assert!(status.success(), "building PodCraft.app failed with {status}");
}

fn remove_cargo_environment(command: &mut Command) {
    // Cargo's environment can confuse the Swift and Xcode toolchains.
    for (key, _) in env::vars() {
        if key.starts_with("CARGO") || key.starts_with("RUSTC") || key.starts_with("RUST") || key == "TARGET"
            || key == "HOST" || key == "OUT_DIR" || key == "CC" || key == "CXX" || key == "CFLAGS" || key == "LDFLAGS"
            || key == "OPT_LEVEL" || key == "PROFILE" || key == "DEBUG" || key == "NUM_JOBS" {
            command.env_remove(&key);
        }
    }
}
