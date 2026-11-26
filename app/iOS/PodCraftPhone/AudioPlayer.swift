import AVFoundation
import MediaPlayer
import Observation
import UIKit

/// Plays episodes streamed from the Mac or straight from a show's feed, in the background too, with Lock Screen and Control Center controls.
/// Where you are is saved on the phone every few seconds and sent back to the Mac.
@MainActor
@Observable
final class AudioPlayer {
    private(set) var episode: RemoteEpisode?
    private(set) var isPlaying = false
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    /// Playback speed, kept by the Store so Sync can share it.
    var rate: Float { store?.rate ?? 1 }
    private(set) var isBuffering = false
    var showNowPlaying = false

    /// The AVPlayer, for the video picture.
    private(set) var player: AVPlayer?
    private weak var store: Store?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var lastReport = Date.distantPast
    private var artwork: MPMediaItemArtwork?

    init(store: Store) {
        self.store = store
        setUpRemoteCommands()
    }

    var chapters: [RemoteChapter] { episode.map { store?.chapters(for: $0) ?? $0.chapters } ?? [] }

    /// Sleep timer: pauses at this time, or at the end of the current chapter.
    private(set) var sleepAt: Date?
    private(set) var sleepAtChapterEnd = false
    /// Shown briefly after a sponsor read is skipped.
    private(set) var skippedSponsorAt: Date?
    /// A sponsor span the listener moved into on purpose plays through.
    @ObservationIgnored private var allowedSpan: Double?

    func setSleepTimer(minutes: Int?) {
        sleepAtChapterEnd = false
        sleepAt = minutes.map { Date().addingTimeInterval(Double($0) * 60) }
    }

    func sleepAtEndOfChapter() {
        sleepAt = nil
        sleepAtChapterEnd = true
    }

    var sleepRemaining: TimeInterval? { sleepAt.map { max(0, $0.timeIntervalSinceNow) } }

    var currentChapter: RemoteChapter? { chapters.last { $0.start <= position + 0.5 } }

    var show: RemoteShow? { episode.flatMap { store?.show($0.showID) } }

    // MARK: Playing

    func play(_ e: RemoteEpisode) {
        if episode?.id == e.id { if !isPlaying { resume() }; return }
        saveProgress(report: true)
        stopObserving()
        episode = e
        duration = e.duration
        let start = store.map { $0.isPlayed(e) ? 0 : $0.position(of: e) } ?? e.position
        position = start >= e.duration - 5 ? 0 : start
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: e.isVideo ? .moviePlayback : .spokenAudio, policy: .longFormAudio)
        try? session.setActive(true)
        // A downloaded episode plays from the phone, with no connection needed.
        let item = AVPlayerItem(url: Downloads.shared.localURL(for: e) ?? e.media)
        item.preferredForwardBufferDuration = 30
        let p = AVPlayer(playerItem: item)
        p.automaticallyWaitsToMinimizeStalling = true
        player = p
        observe(p, item: item)
        if position > 0 { p.seek(to: CMTime(seconds: position, preferredTimescale: 600)) }
        p.playImmediately(atRate: rate)
        isPlaying = true
        loadArtwork(for: e)
        updateNowPlaying()
        allowedSpan = nil
        Task { await store?.loadExtras(for: e) }
    }

    func togglePlay() { isPlaying ? pause() : resume() }

    func resume() {
        guard let player else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        player.playImmediately(atRate: rate)
        isPlaying = true
        updateNowPlaying()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        saveProgress(report: true)
        updateNowPlaying()
    }

    func seek(to seconds: Double) {
        let t = min(max(0, seconds), max(duration, 0))
        if let e = episode {
            allowedSpan = store?.skips(for: e).first { t >= $0.start && t < $0.end }?.start
        }
        position = t
        player?.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        saveProgress(report: false)
        updateNowPlaying()
    }

    func skip(_ delta: Double) { seek(to: position + delta) }

    func setRate(_ r: Float) {
        store?.setRate(r)
        if isPlaying { player?.rate = r }
        updateNowPlaying()
    }

    func nextChapter() {
        if let next = chapters.first(where: { $0.start > position + 1 }) { seek(to: next.start) }
    }

    func previousChapter() {
        guard let current = currentChapter else { seek(to: 0); return }
        if position - current.start > 3 { seek(to: current.start) }
        else if let previous = chapters.last(where: { $0.start < current.start }) { seek(to: previous.start) }
    }

    // MARK: Keeping track

    private func observe(_ p: AVPlayer, item: AVPlayerItem) {
        timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.position = t.seconds.isFinite ? t.seconds : self.position
                if let d = p.currentItem?.duration.seconds, d.isFinite, d > 0 { self.duration = d }
                self.isBuffering = p.timeControlStatus == .waitingToPlayAtSpecifiedRate
                self.saveProgress(report: Date().timeIntervalSince(self.lastReport) > 15)
                self.checkSponsorsAndSleep()
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let e = self.episode else { return }
                self.isPlaying = false
                self.store?.save(position: 0, for: e, played: true)
                self.store?.report(e)
                self.updateNowPlaying()
            }
        }
    }

    private func checkSponsorsAndSleep() {
        guard isPlaying, let e = episode, let store else { return }
        if let span = store.skips(for: e).first(where: { position >= $0.start && position < $0.end - 0.5 }),
           span.start != allowedSpan {
            let end = min(span.end, max(duration, span.end))
            position = end
            player?.seek(to: CMTime(seconds: end, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            skippedSponsorAt = Date()
            updateNowPlaying()
        }
        if let sleepAt, Date() >= sleepAt {
            self.sleepAt = nil
            pause()
        } else if sleepAtChapterEnd, let current = currentChapter,
                  let next = chapters.first(where: { $0.start > current.start }), position >= next.start - 0.6 {
            sleepAtChapterEnd = false
            pause()
        }
    }

    private func stopObserving() {
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player?.pause()
    }

    private func saveProgress(report: Bool) {
        guard let e = episode, let store else { return }
        store.save(position: position, for: e, played: store.isPlayed(e) && position < 1)
        if report {
            lastReport = Date()
            store.report(e)
        }
    }

    // MARK: Lock Screen and Control Center

    private func updateNowPlaying() {
        guard let e = episode else { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil; return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: e.title,
            MPMediaItemPropertyArtist: show?.author ?? "",
            MPMediaItemPropertyAlbumTitle: show?.title ?? "",
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(rate),
            MPNowPlayingInfoPropertyMediaType: e.isVideo ? MPNowPlayingInfoMediaType.video.rawValue : MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let chapter = currentChapter { info[MPNowPlayingInfoPropertyChapterNumber] = chapters.firstIndex(of: chapter) ?? 0 }
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func loadArtwork(for e: RemoteEpisode) {
        artwork = nil
        guard let url = e.artwork ?? show?.artwork else { return }
        Task {
            guard let image = await ImageCache.shared.image(for: url, pixels: 1200), episode?.id == e.id else { return }
            artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            updateNowPlaying()
        }
    }

    private func setUpRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.resume() }; return .success }
        c.pauseCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.pause() }; return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.togglePlay() }; return .success }
        c.skipForwardCommand.preferredIntervals = [30]
        c.skipForwardCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.skip(30) }; return .success }
        c.skipBackwardCommand.preferredIntervals = [15]
        c.skipBackwardCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.skip(-15) }; return .success }
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            MainActor.assumeIsolated { self?.seek(to: e.positionTime) }
            return .success
        }
        c.nextTrackCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.nextChapter() }; return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.previousChapter() }; return .success }
    }
}
