import AVFoundation
import Foundation
import Observation
import Speech
import SwiftUI

// MARK: - Reading published transcripts

/// Transcripts shows publish with <podcast:transcript>: WebVTT, SRT and Podcasting 2.0 JSON.
enum TranscriptParser {
    struct Cue {
        var start: Double
        var end: Double
        var text: String
        var speaker: String?
    }

    /// How good a published type is to read (lower is better); nil for types without timings (HTML, plain text).
    static func rank(_ type: String) -> Int? {
        let t = type.lowercased()
        if t.contains("vtt") { return 0 }
        if t.contains("json") { return 1 }
        if t.contains("srt") || t.contains("subrip") { return 2 }
        return nil
    }

    static func parse(_ data: Data, type: String) -> [TranscriptLine] {
        let text = String(decoding: data, as: UTF8.self)
        let cues: [Cue]
        if type.lowercased().contains("json") || text.drop(while: \.isWhitespace).first == "{" {
            cues = json(data)
        } else {
            cues = timed(text)
        }
        return lines(from: cues)
    }

    /// WebVTT and SRT: blocks with a "start --> end" line, then the words.
    static func timed(_ text: String) -> [Cue] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var cues: [Cue] = []
        for block in normalized.components(separatedBy: "\n\n") {
            let rows = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let timing = rows.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = rows[timing].components(separatedBy: "-->")
            guard parts.count == 2, let start = seconds(parts[0]),
                  let end = seconds(parts[1].trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? "")
            else { continue }
            var speaker: String?
            var words: [String] = []
            for row in rows[(timing + 1)...] {
                var line = row
                // <v Speaker Name>text</v>
                if let match = line.range(of: "<v(\\.[^ >]*)? ([^>]+)>", options: .regularExpression) {
                    let tag = String(line[match])
                    if let space = tag.firstIndex(of: " ") {
                        speaker = String(tag[tag.index(after: space)...].dropLast()).trimmingCharacters(in: .whitespaces)
                    }
                }
                line = line.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                // "SPEAKER: words" (common in SRT)
                if let colon = line.range(of: "^[A-Z][A-Za-z .'-]{1,30}: ", options: .regularExpression) {
                    speaker = String(line[colon].dropLast(2))
                    line.removeSubrange(colon)
                }
                words.append(line)
            }
            let joined = decodeEntities(words.joined(separator: " ")).trimmingCharacters(in: .whitespaces)
            guard !joined.isEmpty else { continue }
            cues.append(Cue(start: start, end: max(end, start), text: joined, speaker: speaker))
        }
        return cues
    }

    /// Podcasting 2.0 JSON: {"segments": [{"startTime", "endTime", "body", "speaker"}]}.
    static func json(_ data: Data) -> [Cue] {
        struct File: Decodable {
            struct Segment: Decodable {
                var startTime: Double?
                var endTime: Double?
                var body: String?
                var speaker: String?
            }
            var segments: [Segment]
        }
        guard let file = try? JSONDecoder().decode(File.self, from: data) else { return [] }
        return file.segments.compactMap { s in
            guard let start = s.startTime, let body = s.body?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty
            else { return nil }
            return Cue(start: start, end: s.endTime ?? start, text: body, speaker: s.speaker)
        }
    }

    /// "01:02:03.450", "02:03.450", "01:02:03,450".
    static func seconds(_ raw: String) -> Double? {
        let parts = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard (2...3).contains(parts.count) else { return nil }
        var total = 0.0
        for p in parts {
            guard let v = Double(p) else { return nil }
            total = total * 60 + v
        }
        return total
    }

    private static func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    /// Joins short cues (captions are often a few words each) into readable lines: a new line at each new speaker,
    /// after a pause, or at the end of a sentence once the line is long enough.
    static func lines(from cues: [Cue]) -> [TranscriptLine] {
        var out: [TranscriptLine] = []
        var current: TranscriptLine?
        var previousText = ""
        func flush() {
            guard var line = current else { return }
            if let last = out.last, line.start <= last.start { line.start = last.start + 0.001 }
            out.append(line)
            current = nil
        }
        for cue in cues.sorted(by: { $0.start < $1.start }) {
            // Rolling captions repeat the cue before.
            if cue.text == previousText { continue }
            previousText = cue.text
            if var line = current {
                let newSpeaker = cue.speaker != nil && cue.speaker != line.speaker
                let pause = cue.start - line.end > 1.5
                let sentenceDone = line.text.count > 80 && line.text.last.map { ".?!…".contains($0) } == true
                if newSpeaker || pause || sentenceDone || line.text.count > 260 {
                    flush()
                } else {
                    line.text += " " + cue.text
                    line.end = max(line.end, cue.end)
                    current = line
                    continue
                }
            }
            current = TranscriptLine(start: cue.start, end: cue.end, text: cue.text, speaker: cue.speaker)
        }
        flush()
        return out
    }
}

