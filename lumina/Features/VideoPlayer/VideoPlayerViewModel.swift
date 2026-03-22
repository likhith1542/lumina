import AVFoundation
import Combine
import SwiftUI

// MARK: - SubtitleTrack

struct SubtitleTrack: Identifiable, Hashable {
    let id: String
    let displayName: String
    let option: AVMediaSelectionOption?   // nil for external/overlay subtitles

    static func == (lhs: SubtitleTrack, rhs: SubtitleTrack) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - AudioTrack

struct AudioTrack: Identifiable, Hashable {
    let id: String
    let displayName: String
    let option: AVMediaSelectionOption

    static func == (lhs: AudioTrack, rhs: AudioTrack) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - VideoPlayerViewModel

@Observable
final class VideoPlayerViewModel {
    var player:                AVPlayer?
    var playerState:           PlayerState = .idle
    var position:              TimeInterval = 0
    var duration:              TimeInterval = 0
    var volume:                Float = 1.0
    var isMuted                = false
    var playbackSpeed:         Float = 1.0
    var isPlaying              = false
    var subtitleTracks:        [SubtitleTrack] = []
    var audioTracks:           [AudioTrack] = []
    var selectedSubtitleTrack: SubtitleTrack? = nil
    var selectedAudioTrack:    AudioTrack? = nil
    var hasExternalSubtitle    = false
    var transcodeProgress:     Double = 0      // 0.0–1.0 while transcoding
    var isTranscoding          = false

    // Parsed SRT cues displayed as an overlay in VideoPlayerView
    var activeCue: String? = nil

    private var timeObserver:        Any?
    private var itemObserver:        AnyCancellable?
    private var endObserver:         Any?
    private var pauseObserver:       Any?
    private var cueTimer:            Timer?
    private var srtCues:             [SRTCue] = []
    private var isSeeking            = false
    private var pendingSeekTime:     TimeInterval? = nil
    private var externalSubtitleURL: URL? = nil
    private var currentItemId:       String? = nil
    private let repo = MediaItemRepository()

    var progress: Double {
        guard duration > 0 else { return 0 }
        return position / duration
    }

    // MARK: - Setters

    func setVolume(_ v: Float)        { volume = v;        player?.volume  = v }
    func setMuted(_ m: Bool)          { isMuted = m;       player?.isMuted = m }
    func setPlaybackSpeed(_ s: Float) { playbackSpeed = s; if isPlaying { player?.rate = s } }

    // MARK: - Load

    @MainActor
    // Exposed for UI audio picker sheet
    var availableAudioStreams: [AudioStreamInfo] = []
    var pendingItem: MediaItem? = nil
    var showAudioPicker = false

    func load(item: MediaItem) {
        cleanup()
        playerState = .loading(item.url)
        try? repo.incrementPlayCount(id: item.id)

        let ext = item.url.pathExtension.lowercased()

        Task { @MainActor in
            if FFmpegBridge.unsupportedExtensions.contains(ext) {
                let streams = await FFmpegBridge.shared.probeAudioStreams(url: item.url)
//                print("🎵 Probed \(streams.count) audio streams")

                if streams.count > 1 {
                    availableAudioStreams = streams
                    pendingItem           = item
                    showAudioPicker       = true
                    playerState           = .idle
                } else {
                    await transcodeAndPlay(item: item, audioStreamIndex: 0)
                }
                return
            }

            let isPlayable = await Self.checkPlayable(url: item.url)
            guard isPlayable else {
                playerState = .error("Cannot open: \(item.url.lastPathComponent)")
                return
            }
            loadAsset(item: item)
        }
    }

    @MainActor
    func loadWithAudio(audioStreamIndex: Int) {
        guard let item = pendingItem else { return }
        showAudioPicker      = false
        availableAudioStreams = []
        pendingItem          = nil
        Task { @MainActor in await transcodeAndPlay(item: item, audioStreamIndex: audioStreamIndex) }
    }

    @MainActor
    private func transcodeAndPlay(item: MediaItem, audioStreamIndex: Int) async {
        isTranscoding     = true
        transcodeProgress = 0

        let result = await FFmpegBridge.shared.prepare(
            url: item.url,
            audioStreamIndex: audioStreamIndex,
            knownDuration: item.duration ?? 0
        ) { [weak self] pct in self?.transcodeProgress = pct }

        isTranscoding = false

        switch result {
        case .success(let tempURL):
            var transcoded = item
            transcoded = MediaItem(
                id: item.id, url: tempURL, mediaType: item.mediaType,
                title: item.title, duration: item.duration,
                width: item.width, height: item.height,
                fileSize: item.fileSize, dateAdded: item.dateAdded,
                dateModified: item.dateModified, isFavorite: item.isFavorite,
                playCount: item.playCount, lastPlayed: item.lastPlayed,
                resumePosition: item.resumePosition
            )
            loadAsset(item: transcoded)
            // Auto-load sidecar subtitle extracted during remux
            if let srtURL = FFmpegBridge.shared.sidecarSubtitleURL(for: tempURL, sourceURL: item.url) {
//                print("🎬 Auto-loading sidecar subtitle: \(srtURL.lastPathComponent)")
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    self.loadExternalSubtitle(url: srtURL)
                }
            }
        case .notNeeded:
            loadAsset(item: item)
        case .failed(let msg):
            playerState = .error(msg)
        }
    }

