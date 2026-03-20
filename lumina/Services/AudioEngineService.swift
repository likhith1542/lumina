import AVFoundation
import Combine

// MARK: - EQBand

struct EQBand: Identifiable {
    let id: Int
    var frequency: Float
    var gain: Float
    var bandwidth: Float
}

// MARK: - AudioEngineService
//
// Runs entirely on the main thread — no background thread access.
// Spectrum visualiser uses a simple animation — no AVAudioEngine tap.

final class AudioEngineService: ObservableObject {
    static let shared = AudioEngineService()

    // Engine nodes
    private var engine:     AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var eq:         AVAudioUnitEQ?
    private var graphBuilt  = false

    // Playback tracking
    private var currentURL:    URL?
    private var fileDuration:  TimeInterval = 0
    private var seekOffset:    TimeInterval = 0
    private var generation:    Int = 0
    private var didFireEnd     = false
    private var positionTimer: Timer?
    private var spectrumTimer: Timer?
    private var spectrumPhase: Float = 0

    @Published var isPlaying:     Bool         = false
    @Published var volume:        Float        = 1.0
    @Published var isMuted:       Bool         = false
    @Published var playbackSpeed: Float        = 1.0
    @Published var eqBands:       [EQBand]     = AudioEngineService.defaultBands()
    @Published var spectrumData:  [Float]      = Array(repeating: 0, count: 32)
    @Published var duration:      TimeInterval = 0
    @Published var position:      TimeInterval = 0
    @Published var trackFinished: Bool         = false

    var onTrackEnd: (() -> Void)?

    private init() {}

    // MARK: - Graph (built once, lazily)

    private func buildGraph() {
        guard !graphBuilt else { return }
        graphBuilt = true

        let eng  = AVAudioEngine()
        let node = AVAudioPlayerNode()
        let eq_  = AVAudioUnitEQ(numberOfBands: 10)

        eng.attach(node)
        eng.attach(eq_)
        eng.connect(node, to: eq_,               format: nil)
        eng.connect(eq_,  to: eng.mainMixerNode, format: nil)

        engine     = eng
        playerNode = node
        eq         = eq_

        applyEQBands()
        eng.mainMixerNode.outputVolume = isMuted ? 0 : volume

        do { try eng.start() }
        catch { print("Engine start: \(error)") }
    }

    // MARK: - Volume / Speed

    func setVolume(_ v: Float) {
        volume = v
        engine?.mainMixerNode.outputVolume = isMuted ? 0 : v
    }

    func setMuted(_ m: Bool) {
        isMuted = m
        engine?.mainMixerNode.outputVolume = m ? 0 : volume
    }

    func setPlaybackSpeed(_ s: Float) {
        playbackSpeed = s
        playerNode?.rate = s
    }

    // MARK: - Load

    func load(url: URL) throws {
        buildGraph()
        cancelCurrent()

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AppError.fileNotFound(url)
        }

        let file     = try AVAudioFile(forReading: url)
        currentURL   = url
        fileDuration = Double(file.length) / file.processingFormat.sampleRate
        duration     = fileDuration
        position     = 0
        seekOffset   = 0

