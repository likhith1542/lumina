import SwiftUI
import AVKit
import AVFoundation

// MARK: - SubtitleOverlay (render only — drag handled by parent ZStack)

struct SubtitleOverlay: View {
    let cue: String
    let fontSize: CGFloat
    let position: CGPoint   // normalised 0-1

    var body: some View {
        GeometryReader { geo in
            let scaledFont = max(10, fontSize * geo.size.height / 540)
            Text(cue)
                .font(.system(size: scaledFont, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.95), radius: 1, x:  1, y:  1)
                .shadow(color: .black.opacity(0.95), radius: 1, x: -1, y: -1)
                .shadow(color: .black.opacity(0.75), radius: 3, x:  0, y:  0)
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .frame(maxWidth: geo.size.width * 0.85)
                .position(
                    x: position.x * geo.size.width,
                    y: position.y * geo.size.height
                )
        }
        .allowsHitTesting(false)
    }
}

// MARK: - VideoPlayerView

struct VideoPlayerView: View {
    let item: MediaItem
    let playback: PlaybackState

    @State private var vm                 = VideoPlayerViewModel()
    @State private var showControls       = true
    @State private var controlsTimer:     Timer? = nil
    @State private var showSubtitlePicker = false
    @State private var subtitleFontSize:  CGFloat = 18
    @State private var subtitlePosition:  CGPoint = CGPoint(x: 0.5, y: 0.88)
    // Track whether mouse is inside the view
    @State private var mouseInside        = false

