// Builds the native Swift app and packages it as app/PodCraft.app (build-app.sh) before the launcher is built,
// so every build — including Craft Anything's checks — produces the real Mac app bundle.
use std::process::Command;

fn main() {
    println!("cargo:rerun-if-changed=Package.swift");
    println!("cargo:rerun-if-changed=Sources");
    println!("cargo:rerun-if-changed=Info.plist");
    println!("cargo:rerun-if-changed=Resources");
    println!("cargo:rerun-if-changed=build-app.sh");
    println!("cargo:rerun-if-changed=iOS/dist");
    let dir = std::env::var("CARGO_MANIFEST_DIR").unwrap();
    let status = Command::new("sh")
        .arg(format!("{dir}/build-app.sh"))
        .current_dir(&dir)
        .env_remove("RUSTFLAGS")
        .env_remove("CARGO_ENCODED_RUSTFLAGS")
        .status()
        .expect("could not run build-app.sh (Xcode or the Swift toolchain is needed)");
    if !status.success() {
        panic!("building PodCraft.app failed");
    }
}
