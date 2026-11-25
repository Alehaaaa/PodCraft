import AppKit
import MediaPlayer

/// Publishes PodCraft's actual playback session to the macOS Now Playing service.
/// The system advances the elapsed time at the published rate; update it on state changes
/// and seeks rather than continuously from the player's 250 ms UI timer.
@MainActor
final class SystemMedia {
    private weak var player: Player?
    private let infoCenter = MPNowPlayingInfoCenter.default()
    private let commands = MPRemoteCommandCenter.shared()
    private var registrations: [(command: MPRemoteCommand, token: Any)] = []
    private var artworkSource: String?
    private var currentArtwork: MPMediaItemArtwork?
    private var artworkDownload: Task<Void, Never>?
    private var pendingArtworkURL: String?
    private var failedArtworkURL: String?

    /// Only send values between the remote command queue and the MainActor.
    private enum RemoteAction: Sendable {
        case play, pause, toggle, backward(Double), forward(Double), seek(Double)
    }

    init(player: Player) {
        self.player = player
        configureCommands()
        setRemoteEnabled(false)
    }

    isolated deinit {
        for registration in registrations {
            registration.command.removeTarget(registration.token)
        }
    }

    private func register(_ command: MPRemoteCommand,
                          _ action: @escaping @Sendable (MPRemoteCommandEvent) -> RemoteAction?) {
        command.isEnabled = true
        let token = command.addTarget { [weak self] event in
            guard let command = action(event) else { return .commandFailed }
            Task { @MainActor [weak self] in
                self?.handle(command)
            }
            return .success
        }
        registrations.append((command, token))
    }

    private func configureCommands() {
        register(commands.playCommand) { _ in .play }
        register(commands.pauseCommand) { _ in .pause }
        register(commands.togglePlayPauseCommand) { _ in .toggle }

        commands.skipBackwardCommand.preferredIntervals = [15]
        commands.skipForwardCommand.preferredIntervals = [15]
        register(commands.skipBackwardCommand) { event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 15
            return .backward(interval)
        }
        register(commands.skipForwardCommand) { event in
            .forward((event as? MPSkipIntervalCommandEvent)?.interval ?? 15)
        }
        register(commands.changePlaybackPositionCommand) { event in
            guard let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime,
                  position.isFinite else { return nil }
            return .seek(position)
        }

        // PodCraft's transport skips 15 seconds; avoid misleading previous/next track buttons.
        commands.stopCommand.isEnabled = false
        commands.nextTrackCommand.isEnabled = false
        commands.previousTrackCommand.isEnabled = false
    }

    private func handle(_ action: RemoteAction) {
        guard let player, player.episodeID != nil else { return }
        switch action {
        case .play: if !player.isPlaying { player.togglePlay() }
        case .pause: if player.isPlaying { player.togglePlay() }
        case .toggle: player.togglePlay()
        case .backward(let seconds): player.skip(by: -seconds)
        case .forward(let seconds): player.skip(by: seconds)
        case .seek(let position): player.seek(to: position)
        }
    }

    private func setRemoteEnabled(_ enabled: Bool) {
        commands.playCommand.isEnabled = enabled
        commands.pauseCommand.isEnabled = enabled
        commands.togglePlayPauseCommand.isEnabled = enabled
        commands.skipForwardCommand.isEnabled = enabled
        commands.skipBackwardCommand.isEnabled = enabled
        commands.changePlaybackPositionCommand.isEnabled = enabled
    }

    func publish() {
        guard let player, let episode = player.episode else { clear(); return }
        let show = player.showForNowPlaying
        let creator = show.flatMap { $0.author.isEmpty ? nil : $0.author }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: episode.title,
            MPMediaItemPropertyArtist: creator ?? show?.title ?? "PodCraft",
            MPMediaItemPropertyAlbumTitle: show?.title ?? "PodCraft",
            MPMediaItemPropertyPodcastTitle: show?.title ?? "PodCraft",
            MPMediaItemPropertyMediaType: MPMediaType.podcast.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: max(0, player.position),
            MPNowPlayingInfoPropertyPlaybackRate: player.isPlaying ? player.rate : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: player.rate
        ]
        if player.duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = player.duration }

        if let artwork = artwork(for: episode, show: show) {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        infoCenter.nowPlayingInfo = info
        // macOS needs an explicit playbackState or remote play/pause controls won't reliably work.
        infoCenter.playbackState = player.isPlaying ? .playing : .paused
        setRemoteEnabled(true)
    }

    private func artwork(for episode: Episode, show: Show?) -> MPMediaItemArtwork? {
        let source = [episode.artworkURL ?? "", show?.artworkURL ?? "", show?.customArtwork ?? ""]
            .joined(separator: "|")
        if artworkSource != source {
            artworkDownload?.cancel()
            artworkDownload = nil
            pendingArtworkURL = nil
            failedArtworkURL = nil
            artworkSource = source
            currentArtwork = nil
        }
        if let currentArtwork { return currentArtwork }

        let cover = ArtworkStore.thumbnail(remote: episode.artworkURL, points: 300)
            ?? ArtworkStore.thumbnail(remote: show?.artworkURL, localPath: show?.customArtwork, points: 300)
        if let cover {
            let artwork = MPMediaItemArtwork(boundsSize: cover.size) { _ in cover }
            currentArtwork = artwork
            return artwork
        }

        // Only one artwork request is active. A failed URL is not retried on every seek,
        // and an old download cannot replace the cover of a newly selected episode.
        if let url = episode.artworkURL ?? show?.artworkURL,
           pendingArtworkURL != url, failedArtworkURL != url {
            pendingArtworkURL = url
            artworkDownload = Task { @MainActor [weak self] in
                let fetched = await ArtworkStore.download(url)
                guard let self, !Task.isCancelled, self.pendingArtworkURL == url else { return }
                self.pendingArtworkURL = nil
                self.artworkDownload = nil
                if fetched {
                    self.currentArtwork = nil
                    self.publish()
                } else { self.failedArtworkURL = url }
            }
        }
        if let cover = Logo.image {
            let artwork = MPMediaItemArtwork(boundsSize: cover.size) { _ in cover }
            currentArtwork = artwork
            return artwork
        }
        return nil
    }

    func clear() {
        artworkDownload?.cancel()
        artworkDownload = nil
        pendingArtworkURL = nil
        failedArtworkURL = nil
        artworkSource = nil
        currentArtwork = nil
        infoCenter.playbackState = .stopped
        infoCenter.nowPlayingInfo = nil
        setRemoteEnabled(false)
    }
}