    var body: some View {
        GeometryReader { geo in
        ZStack {
            Color.black.ignoresSafeArea()

            if let player = vm.player {
                AVPlayerLayerView(player: player)
                    .ignoresSafeArea()
                    .onTapGesture { showControls = true; scheduleHide() }
            }

            if case .loading = vm.playerState {
                ProgressView().tint(.white).scaleEffect(1.5)
            }

            // Transcode progress overlay — shown while FFmpeg converts unsupported formats
            if vm.isTranscoding {
                VStack(spacing: 16) {
                    Image(systemName: "gearshape.2.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.white.opacity(0.8))
                        .rotationEffect(.degrees(vm.transcodeProgress * 360))
                        .animation(.linear(duration: 1).repeatForever(autoreverses: false),
                                   value: vm.isTranscoding)

                    Text("Transcoding…")
                        .font(.headline)
                        .foregroundStyle(.white)

                    ProgressView(value: vm.transcodeProgress)
                        .tint(.white)
                        .frame(width: 200)

                    Text("\(Int(vm.transcodeProgress * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.7))
                }
                .padding(32)
                .background(.black.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }

            if case .error(let msg) = vm.playerState {
                VStack(spacing: 20) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 44)).foregroundStyle(.yellow)
                    VStack(spacing: 8) {
                        ForEach(msg.components(separatedBy: "\n"), id: \.self) { line in
                            Text(line)
                                .foregroundStyle(line.hasPrefix("Tip:")
                                    ? .yellow.opacity(0.8) : .white.opacity(0.9))
                                .font(line.hasPrefix("Tip:") ? .caption : .body)
                                .multilineTextAlignment(.center)
                        }
                    }.padding(.horizontal, 40)
                    ExternalPlayerButtons(item: item, vm: vm)
                }
            }

            if let cue = vm.activeCue, !cue.isEmpty {
                SubtitleOverlay(
                    cue: cue,
                    fontSize: subtitleFontSize,
                    position: subtitlePosition
                )
            }

            // Controls — opacity toggled, always in hierarchy for hit testing
            VideoControlsOverlay(
                vm: vm,
                subtitleFontSize: $subtitleFontSize,
                onSubtitlePicker: { showSubtitlePicker = true },
                onFullscreen: { openVideoFullscreen() }
            )
            .opacity(showControls ? 1 : 0)
            .animation(.easeInOut(duration: 0.25), value: showControls)
            .allowsHitTesting(showControls)
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture(count: 2).onEnded { })
            .simultaneousGesture(TapGesture(count: 1).onEnded { })
        }
        // Subtitle drag — on ZStack with GeometryReader frame available
        .gesture(vm.activeCue != nil ? DragGesture(minimumDistance: 2)
            .onChanged { val in
                subtitlePosition = CGPoint(
                    x: (val.location.x / geo.size.width).clamped(to: 0.05...0.95),
                    y: (val.location.y / geo.size.height).clamped(to: 0.05...0.95)
                )
            } : nil
        )
        .onWindowKeyPress(id: "videoplayer") { event in
            switch event.keyCode {
            case 49:  vm.togglePlay(); showControls = true; scheduleHide(); return true
            case 123: vm.skip(by: -10); showControls = true; scheduleHide(); return true
            case 124: vm.skip(by:  10); showControls = true; scheduleHide(); return true
            case 126: vm.setVolume(min(1, vm.volume + 0.1)); return true
            case 125: vm.setVolume(max(0, vm.volume - 0.1)); return true
            default:  return false
            }
        }
        .onHover { inside in
            mouseInside = inside
            if inside {
                // Show controls whenever mouse enters — always
                showControls = true
                scheduleHide()
            } else {
                // Mouse left — hide controls after brief delay
                controlsTimer?.invalidate()
                controlsTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
                    DispatchQueue.main.async {
                        if !self.mouseInside {
                            withAnimation(.easeInOut(duration: 0.3)) { self.showControls = false }
                        }
                    }
                }
            }
        }
        // Mouse moved inside — keep refreshing the hide timer
        .onContinuousHover { phase in
            switch phase {
            case .active:
                if !showControls { showControls = true }
                scheduleHide()
            case .ended:
                break
            }
        }
        .onAppear   { vm.load(item: item); showControls = true }
        .onDisappear {
            vm.savePosition(for: item.id)
            vm.pause()
            controlsTimer?.invalidate()
            KeyEventHandler.shared.unregister(id: "videoplayer")
        }
        .id(item.id)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $vm.showAudioPicker) {
            AudioPickerSheet(streams: vm.availableAudioStreams) { index in
                vm.loadWithAudio(audioStreamIndex: index)
            }
        }
        } // GeometryReader
        .fileImporter(
            isPresented: $showSubtitlePicker,
            allowedContentTypes: [
                UTType(filenameExtension: "srt") ?? .plainText,
                UTType(filenameExtension: "ass") ?? .plainText,
                UTType(filenameExtension: "vtt") ?? .plainText
            ],
            allowsMultipleSelection: false
        ) { result in
            if let url = try? result.get().first {
                vm.loadExternalSubtitle(url: url)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { showSubtitlePicker = true } label: {
                    Image(systemName: vm.hasExternalSubtitle
                          ? "captions.bubble.fill" : "captions.bubble")
                }
                .help("Load subtitle file (.srt)")

                Button { openVideoFullscreen() } label: {
                    Image(systemName: "arrow.up.backward.and.arrow.down.forward.square")
                }
                .help("Full Screen  F")
                .keyboardShortcut("f", modifiers: [])
            }
        }
    }

    // Controls hide after inactivity — only when playing
    private func scheduleHide() {
        controlsTimer?.invalidate()
        controlsTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { _ in
            DispatchQueue.main.async {
                guard self.vm.isPlaying, self.mouseInside else { return }
                withAnimation(.easeInOut(duration: 0.35)) { self.showControls = false }
            }
        }
    }

    private func openVideoFullscreen() {
        guard let player = vm.player else { return }
        let wasPlaying = vm.isPlaying
        FullscreenWindowManager.shared.present {
            FullscreenVideoView(
                player: player,
                vm: vm,
                wasPlaying: wasPlaying,
                subtitleFontSize: $subtitleFontSize,
                subtitlePosition: $subtitlePosition,
                onSubtitlePicker: { showSubtitlePicker = true }
            )
        }
    }
}

// MARK: - AVPlayerLayerView

struct AVPlayerLayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> PlayerContainerView {
        let v = PlayerContainerView(); v.player = player; return v
    }
    func updateNSView(_ nsView: PlayerContainerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
    }
}