// MARK: - Transcripts on the phone

/// Finds an episode's transcript when the Mac has none: the one the show publishes, or one made on this iPhone
/// with Apple's on-device speech model. Both are kept in the cache so they load at once next time.
@MainActor
@Observable
final class TranscriptService {
    enum Phase: Equatable {
        case preparing
        case downloadingAudio(Double)
        case downloadingModel
        case transcribing(Double)
        case failed(String)
    }

    /// Transcriptions running (or failed) on this phone, by episode id.
    private(set) var phases: [String: Phase] = [:]
    /// Lines found so far while transcribing, and finished transcripts, by episode id.
    private(set) var lines: [String: [TranscriptLine]] = [:]
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]

    /// Apple's on-device speech model runs on this iPhone.
    static var canTranscribe: Bool { SpeechTranscriber.isAvailable }

    private static let dir: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Transcripts")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static func file(_ id: String, _ suffix: String) -> URL {
        dir.appendingPathComponent(Hash.short(id, length: 32) + suffix)
    }

    func isRunning(_ id: String) -> Bool { tasks[id] != nil }

    /// A transcript found before: the show's, or one made on this iPhone.
    func cached(_ id: String) -> [TranscriptLine]? {
        if tasks[id] == nil, let have = lines[id], !have.isEmpty { return have }
        for suffix in [".json", ".device.json"] {
            if let data = try? Data(contentsOf: Self.file(id, suffix)),
               let saved = try? JSONDecoder().decode([TranscriptLine].self, from: data), !saved.isEmpty {
                lines[id] = saved
                return saved
            }
        }
        return nil
    }

    func hasOnDevice(_ id: String) -> Bool { FileManager.default.fileExists(atPath: Self.file(id, ".device.json").path) }

    /// The transcript the show publishes for this episode, if it has one PodCraft can read.
    func published(for e: RemoteEpisode) async -> [TranscriptLine]? {
        guard let url = e.transcriptURL else { return nil }
        if let have = cached(e.id) { return have }
        var request = URLRequest(url: url)
        request.setValue("PodCraft/1.0 (iPhone)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true else { return nil }
        let type = e.transcriptType ?? ""
        let parsed = await Task.detached(priority: .utility) { TranscriptParser.parse(data, type: type) }.value
        guard !parsed.isEmpty else { return nil }
        lines[e.id] = parsed
        if let encoded = try? JSONEncoder().encode(parsed) { try? encoded.write(to: Self.file(e.id, ".json"), options: .atomic) }
        return parsed
    }

    /// Transcribes the episode on this iPhone. Lines appear as they are found; the result is saved.
    func transcribe(_ e: RemoteEpisode, language: String?) {
        guard tasks[e.id] == nil else { return }
        let id = e.id
        phases[id] = .preparing
        lines[id] = []
        // A downloaded episode is transcribed from the phone, with nothing to fetch.
        let media = Downloads.shared.localURL(for: e) ?? e.media
        let duration = e.duration
        let service = self
        tasks[id] = Task {
            do {
                let result = try await OnDeviceTranscriber.run(
                    media: media, language: language, duration: duration,
                    phase: { phase in Task { @MainActor in service.update(id, phase: phase) } },
                    partial: { partial in Task { @MainActor in service.update(id, partial: partial) } })
                guard !Task.isCancelled else { return }
                self.tasks[id] = nil
                if result.isEmpty {
                    self.phases[id] = .failed("No speech was found in this episode.")
                    self.lines[id] = nil
                    return
                }
                self.phases[id] = nil
                self.lines[id] = result
                if let encoded = try? JSONEncoder().encode(result) {
                    try? encoded.write(to: Self.file(id, ".device.json"), options: .atomic)
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.tasks[id] = nil
                self.lines[id] = nil
                self.phases[id] = error is CancellationError ? nil : .failed(error.localizedDescription)
            }
        }
    }

    func cancel(_ id: String) {
        tasks[id]?.cancel()
        tasks[id] = nil
        phases[id] = nil
        lines[id] = nil
    }

    /// Forgets a transcript made on this iPhone, to make it again.
    func forgetOnDevice(_ id: String) {
        try? FileManager.default.removeItem(at: Self.file(id, ".device.json"))
        lines[id] = nil
    }

    private func update(_ id: String, phase: Phase) {
        guard tasks[id] != nil else { return }
        phases[id] = phase
    }

    private func update(_ id: String, partial: [TranscriptLine]) {
        guard tasks[id] != nil else { return }
        lines[id] = partial
    }
}

enum TranscriptionError: LocalizedError {
    case unavailable, language(String), audio
    var errorDescription: String? {
        switch self {
        case .unavailable: "On-device transcription isn’t available on this iPhone."
        case .language(let l): "On-device transcription doesn’t support this show’s language (\(l)) yet."
        case .audio: "This episode’s audio couldn’t be read for transcription."
        }
    }
}

/// Apple's on-device speech model (SpeechAnalyzer). The audio never leaves the phone.
enum OnDeviceTranscriber {
    static func run(media: URL, language: String?, duration: Double,
                    phase: @escaping @Sendable (TranscriptService.Phase) -> Void,
                    partial: @escaping @Sendable ([TranscriptLine]) -> Void) async throws -> [TranscriptLine] {
        guard SpeechTranscriber.isAvailable else { throw TranscriptionError.unavailable }

        let wanted = language.map { Locale(identifier: $0.replacingOccurrences(of: "_", with: "-")) } ?? Locale.current
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) else {
            throw TranscriptionError.language(wanted.identifier)
        }

        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            _ = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
                SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
            }
        }

        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            phase(.downloadingModel)
            try await request.downloadAndInstall()
        }

        let (audio, temporary) = try await localAudio(media, phase: phase)
        defer { if temporary { try? FileManager.default.removeItem(at: audio) } }
        try Task.checkCancellation()

        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: audio) } catch { throw TranscriptionError.audio }
        let total = duration > 0 ? duration : Double(file.length) / max(file.fileFormat.sampleRate, 1)
        phase(.transcribing(0))

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task {
            var cues: [TranscriptParser.Cue] = []
            var lastPush = Date.distantPast
            for try await result in transcriber.results {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                let start = result.range.start.seconds
                let end = result.range.end.seconds
                guard !text.isEmpty, start.isFinite else { continue }
                cues.append(TranscriptParser.Cue(start: start, end: end.isFinite ? end : start, text: text))
                if Date().timeIntervalSince(lastPush) > 1 {
                    lastPush = Date()
                    phase(.transcribing(min(1, max(0, (end.isFinite ? end : start) / max(total, 1)))))
                    partial(TranscriptParser.lines(from: cues))
                }
            }
            return cues
        }

        do {
            try await withTaskCancellationHandler {
                if let last = try await analyzer.analyzeSequence(from: file) {
                    try await analyzer.finalizeAndFinish(through: last)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
            } onCancel: {
                Task { await analyzer.cancelAndFinishNow() }
            }
        } catch {
            collector.cancel()
            throw error
        }
        try Task.checkCancellation()
        let cues = try await collector.value
        return TranscriptParser.lines(from: cues)
    }

    /// The episode's audio as a file on the phone: downloaded to the cache when it streams.
    private static func localAudio(_ media: URL, phase: @escaping @Sendable (TranscriptService.Phase) -> Void)
        async throws -> (URL, Bool) {
        if media.isFileURL { return (media, false) }
        phase(.downloadingAudio(0))
        let watcher = ProgressWatcher()
        let poll = Task {
            while !Task.isCancelled {
                if let fraction = watcher.fraction { phase(.downloadingAudio(fraction)) }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        defer { poll.cancel() }
        var request = URLRequest(url: media)
        request.setValue("PodCraft/1.0 (iPhone)", forHTTPHeaderField: "User-Agent")
        let (temp, response) = try await URLSession.shared.download(for: request, delegate: watcher)
        if let code = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(code) {
            try? FileManager.default.removeItem(at: temp)
            throw TranscriptionError.audio
        }
        let ext = media.pathExtension.isEmpty ? "mp3" : media.pathExtension
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        try FileManager.default.moveItem(at: temp, to: dest)
        return (dest, true)
    }
}

/// Keeps the download task so its progress can be read while it runs.
private final class ProgressWatcher: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        lock.withLock { self.task = task }
    }

    var fraction: Double? {
        lock.withLock {
            guard let task, task.countOfBytesExpectedToReceive > 0 else { return nil }
            return Double(task.countOfBytesReceived) / Double(task.countOfBytesExpectedToReceive)
        }
    }
}

