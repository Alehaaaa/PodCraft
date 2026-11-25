import Foundation

/// Values read from the original program. Addresses and notes live in MECHANICS.md.
enum Mechanics {
    /// "Back 15 Seconds" / "Forward 15 Seconds", SF symbols gobackward.15 / goforward.15 (PlayerTransport, 0x10046d2e8).
    static let skipBackSeconds: Double = 15
    static let skipForwardSeconds: Double = 15
    /// Playback Speed slider range, doubles 0.5 and 3.0 at 0x10095fe90 used by PlayerSpeed (0x10045e08c).
    static let minSpeed: Double = 0.5
    static let maxSpeed: Double = 3.0
    /// Estimated: slider step and the speed-button presets (not found in the code).
    static let speedStep: Double = 0.05
    static let speedPresets: [Double] = [0.8, 1.0, 1.2, 1.5, 2.0]
    /// Estimated: going to "Previous Chapter" more than this far into a chapter restarts it instead.
    static let previousChapterGrace: Double = 3
    /// Keep-rule defaults: autoDeleteKeepCount = 10, autoDeleteRetentionDays = 30 (app storage defaults, 0x10022e8d8).
    static let defaultKeepNewest = 10
    static let defaultKeepDays = 30
    /// The person's choice: a show keeps only its newest episode on this Mac unless told otherwise.
    static let defaultAvailablePerShow = 1
    static let videoExtensions: Set<String> = ["mp4", "m4v", "mov"]
    /// autoSyncIntervalMinutes = 30: how often new episodes are checked for (0x10022e8d8).
    static let checkIntervalMinutes: Double = 30
    /// Estimated: the Gemini model name (the original calls generativelanguage.googleapis.com/v1beta/models/, 0x10081a05c,
    /// and lists the models with the key; the chosen default wasn't found).
    static let defaultGeminiModel = "gemini-2.5-flash"
    /// Estimated: port of the feed server on this Mac.
    static let defaultHostPort = 8743
    /// Estimated: sentences are joined into blocks of at least this many seconds before the AI reads them.
    static let transcriptBlockSeconds: Double = 8
    /// Estimated: blocks per on-device AI request (the on-device model has a small context window).
    // About six minutes of transcript per request: comfortably inside the on-device model's
    // context window while avoiding dozens of tiny, high-overhead generations for long shows.
    static let onDeviceBlocksPerRequest = 24
    /// Speed panel width (320.0 stored beside the speed range at 0x10095fe88; estimated use).
    static let speedPanelWidth: Double = 320
}