final class PlayerContainerView: NSView {
    private let playerLayer = AVPlayerLayer()
    var player: AVPlayer? {
        get { playerLayer.player }
        set { playerLayer.player = newValue }
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = CGColor.black
        layer?.addSublayer(playerLayer)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}

// MARK: - VideoControlsOverlay

struct VideoControlsOverlay: View {
    @Bindable var vm: VideoPlayerViewModel
    @Binding var subtitleFontSize: CGFloat
    let onSubtitlePicker: () -> Void
    let onFullscreen: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 12) {
                ScrubBar(
                    position: vm.position,
                    duration: vm.duration,
                    onScrubbing: { _ in },
                    onSeek: { vm.seek(to: $0) }
                )
                HStack(spacing: 14) {
                    cBtn("gobackward.10")  { vm.skip(by: -10) }
                    cBtn("backward.frame") { vm.stepFrame(forward: false) }

                    Button { vm.togglePlay() } label: {
                        Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)

                    cBtn("forward.frame") { vm.stepFrame(forward: true) }
                    cBtn("goforward.10")  { vm.skip(by: 10) }

                    Spacer()

                    Text("\(vm.position.formatted) / \(vm.duration.formatted)")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.white)

                    Spacer()

                    cBtn(vm.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill") {
                        vm.setMuted(!vm.isMuted)
                    }
                    Slider(value: Binding(
                        get: { Double(vm.volume) },
                        set: { vm.setVolume(Float($0)) }
                    ), in: 0...1).frame(width: 80).tint(.white)

                    Menu {
                        ForEach([0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { s in
                            Button(s == 1.0 ? "Normal" : String(format: "%.2g×", s)) {
                                vm.setPlaybackSpeed(Float(s))
                            }
                        }
                    } label: {
                        Text(vm.playbackSpeed == 1 ? "1×" : String(format: "%.2g×", vm.playbackSpeed))
                            .font(.caption).foregroundStyle(.white).frame(minWidth: 28)
                    }.menuStyle(.button).buttonStyle(.plain)

                    Menu {
                        Button("Off") { vm.selectSubtitle(nil) }
                        if !vm.subtitleTracks.isEmpty {
                            Divider()
                            ForEach(vm.subtitleTracks) { track in
                                Button {
                                    vm.selectSubtitle(track)
                                } label: {
                                    if vm.selectedSubtitleTrack?.id == track.id {
                                        Label(track.displayName, systemImage: "checkmark")
                                    } else { Text(track.displayName) }
                                }
                            }
                        }
                        Divider()
                        Button("Load Subtitle File…") { onSubtitlePicker() }
                        if vm.hasExternalSubtitle {
                            Divider()
                            Button {
                                subtitleFontSize = max(12, subtitleFontSize - 2)
                            } label: {
                                Label("Smaller (\(Int(subtitleFontSize))pt → \(Int(max(12, subtitleFontSize-2)))pt)",
                                      systemImage: "textformat.size.smaller")
                            }
                            Button {
                                subtitleFontSize = min(40, subtitleFontSize + 2)
                            } label: {
                                Label("Larger (\(Int(subtitleFontSize))pt → \(Int(min(40, subtitleFontSize+2)))pt)",
                                      systemImage: "textformat.size.larger")
                            }
                            Divider()
                            Button("Remove Subtitle") { vm.clearExternalSubtitle() }
                        }
                    } label: {
                        Image(systemName: vm.selectedSubtitleTrack != nil
                              ? "captions.bubble.fill" : "captions.bubble")
                            .foregroundStyle(.white)
                    }.menuStyle(.button).buttonStyle(.plain)

                    if vm.hasExternalSubtitle {
                        cBtn("textformat.size.smaller") { subtitleFontSize = max(12, subtitleFontSize - 2) }
                        cBtn("textformat.size.larger")  { subtitleFontSize = min(40, subtitleFontSize + 2) }
                    }

                    if !vm.audioTracks.isEmpty {
                        Menu {
                            Section("Audio Track") {
                                ForEach(vm.audioTracks) { track in
                                    Button {
                                        vm.selectAudio(track)
                                    } label: {
                                        if vm.selectedAudioTrack?.id == track.id {
                                            Label(track.displayName, systemImage: "checkmark")
                                        } else { Text(track.displayName) }
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: "speaker.badge.waveform").foregroundStyle(.white)
                        }.menuStyle(.button).buttonStyle(.plain)
                    }

                    cBtn("arrow.up.backward.and.arrow.down.forward") { onFullscreen() }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .background(LinearGradient(
                colors: [.clear, .black.opacity(0.8)],
                startPoint: .top, endPoint: .bottom
            ))
        }
    }

    @ViewBuilder
    private func cBtn(_ name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

// MARK: - ScrubBar

struct ScrubBar: View {
    let position: TimeInterval
    let duration: TimeInterval
    let onScrubbing: (Bool) -> Void
    let onSeek: (TimeInterval) -> Void
    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0

    private var displayValue: Double {
        guard duration > 0 else { return 0 }
        return isScrubbing ? scrubValue : (position / duration)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(.white.opacity(0.3)).frame(height: 4)
                RoundedRectangle(cornerRadius: 2).fill(.white)
                    .frame(width: max(0, geo.size.width * displayValue), height: 4)
                Circle().fill(.white)
                    .frame(width: isScrubbing ? 16 : 12, height: isScrubbing ? 16 : 12)
                    .offset(x: max(0, geo.size.width * displayValue - (isScrubbing ? 8 : 6)))
                    .animation(.easeInOut(duration: 0.1), value: isScrubbing)
            }
            .frame(height: 20).contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { val in
                    isScrubbing = true
                    scrubValue  = (val.location.x / geo.size.width).clamped(to: 0...1)
                    onScrubbing(true)
                }
                .onEnded { _ in
                    onSeek(scrubValue * duration)
                    isScrubbing = false; onScrubbing(false)
                }
            )
        }.frame(height: 20)
    }
}

// MARK: - FullscreenVideoView

struct FullscreenVideoView: View {
    let player: AVPlayer
    let vm: VideoPlayerViewModel
    let wasPlaying: Bool
    @Binding var subtitleFontSize: CGFloat
    @Binding var subtitlePosition: CGPoint
    let onSubtitlePicker: () -> Void

    @State private var showControls   = true
    @State private var controlsTimer: Timer? = nil
    @State private var mouseInside    = false

    var body: some View {
        GeometryReader { geo in
        ZStack {
            Color.black.ignoresSafeArea()

            AVPlayerLayerView(player: player)
                .ignoresSafeArea()
                .onTapGesture { showControlsTemporarily() }

            if let cue = vm.activeCue, !cue.isEmpty {
                SubtitleOverlay(
                    cue: cue,
                    fontSize: subtitleFontSize,
                    position: subtitlePosition
                )
            }

            FullscreenVideoControls(
                vm: vm,
                subtitleFontSize: $subtitleFontSize,
                onSubtitlePicker: {
                    FullscreenWindowManager.shared.dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { onSubtitlePicker() }
                },
                onDismiss: { FullscreenWindowManager.shared.dismiss() }
            )
            .opacity(showControls ? 1 : 0)
            .animation(.easeInOut(duration: 0.25), value: showControls)
            .allowsHitTesting(showControls)
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture(count: 2).onEnded { })
            .simultaneousGesture(TapGesture(count: 1).onEnded { })
        }
        .gesture(vm.activeCue != nil ? DragGesture(minimumDistance: 2)
            .onChanged { val in
                subtitlePosition = CGPoint(
                    x: (val.location.x / geo.size.width).clamped(to: 0.05...0.95),
                    y: (val.location.y / geo.size.height).clamped(to: 0.05...0.95)
                )
            } : nil
        )
        .onHover { inside in
            mouseInside = inside
            if inside { showControls = true; scheduleHide() }
            else {
                controlsTimer?.invalidate()
                controlsTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
                    DispatchQueue.main.async {
                        if !self.mouseInside {
                            withAnimation(.easeInOut(duration: 0.3)) { self.showControls = false }
                        }
                    }
                }
            }
        }
        .onContinuousHover { phase in
            if case .active = phase {
                if !showControls { showControls = true }
                scheduleHide()
            }
        }
        .onWindowKeyPress(id: "fullscreen-video") { event in
            switch event.keyCode {
            case 49:  vm.togglePlay(); showControlsTemporarily(); return true
            case 123: vm.skip(by: -10); showControlsTemporarily(); return true
            case 124: vm.skip(by:  10); showControlsTemporarily(); return true
            case 126: vm.setVolume(min(1, vm.volume + 0.1)); return true
            case 125: vm.setVolume(max(0, vm.volume - 0.1)); return true
            case 53:  FullscreenWindowManager.shared.dismiss(); return true
            default:  return false
            }
        }
        .onAppear   { if wasPlaying { vm.play() }; showControls = true; scheduleHide() }
        .onDisappear {
            controlsTimer?.invalidate()
            KeyEventHandler.shared.unregister(id: "fullscreen-video")
        }
        } // GeometryReader
    }

