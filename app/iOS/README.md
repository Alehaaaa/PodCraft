# PodCraft for iOS

Open **PodCraftPhone.xcodeproj** in Xcode 26 or later, select the **PodCraftPhone** scheme and an iPhone
simulator, and build. A command-line simulator build is also available:

```bash
cd app/iOS
./build-simulator.sh
```

Set `SIMULATOR_DESTINATION` to build for a particular simulator, for example
`SIMULATOR_DESTINATION='platform=iOS Simulator,name=iPhone 17 Pro' ./build-simulator.sh`.

The app's own sources are in `PodCraftPhone/`. The sync format, `../Sources/PodCraft/Sync/SyncCore.swift`, is shared
with the Mac app by a direct Xcode file reference, so both read and write the same documents. No copies are made.

**Modes:** with your Mac (companion) the app plays the library PodCraft on the Mac serves; on its own (standalone)
it follows podcasts straight from their feeds. **Sync** keeps followed shows, progress and speed in step across
devices, and brings the Mac's transcripts, chapters and sponsor spans to episodes streamed from their feed.

## IPA

To create an unsigned device IPA in `dist/PodCraft.ipa`:

```bash
cd app/iOS
./build-ipa.sh
```

The unsigned IPA is what AltStore, SideStore and LiveContainer install; they sign it themselves. With valid Xcode
signing configured, set `EXPORT_OPTIONS_PLIST=/absolute/path/ExportOptions.plist` (and optionally
`DEVELOPMENT_TEAM`) to archive and export a signed IPA instead; `ExportOptions.plist` here is a starting point.
The script checks the IPA's ZIP integrity, executable and `Info.plist` before it replaces the previous one, and
writes `dist/PodCraft-release.json` (version, build, size). The next `cargo build` of the Mac app bundles both, so
the Mac serves the new build to iPhones.

**Versions:** the version is in `VERSION`. The build number is the date and time (UTC), so every build is newer
than the last; `PODCRAFT_BUILD` overrides it.

**CI:** `.github/workflows/ios-ipa.yml` runs on changes pushed to main: it builds the unsigned IPA and, when the
version in `VERSION` is not published yet, publishes `altstore/PodCraft-<version>-<build>.ipa` and updates
`altstore.json`. Bump `VERSION` for each release.

The deployment target is **iOS 26**. The bundle identifier is `app.podcraft.ios`. The app icon is the Icon
Composer file `../Resources/PodCraft.icon`, shared with macOS.
