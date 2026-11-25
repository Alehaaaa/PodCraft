// Opens the packaged Mac app (app/PodCraft.app, built by build.rs) through macOS, passing every argument
// through (for example `--screenshot shots/now.png`). With --screenshot it opens in the background without
// taking focus and waits until the app has saved its picture and quit.
use std::process::{exit, Command};

fn main() {
    let bundle = concat!(env!("CARGO_MANIFEST_DIR"), "/PodCraft.app");
    let args: Vec<String> = std::env::args().skip(1).collect();
    let screenshot = args.iter().any(|a| a == "--screenshot");
    // Relative paths (like shots/now.png) are made absolute: the app doesn't share this working folder.
    let cwd = std::env::current_dir().unwrap_or_default();
    let mut pass: Vec<String> = Vec::new();
    let mut i = 0;
    while i < args.len() {
        pass.push(args[i].clone());
        if args[i] == "--screenshot" && i + 1 < args.len() {
            let p = std::path::Path::new(&args[i + 1]);
            let abs = if p.is_absolute() { p.to_path_buf() } else { cwd.join(p) };
            pass.push(abs.to_string_lossy().into_owned());
            i += 1;
        }
        i += 1;
    }
    let mut open = Command::new("/usr/bin/open");
    if screenshot {
        // -g: stay in the background, -W: wait for it to quit, -n: a fresh copy even if one is already open.
        open.args(["-g", "-W", "-n"]);
    }
    open.arg(bundle);
    if !pass.is_empty() {
        open.arg("--args").args(&pass);
    }
    match open.status() {
        Ok(s) => exit(s.code().unwrap_or(1)),
        Err(e) => {
            eprintln!("could not open {bundle}: {e}");
            exit(1);
        }
    }
}