        startEngine()
        let g = generation
        schedule(file: file, from: 0, gen: g)
    }

    // MARK: - Playback controls

    func play() {
        guard !isPlaying else { return }
        if trackFinished {
            trackFinished = false
            didFireEnd    = false
            try? seek(to: 0)
            return
        }
        startEngine()
        playerNode?.play()
        isPlaying = true
        startTimers(gen: generation)
    }

    func pause() {
        guard isPlaying else { return }
        seekOffset = currentPosition
        playerNode?.pause()
        isPlaying = false
        stopTimers()
    }

    func stop() {
        cancelCurrent()
        currentURL    = nil
        fileDuration  = 0
        duration      = 0
        position      = 0
        seekOffset    = 0
        trackFinished = false
        spectrumData  = Array(repeating: 0, count: 32)
    }

    func restartAndPlay() {
        didFireEnd    = false
        trackFinished = false
        try? seek(to: 0)
    }

    func seek(to time: TimeInterval) throws {
        guard let url = currentURL else { return }
        let t = time.clamped(to: 0...max(fileDuration, 0))

        cancelCurrent()
        seekOffset = t
        position   = t

        let file = try AVAudioFile(forReading: url)
        startEngine()
        let g = generation
        schedule(file: file, from: t, gen: g)
    }

    // MARK: - EQ

    func applyEQBands() {
        guard let eq else { return }
        for (i, band) in eqBands.enumerated() {
            guard i < eq.bands.count else { continue }
            eq.bands[i].filterType = .parametric
            eq.bands[i].frequency  = band.frequency
            eq.bands[i].gain       = band.gain
            eq.bands[i].bandwidth  = band.bandwidth
            eq.bands[i].bypass     = false
        }
    }

    func updateBand(id: Int, gain: Float) {
        guard id < eqBands.count, let eq else { return }
        eqBands[id].gain  = gain.clamped(to: -24...24)
        eq.bands[id].gain = eqBands[id].gain
    }

    func resetEQ() {
        eqBands = Self.defaultBands()
        applyEQBands()
    }

    static func defaultBands() -> [EQBand] {
        let freqs: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
        return freqs.enumerated().map {
            EQBand(id: $0.offset, frequency: $0.element, gain: 0, bandwidth: 1.0)
        }
    }

    // MARK: - Private

    private func cancelCurrent() {
        stopTimers()
        playerNode?.stop()
        isPlaying  = false
        didFireEnd = false
        generation &+= 1
    }

    private func schedule(file: AVAudioFile,
                          from time: TimeInterval,
                          gen: Int) {
        guard let node = playerNode else { return }

        let sr    = file.processingFormat.sampleRate
        let start = AVAudioFramePosition(time * sr)
        let count = file.length - start
        guard count > 0 else { fireEnd(gen: gen); return }

        // Dispatch completion back to main queue explicitly
        // Do NOT capture self on the audio thread
        let onComplete: () -> Void = {
            DispatchQueue.main.async {
                AudioEngineService.shared.fireEnd(gen: gen)
            }
        }

        node.scheduleSegment(
            file,
            startingFrame: start,
            frameCount: AVAudioFrameCount(count),
            at: nil,
            completionCallbackType: .dataPlayedBack
        ) { _ in onComplete() }

        node.play()
        isPlaying = true
        startTimers(gen: gen)
    }

    private func fireEnd(gen: Int) {
        guard gen == generation, !didFireEnd else { return }
        guard fileDuration == 0 || currentPosition >= fileDuration - 0.5 else { return }
        didFireEnd    = true
        isPlaying     = false
        trackFinished = true
        position      = fileDuration
        stopTimers()
        spectrumData  = Array(repeating: 0, count: 32)
        onTrackEnd?()
    }

    var currentPosition: TimeInterval {
        guard let node = playerNode,
              let nodeTime   = node.lastRenderTime,
              let playerTime = node.playerTime(forNodeTime: nodeTime),
              playerTime.sampleRate > 0
        else { return seekOffset }
        let elapsed = Double(playerTime.sampleTime) / playerTime.sampleRate
        return (seekOffset + elapsed / Double(max(playbackSpeed, 0.1)))
            .clamped(to: 0...max(fileDuration, 0))
    }

    private func startTimers(gen: Int) {
        stopTimers()

        // Position timer — main thread only
        positionTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, self.isPlaying, gen == self.generation else { return }
            let pos = self.currentPosition
            self.position = pos
            if pos >= self.fileDuration - 0.1, self.fileDuration > 0 {
                self.fireEnd(gen: gen)
            }
        }

        // Spectrum animation — purely visual, no audio thread access
        spectrumTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.tickSpectrum()
        }
    }

    private func stopTimers() {
        positionTimer?.invalidate(); positionTimer = nil
        spectrumTimer?.invalidate(); spectrumTimer = nil
    }

    private func tickSpectrum() {
        spectrumPhase += 0.08
        var bands = [Float](repeating: 0, count: 32)
        for i in 0..<32 {
            let f = Float(i) / 32.0
            let envelope: Float = 1.0 - abs(f - 0.3) * 1.4
            let wave = sin(spectrumPhase * (1.0 + f * 3.0) + Float(i) * 0.4)
            bands[i] = max(0, min(1, envelope * (0.4 + 0.45 * wave + Float.random(in: -0.05...0.05))))
        }
        spectrumData = bands
    }

    private func startEngine() {
        guard let eng = engine, !eng.isRunning else { return }
        try? eng.start()
    }
}