// MARK: - Showing a transcript

/// Transcript lines in their own scroll area, following along as the episode plays. Tap a line to jump there.
/// Scrolling by hand pauses the following for a few seconds, so another line can be picked.
struct TranscriptLinesView: View {
    @Environment(AudioPlayer.self) private var player
    let lines: [TranscriptLine]
    var large = false
    @State private var followAfter = Date.distantPast

    var body: some View {
        let active = lines.last { $0.start <= player.position + 0.2 }?.start
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: large ? 18 : 12) {
                    ForEach(Array(lines.enumerated()), id: \.element.id) { i, line in
                        Button {
                            followAfter = .distantPast
                            player.seek(to: line.start)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                if let speaker = line.speaker, i == 0 || lines[i - 1].speaker != speaker {
                                    Text(speaker.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(Color.podTeal)
                                }
                                Text(line.text)
                                    .font(large ? .title2.weight(.semibold) : .title3.weight(.semibold))
                                    .foregroundStyle(line.start == active ? Color.primary : Color.secondary.opacity(0.7))
                                    .multilineTextAlignment(.leading)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(line.start)
                    }
                }
                .padding(.vertical, 8)
                .padding(.trailing, 6)
            }
            .scrollIndicators(.visible)
            .onScrollPhaseChange { _, phase in
                if phase == .interacting || phase == .decelerating { followAfter = Date().addingTimeInterval(5) }
            }
            .onChange(of: active) { _, now in
                guard let now, Date() >= followAfter else { return }
                withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(now, anchor: .center) }
            }
            .onAppear {
                if let active { proxy.scrollTo(active, anchor: .center) }
            }
        }
    }
}

