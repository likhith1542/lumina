import AppKit
import Foundation
import AVFoundation
import Combine

// MARK: - AudioPlayerViewModel

@Observable
final class AudioPlayerViewModel {
    var trackTitle:  String          = "—"
    var artistName:  String          = "—"
    var albumName:   String          = "—"
    var albumArt:    AppKit.NSImage? = nil

    var isPlaying:    Bool         = false
    var position:     TimeInterval = 0
    var duration:     TimeInterval = 0
    var volume:       Float        = 1.0
    var spectrumData: [Float]      = Array(repeating: 0, count: 32)
    var eqBands:      [EQBand]     = AudioEngineService.defaultBands()

    private let engine       = AudioEngineService.shared
    private let repo         = MediaItemRepository()
    private var saveTimer:   Timer? = nil
    private var cancellables = Set<AnyCancellable>()
    private var playback:    PlaybackState? = nil
    private var pauseObserver: Any? = nil

    init() {
        engine.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.isPlaying    = self.engine.isPlaying
                self.position     = self.engine.position
                self.duration     = self.engine.duration
                self.volume       = self.engine.volume
                self.spectrumData = self.engine.spectrumData
                self.eqBands      = self.engine.eqBands
            }
            .store(in: &cancellables)

        pauseObserver = NotificationCenter.default.addObserver(
            forName: Constants.Notification.pausePlayback,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.engine.pause()
        }
    }

    deinit {
        if let obs = pauseObserver { NotificationCenter.default.removeObserver(obs) }
    }

    // Called once from AudioPlayerView.onAppear
    func attach(playback: PlaybackState) {
        self.playback = playback
        engine.onTrackEnd = { [weak self] in
            Task { @MainActor in self?.handleTrackEnd() }
        }
    }

    // MARK: - Load

    @MainActor
    func load(item: MediaItem, fromStart: Bool = false) async {
        trackTitle = item.title
        artistName = "—"
        albumName  = "—"
        albumArt   = nil

        do {
            try engine.load(url: item.url)
        } catch {
            return
        }

        await loadMetadata(url: item.url)

        // Only restore resume position on explicit user selection, not auto-advance
        if !fromStart && item.resumePosition > 3 {
            try? engine.seek(to: item.resumePosition)
        }

        startSaveTimer(itemId: item.id)
        try? repo.incrementPlayCount(id: item.id)
    }

    // MARK: - Controls

    func play()       { engine.play()  }
    func pause()      { engine.pause() }
    func stop()       { engine.stop(); saveTimer?.invalidate() }
    func togglePlay() { isPlaying ? pause() : play() }
    func seek(to time: TimeInterval) { try? engine.seek(to: time) }
    func setVolume(_ v: Float)       { engine.setVolume(v) }
    func skip(by seconds: TimeInterval) {
        try? engine.seek(to: (engine.position + seconds).clamped(to: 0...max(engine.duration, 1)))
    }

    func playNext() {
        guard let playback, playback.hasNext else { return }
        loadQueueItem(at: playback.queueIndex + 1, in: playback)
    }

    func playPrevious() {
        guard let playback, playback.hasPrevious else { return }
        loadQueueItem(at: playback.queueIndex - 1, in: playback)
    }
    // MARK: - EQ

    func updateBand(id: Int, gain: Float) { engine.updateBand(id: id, gain: gain) }
    func resetEQ()                         { engine.resetEQ() }

    // MARK: - Track end

    @MainActor
    private func handleTrackEnd() {
        guard let playback else {
            return
        }

        switch playback.loopMode {
        case .one:
            engine.restartAndPlay()

        case .all:
            let next = playback.hasNext ? playback.queueIndex + 1 : 0
            loadQueueItem(at: next, in: playback)

        case .none:
            guard playback.hasNext else { return }
            loadQueueItem(at: playback.queueIndex + 1, in: playback)
        }
    }

    /// Single method that advances the queue AND loads the track.
    /// Never relies on the view re-rendering to trigger the load.
    @MainActor
    private func loadQueueItem(at index: Int, in playback: PlaybackState) {
        guard index >= 0, index < playback.queue.count else {
            return
        }
        let item = playback.queue[index]
        playback.queueIndex  = index
        playback.currentItem = item

        // Load directly — don't wait for view re-render
        Task { @MainActor in await self.load(item: item, fromStart: true) }
    }

    // MARK: - Private

    private func loadMetadata(url: URL) async {
        let asset = AVURLAsset(url: url)
        guard let meta = try? await asset.load(.metadata) else { return }
        for item in meta {
            guard let key = item.commonKey else { continue }
            switch key {
            case .commonKeyTitle:
                if let v = try? await item.load(.stringValue) {
                    await MainActor.run { trackTitle = v }
                }
            case .commonKeyArtist:
                if let v = try? await item.load(.stringValue) {
                    await MainActor.run { artistName = v }
                }
            case .commonKeyAlbumName:
                if let v = try? await item.load(.stringValue) {
                    await MainActor.run { albumName = v }
                }
            case .commonKeyArtwork:
                if let d = try? await item.load(.dataValue),
                   let img = NSImage(data: d) {
                    await MainActor.run { albumArt = img }
                }
            default: break
            }
        }
    }

    private func startSaveTimer(itemId: String) {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                try? self.repo.saveResumePosition(id: itemId, position: self.engine.position)
            }
        }
    }
}