    private static func checkPlayable(url: URL) async -> Bool {
        let asset = AVURLAsset(url: url, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true
        ])
        guard let tracks = try? await asset.load(.tracks) else { return false }
        return !tracks.isEmpty
    }

    private func loadAsset(item: MediaItem) {
        currentItemId = item.id
        let asset      = AVURLAsset(url: item.url, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true
        ])

        // Debug: log all tracks in the asset
//        Task {
//            if let tracks = try? await asset.load(.tracks) {
////                print("🎵 Asset tracks (\(tracks.count) total):")
//                for track in tracks {
////                    print("🎵  - \(track.mediaType.rawValue)")
//                }
//            }
//        }
        let playerItem = AVPlayerItem(asset: asset)
        let avPlayer   = AVPlayer(playerItem: playerItem)
        avPlayer.volume  = volume
        avPlayer.isMuted = isMuted
        // Must be false — true causes all audio tracks to play simultaneously
        avPlayer.appliesMediaSelectionCriteriaAutomatically = false

        player = avPlayer
        observePlayerItem(playerItem)
        addTimeObserver(to: avPlayer)
        observeEnd(of: avPlayer)

        if item.resumePosition > 3 {
            let t = CMTime(seconds: item.resumePosition, preferredTimescale: 600)
            avPlayer.seek(to: t, toleranceBefore: CMTime(seconds: 0.5, preferredTimescale: 600),
                          toleranceAfter: CMTime(seconds: 0.5, preferredTimescale: 600),
                          completionHandler: { _ in })
        }

