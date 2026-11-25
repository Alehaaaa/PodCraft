# PodCraft

A free podcast app for macOS and iOS.

- **Mac** — downloads shows, cuts sponsor segments, adds chapters and transcripts, and serves the cleaned
  library to your iPhone.
- **iPhone** — works two ways:
  - **With your Mac** (companion): plays the Mac's cleaned library over your network or Tailscale.
  - **On its own** (standalone): search Apple's podcast directory or paste any RSS feed and follow shows directly,
    no Mac needed.
- **Sync** — a free, account-less sync code keeps followed shows, listening progress and playback settings the
  same on any number of devices. Data is end-to-end encrypted with a key derived from the code and stored in a
  public text store (textdb.dev), so it works anywhere without Tailscale or a server of your own.

## Install on iPhone

Add this source to AltStore / SideStore:

```
https://raw.githubusercontent.com/Alehaaaa/PodCraft/main/altstore.json
```

Builds are unsigned; AltStore, SideStore and LiveContainer sign them as they install.

## Project layout

- `app/Sources/PodCraft/` — the macOS app (Swift package, `app/Package.swift`).
- `app/iOS/` — the iPhone app (`PodCraftPhone.xcodeproj`), `build-ios.sh`, and `VERSION`.
- `app/Tests/` — regression tests for the Mac app.
- `altstore.json`, `altstore/` — the AltStore source and published `.ipa` files.

## Releases

Pushing to `main` runs the **iOS IPA** workflow: it builds an unsigned `.ipa` and, when the version in
`app/iOS/VERSION` hasn't been published yet, adds it to `altstore/` and `altstore.json`. Bump `app/iOS/VERSION`
to release. The **macOS build check** workflow compiles the Mac app and runs its tests.

The Mac app is built locally with `app/build-app.sh` (it bundles a static LGPL FFmpeg from `app/Vendor/`).