    private func showControlsTemporarily() {
        showControls = true
        scheduleHide()
    }

    private func scheduleHide() {
        controlsTimer?.invalidate()
        controlsTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { _ in
            DispatchQueue.main.async {
                guard self.vm.isPlaying, self.mouseInside else { return }
                withAnimation(.easeInOut(duration: 0.35)) { self.showControls = false }
            }
        }
    }
}

// MARK: - FullscreenVideoControls

struct FullscreenVideoControls: View {
    @Bindable var vm: VideoPlayerViewModel
    @Binding var subtitleFontSize: CGFloat
    let onSubtitlePicker: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 14) {
                ScrubBar(
                    position: vm.position,
                    duration: vm.duration,
                    onScrubbing: { _ in },
                    onSeek: { vm.seek(to: $0) }
                )
                HStack(spacing: 16) {
                    fsBtn("gobackward.10")  { vm.skip(by: -10) }
                    fsBtn("backward.frame") { vm.stepFrame(forward: false) }

                    Button { vm.togglePlay() } label: {
                        Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 28, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(width: 52, height: 52)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)

                    fsBtn("forward.frame")  { vm.stepFrame(forward: true) }
                    fsBtn("goforward.10")   { vm.skip(by: 10) }

                    Spacer()

                    Text("\(vm.position.formatted) / \(vm.duration.formatted)")
                        .font(.system(size: 14).monospacedDigit())
                        .foregroundStyle(.white)

                    Spacer()

                    fsBtn(vm.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill") {
                        vm.setMuted(!vm.isMuted)
                    }
                    Slider(value: Binding(
                        get: { Double(vm.volume) },
                        set: { vm.setVolume(Float($0)) }
                    ), in: 0...1).frame(width: 110).tint(.white)

                    Menu {
                        Button("Off") { vm.selectSubtitle(nil) }
                        if !vm.subtitleTracks.isEmpty {
                            Divider()
                            ForEach(vm.subtitleTracks) { track in
                                Button {
                                    vm.selectSubtitle(track)
                                } label: {
                                    if vm.selectedSubtitleTrack?.id == track.id {
                                        Label(track.displayName, systemImage: "checkmark")
                                    } else { Text(track.displayName) }
                                }
                            }
                        }
                        Divider()
                        Button("Load Subtitle File…") { onSubtitlePicker() }
                        if vm.hasExternalSubtitle {
                            Divider()
                            Button {
                                subtitleFontSize = max(12, subtitleFontSize - 2)
                            } label: {
                                Label("Smaller (\(Int(subtitleFontSize))pt)",
                                      systemImage: "textformat.size.smaller")
                            }
                            Button {
                                subtitleFontSize = min(40, subtitleFontSize + 2)
                            } label: {
                                Label("Larger (\(Int(subtitleFontSize))pt)",
                                      systemImage: "textformat.size.larger")
                            }
                            Divider()
                            Button("Remove Subtitle") { vm.clearExternalSubtitle() }
                        }
                    } label: {
                        Image(systemName: vm.selectedSubtitleTrack != nil
                              ? "captions.bubble.fill" : "captions.bubble")
                            .foregroundStyle(.white)
                    }.menuStyle(.button).buttonStyle(.plain)

                    if vm.hasExternalSubtitle {
                        fsBtn("textformat.size.smaller") { subtitleFontSize = max(12, subtitleFontSize - 2) }
                        fsBtn("textformat.size.larger")  { subtitleFontSize = min(40, subtitleFontSize + 2) }
                    }

                    if !vm.audioTracks.isEmpty {
                        Menu {
                            Section("Audio Track") {
                                ForEach(vm.audioTracks) { track in
                                    Button {
                                        vm.selectAudio(track)
                                    } label: {
                                        if vm.selectedAudioTrack?.id == track.id {
                                            Label(track.displayName, systemImage: "checkmark")
                                        } else { Text(track.displayName) }
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: "speaker.badge.waveform").foregroundStyle(.white)
                        }.menuStyle(.button).buttonStyle(.plain)
                    }

                    fsBtn("arrow.down.forward.and.arrow.up.backward") { onDismiss() }
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 18)
            .background(LinearGradient(
                colors: [.clear, .black.opacity(0.85)],
                startPoint: .top, endPoint: .bottom
            ))
        }
    }

    @ViewBuilder
    private func fsBtn(_ name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

// MARK: - ExternalPlayerButtons

struct ExternalPlayerButtons: View {
    let item: MediaItem
    let vm: VideoPlayerViewModel

    private var iinaInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.colliderli.iina") != nil
    }
    private var vlcInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "org.videolan.vlc") != nil
    }

    var body: some View {
        VStack(spacing: 12) {
            if iinaInstalled || vlcInstalled {
                Text("Open with:").font(.caption).foregroundStyle(.white.opacity(0.6))
                HStack(spacing: 10) {
                    if iinaInstalled {
                        Button { openInIINA() } label: {
                            Label("IINA", systemImage: "play.rectangle.fill")
                        }.buttonStyle(.bordered).tint(.white)
                    }
                    if vlcInstalled {
                        Button { openInVLC() } label: {
                            Label("VLC", systemImage: "play.circle.fill")
                        }.buttonStyle(.bordered).tint(.orange)
                    }
                }
            } else {
                Button { NSWorkspace.shared.open(item.url) } label: {
                    Label("Open in Default App", systemImage: "arrow.up.forward.app")
                }.buttonStyle(.bordered).tint(.white)
                Text("Install IINA or VLC for MKV/AVI/WMV support (both free)")
                    .font(.caption).foregroundStyle(.white.opacity(0.5))
                    .multilineTextAlignment(.center).padding(.horizontal, 40)
                HStack(spacing: 10) {
                    Button("Get IINA") { NSWorkspace.shared.open(URL(string: "https://iina.io")!) }
                        .buttonStyle(.bordered).tint(.blue)
                    Button("Get VLC") { NSWorkspace.shared.open(URL(string: "https://videolan.org/vlc")!) }
                        .buttonStyle(.bordered).tint(.orange)
                }
            }
        }
    }

    private func openInIINA() {
        let encoded = item.url.absoluteString
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let url = URL(string: "iina://weblink?url=\(encoded)") {
            NSWorkspace.shared.open(url)
        }
    }
    private func openInVLC() {
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "org.videolan.vlc") {
            NSWorkspace.shared.open([item.url], withApplicationAt: app,
                                    configuration: NSWorkspace.OpenConfiguration())
        }
    }
}