        Task {
            await loadTracks(asset: asset, playerItem: playerItem)
            // Auto-restore last subtitle for this video
            await MainActor.run {
                if let savedURL = SubtitleMemory.load(forItemId: item.id) {
                    self.loadExternalSubtitle(url: savedURL)
                }
            }
        }
    }

    // MARK: - Controls

    func play() {
        // If finished, restart from the beginning
        if case .finished = playerState {
            player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                guard let self else { return }
                self.player?.rate = self.playbackSpeed
                self.isPlaying    = true
                self.playerState  = .playing
                self.startCueTimer()
            }
            return
        }
        player?.rate = playbackSpeed
        isPlaying    = true
        playerState  = .playing
        startCueTimer()
    }

    func pause() {
        player?.pause()
        isPlaying   = false
        playerState = .paused
        cueTimer?.invalidate()
    }

    func togglePlay() { isPlaying ? pause() : play() }

    // MARK: - Seek with debounce

    func seek(to time: TimeInterval, precise: Bool = false) {
        let clamped = time.clamped(to: 0...max(duration, 0))
        position = clamped
        updateActiveCue(for: clamped)

        if isSeeking {
            pendingSeekTime = clamped
            return
        }
        performSeek(to: clamped, precise: precise)
    }

    private func performSeek(to time: TimeInterval, precise: Bool = false) {
        isSeeking = true
        let cmTime    = CMTime(seconds: time, preferredTimescale: 600)
        let tolerance = precise ? CMTime.zero : CMTime(seconds: 0.1, preferredTimescale: 600)

        player?.seek(to: cmTime, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async {
                self.isSeeking = false
                if let next = self.pendingSeekTime {
                    self.pendingSeekTime = nil
                    self.performSeek(to: next, precise: precise)
                }
            }
        }
    }

    func skip(by seconds: TimeInterval) {
        seek(to: (position + seconds).clamped(to: 0...duration))
    }

    func stepFrame(forward: Bool) {
        guard let item = player?.currentItem else { return }
        pause()
        item.step(byCount: forward ? 1 : -1)
    }

    // MARK: - Embedded subtitle / audio track selection

    func selectSubtitle(_ track: SubtitleTrack?) {
        // External SRT track — already handled by cue timer
        if track?.id == "external" || track == nil && selectedSubtitleTrack?.id == "external" {
            if track == nil {
                srtCues = []; activeCue = nil; hasExternalSubtitle = false
                externalSubtitleURL = nil
            }
            selectedSubtitleTrack = track
            return
        }

        selectedSubtitleTrack = track
        guard let item = player?.currentItem else { return }
        Task { @MainActor in
            if let group = try? await item.asset.loadMediaSelectionGroup(for: .legible) {
                item.select(track?.option, in: group)
            }
        }
    }

    func selectAudio(_ track: AudioTrack) {
        selectedAudioTrack = track
        guard let item = player?.currentItem else { return }
        Task { @MainActor in
            if let group = try? await item.asset.loadMediaSelectionGroup(for: .audible) {
                item.select(track.option, in: group)
            }
        }
    }

    // MARK: - External SRT subtitle (rendered as SwiftUI overlay)

    func loadExternalSubtitle(url: URL) {
        guard let content = try? String(contentsOf: url, encoding: .utf8)
                         ?? String(contentsOf: url, encoding: .isoLatin1)
        else { return }

        let cues = SRTParser.parse(content)
        guard !cues.isEmpty else { return }

        srtCues             = cues
        externalSubtitleURL = url
        hasExternalSubtitle = true

        // Persist association: video item ID → subtitle file URL bookmark
        if let itemId = currentItemId {
            SubtitleMemory.save(subtitleURL: url, forItemId: itemId)
        }

        let track = SubtitleTrack(id: "external",
                                  displayName: url.deletingPathExtension().lastPathComponent,
                                  option: nil)
        subtitleTracks.removeAll { $0.id == "external" }
        subtitleTracks.append(track)
        selectedSubtitleTrack = track

        if let item = player?.currentItem {
            Task { @MainActor in
                if let group = try? await item.asset.loadMediaSelectionGroup(for: .legible) {
                    item.select(nil, in: group)
                }
            }
        }

        if isPlaying { startCueTimer() }
        updateActiveCue(for: position)
    }

    func clearExternalSubtitle() {
        srtCues             = []
        activeCue           = nil
        hasExternalSubtitle = false
        externalSubtitleURL = nil
        subtitleTracks.removeAll { $0.id == "external" }
        selectedSubtitleTrack = nil
        cueTimer?.invalidate()
        // Remove persisted association so it won't auto-load next time
        if let itemId = currentItemId { SubtitleMemory.clear(forItemId: itemId) }
    }

    // MARK: - Cue timer — updates activeCue as video plays

    private func startCueTimer() {
        cueTimer?.invalidate()
        guard !srtCues.isEmpty else { return }
        cueTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.updateActiveCue(for: self.position)
        }
    }

    private func updateActiveCue(for time: TimeInterval) {
        guard selectedSubtitleTrack?.id == "external", !srtCues.isEmpty else {
            activeCue = nil
            return
        }
        let cue = srtCues.first { time >= $0.startTime && time <= $0.endTime }
        activeCue = cue?.text
    }

    // MARK: - Resume

    func savePosition(for itemId: String) {
        guard position > 3, (duration - position) > 5 else { return }
        try? repo.saveResumePosition(id: itemId, position: position)
    }

    // MARK: - External player

    func openInExternalPlayer(url: URL) {
        let encoded = url.absoluteString
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let iinaURL = URL(string: "iina://weblink?url=\(encoded)"),
           NSWorkspace.shared.urlForApplication(toOpen: iinaURL) != nil {
            NSWorkspace.shared.open(iinaURL); return
        }
        if let vlcApp = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "org.videolan.vlc") {
            NSWorkspace.shared.open([url], withApplicationAt: vlcApp,
                                    configuration: NSWorkspace.OpenConfiguration())
            return
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Private helpers

    private func loadTracks(asset: AVURLAsset, playerItem: AVPlayerItem) async {
        async let subGroup = try? asset.loadMediaSelectionGroup(for: .legible)
        async let audGroup = try? asset.loadMediaSelectionGroup(for: .audible)
        let (sub, aud) = await (subGroup, audGroup)

//        print("🔊 AudioTracks: group=\(String(describing: aud)), options=\(aud?.options.count ?? 0)")
//        aud?.options.forEach {
//            print("🔊 Track: \($0.displayName) locale=\($0.locale?.identifier ?? "nil")")
//        }

        await MainActor.run {
            if let sub, !sub.options.isEmpty {
                // Don't overwrite existing external subtitle entry
                let embedded = sub.options.map {
                    SubtitleTrack(id: $0.displayName,
                                  displayName: $0.displayName,
                                  option: $0)
                }
                let external = subtitleTracks.filter { $0.id == "external" }
                subtitleTracks = embedded + external

                // Auto-select first embedded track
                if let first = embedded.first {
                    playerItem.select(first.option, in: sub)
                    if selectedSubtitleTrack == nil {
                        selectedSubtitleTrack = first
                    }
                }
            }
            if let aud, !aud.options.isEmpty {
                audioTracks = aud.options.enumerated().map { idx, option in
                    var name = option.displayName

                    if let locale = option.locale {
                        let langName = Locale.current.localizedString(forLanguageCode: locale.identifier)
                            ?? locale.identifier
                        name = langName
                    }

                    let extInfo = option.commonMetadata
                        .first(where: { $0.commonKey == .commonKeyTitle })?
                        .stringValue

                    if let extInfo, !extInfo.isEmpty, extInfo != name {
                        name = "\(name) — \(extInfo)"
                    } else if option.displayName != name {
                        name = "\(name) (\(option.displayName))"
                    }

                    if name.isEmpty || name == "und" { name = "Track \(idx + 1)" }

                    return AudioTrack(id: option.displayName, displayName: name, option: option)
                }

                // Explicitly select only the first audio track — prevents all tracks
                // playing simultaneously when appliesMediaSelectionCriteriaAutomatically = false
                if let first = aud.options.first {
                    playerItem.select(first, in: aud)
                    selectedAudioTrack = audioTracks.first
                }
            }
        }
    }

    private func observePlayerItem(_ item: AVPlayerItem) {
        itemObserver = item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                switch status {
                case .readyToPlay:
                    let dur = item.duration.seconds
                    self?.duration    = (dur.isNaN || dur.isInfinite) ? 0 : dur
                    self?.playerState = .ready
                    self?.play()
                case .failed:
                    self?.playerState = .error(
                        item.error?.localizedDescription ?? "Playback failed"
                    )
                default: break
                }
            }
    }

    private func addTimeObserver(to player: AVPlayer) {
        let interval = CMTime(value: 1, timescale: 10)
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: interval, queue: .main
        ) { [weak self] time in
            guard let self, !self.isSeeking else { return }
            self.position = time.seconds
        }
    }

    private func observeEnd(of player: AVPlayer) {
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem, queue: .main
        ) { [weak self] _ in
            self?.isPlaying   = false
            self?.playerState = .finished
            self?.cueTimer?.invalidate()
        }
    }

    private func cleanup() {
        if let obs = timeObserver  { player?.removeTimeObserver(obs) }
        if let obs = endObserver   { NotificationCenter.default.removeObserver(obs) }
        if let obs = pauseObserver { NotificationCenter.default.removeObserver(obs) }
        cueTimer?.invalidate()
        player?.pause()
        player = nil; timeObserver = nil; endObserver = nil; itemObserver = nil; pauseObserver = nil
        subtitleTracks = []; audioTracks = []
        selectedSubtitleTrack = nil; selectedAudioTrack = nil
        hasExternalSubtitle = false; externalSubtitleURL = nil
        srtCues = []; activeCue = nil
        isSeeking = false; pendingSeekTime = nil
    }

    /// Subscribe to window-close pause notification. Call once after init.
    func subscribeToPauseNotification() {
        guard pauseObserver == nil else { return }
        pauseObserver = NotificationCenter.default.addObserver(
            forName: Constants.Notification.pausePlayback,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.player?.pause()
            self?.isPlaying = false
        }
    }

    deinit { cleanup() }
}

