# PodCraft source organization

The Swift package is rooted at `app/Sources/PodCraft` and grouped by ownership:

- `App`: process entry point, window composition, root navigation, and app-wide toolbar.
- `Core`: persistent models, shared mechanics, styling, and reusable views.
- `Services`: infrastructure shared by features, including networking, artwork, and system media integration.
- `Features/Discovery`: RSS parsing, directory discovery, country selection, and public show details.
- `Features/Hosting`: the local HTTP/RSS server and hosting controls.
- `Features/Library`: manage/listen library screens, show editing, and show import.
- `Features/Player`: playback state, player surfaces, video, transcript, and queue UI.
- `Features/Processing`: downloads, transcription, AI chapters, sponsor removal, and YouTube source matching.
- `Diagnostics`: opt-in regression fixtures, stress tools, crash logging, and source-alignment checks.

## Dependency direction

Feature code may depend on `Core` and `Services`. Shared infrastructure should not import feature-specific behavior. Cross-feature coordination belongs in `Library`, `Player`, or the app composition layer rather than in views.

## Persistence

User data is stored under `Application Support/PodCraft`. The library migrates data and absolute media paths from releases predating the PodCraft naming cleanup. Keychain credentials are copied forward to the `PodCraft` service when first read.

## Tests

Backend regression tests live in `app/Tests/PodCraftTests`. Run them from `app/` with:

```sh
swift test
```