// MARK: - AudioPickerSheet

struct AudioPickerSheet: View {
    let streams: [AudioStreamInfo]
    let onSelect: (Int) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Select Audio Track")
                        .font(.headline)
                    Text("Choose which audio to play")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.title3)
                }
                .buttonStyle(.plain)
            }
            .padding(20)

            Divider()

            // Track list
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(streams) { stream in
                        Button {
                            onSelect(stream.id)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "speaker.wave.2.fill")
                                    .foregroundStyle(.blue)
                                    .frame(width: 24)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(stream.title)
                                        .font(.body)
                                        .foregroundStyle(.primary)
                                    Text(stream.codec)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                if stream.isDefault {
                                    Text("Default")
                                        .font(.caption)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Color.blue.opacity(0.15))
                                        .foregroundStyle(.blue)
                                        .clipShape(Capsule())
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(Color.secondary.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding(.horizontal, 12)
                    }
                }
                .padding(.vertical, 12)
            }

            Divider()

            // Play with default button
            Button {
                let defaultIdx = streams.firstIndex(where: { $0.isDefault }) ?? 0
                onSelect(defaultIdx)
                dismiss()
            } label: {
                Text("Play with Default Audio")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(16)
        }
        .frame(width: 360, height: min(CGFloat(streams.count) * 64 + 180, 500))
    }
}