// MARK: - SRT Parser

struct SRTCue {
    let index:     Int
    let startTime: TimeInterval
    let endTime:   TimeInterval
    let text:      String
}

enum SRTParser {
    static func parse(_ content: String) -> [SRTCue] {
        // Normalise line endings
        let normalised = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var cues: [SRTCue] = []
        let blocks = normalised.components(separatedBy: "\n\n")

        for block in blocks {
            let lines = block
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: "\n")
                .filter { !$0.isEmpty }

            guard lines.count >= 3 else { continue }

            // Index line
            guard let index = Int(lines[0].trimmingCharacters(in: .whitespaces))
            else { continue }

            // Timecode line: 00:00:01,000 --> 00:00:03,500
            let timeLine = lines[1]
            let parts = timeLine.components(separatedBy: " --> ")
            guard parts.count == 2,
                  let start = parseTime(parts[0].trimmingCharacters(in: .whitespaces)),
                  let end   = parseTime(parts[1].trimmingCharacters(in: .whitespaces))
            else { continue }

            // Remaining lines are the subtitle text
            let text = lines[2...].joined(separator: "\n")
                // Strip basic HTML tags like <i>, <b>, <font>
                .replacingOccurrences(of: "<[^>]+>",
                                      with: "",
                                      options: .regularExpression)

            cues.append(SRTCue(index: index, startTime: start, endTime: end, text: text))
        }
        return cues.sorted { $0.startTime < $1.startTime }
    }

    private static func parseTime(_ s: String) -> TimeInterval? {
        let norm  = s.replacingOccurrences(of: ",", with: ".")
        let parts = norm.components(separatedBy: ":")
        guard parts.count == 3,
              let h   = Double(parts[0]),
              let m   = Double(parts[1]),
              let sec = Double(parts[2])
        else { return nil }
        return h * 3600 + m * 60 + sec
    }
}