/// The transcript on its own page, pulled up from the player: drag the handle down to go back.
struct TranscriptSheet: View {
    @Environment(AudioPlayer.self) private var player
    @Environment(\.dismiss) private var dismiss
    let title: String
    let lines: [TranscriptLine]

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("TRANSCRIPT").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    Text(title).font(.headline).lineLimit(1)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left").font(.subheadline.weight(.semibold))
                        .frame(width: 34, height: 34)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Minimize Transcript")
            }
            .padding(.horizontal, 20).padding(.top, 22).padding(.bottom, 8)

            TranscriptLinesView(lines: lines, large: true)
                .padding(.horizontal, 20)

            HStack(spacing: 28) {
                Text(Fmt.clock(player.position)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .leading)
                Spacer()
                Button { player.skip(-15) } label: { Image(systemName: "gobackward.15").font(.title2) }
                    .accessibilityLabel("Back 15 Seconds")
                Button { player.togglePlay() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                Button { player.skip(30) } label: { Image(systemName: "goforward.30").font(.title2) }
                    .accessibilityLabel("Forward 30 Seconds")
                Spacer()
                Text("−" + Fmt.clock(max(0, player.duration - player.position))).font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20).padding(.vertical, 12)
            .background(.bar)
        }
        .presentationDetents([.large, .medium])
        .presentationDragIndicator(.visible)
        .presentationBackground(.regularMaterial)
    }
}
