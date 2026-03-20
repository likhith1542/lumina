import SwiftUI

// MARK: - AudioPlayerView

struct AudioPlayerView: View {
    let playback: PlaybackState
    let item: MediaItem
    @State private var vm = AudioPlayerViewModel()
    @State private var showEQ = false

    var body: some View {
        VStack(spacing: 0) {
            if showEQ {
                EqualizerView(vm: vm)
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else {
                AlbumArtSection(art: vm.albumArt, spectrumData: vm.spectrumData)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            Divider()

            VStack(spacing: 16) {
                TrackInfoSection(vm: vm)
                AudioScrubSection(vm: vm)
                AudioControlsRow(vm: vm, playback: playback, showEQ: $showEQ)
            }
            .padding(20)
        }
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            vm.attach(playback: playback)
            Task { await vm.load(item: item) }
        }
        .onDisappear {
            vm.pause()
            KeyEventHandler.shared.unregister(id: "audioplayer")
        }
        .onChange(of: item.id) { _, _ in
            Task { await vm.load(item: item) }
        }
        .onWindowKeyPress(id: "audioplayer") { event in
            switch event.keyCode {
            case 49:  vm.togglePlay(); return true
            case 123: vm.skip(by: -10); return true
            case 124: vm.skip(by:  10); return true
            case 126: vm.setVolume(min(1, vm.volume + 0.1)); return true
            case 125: vm.setVolume(max(0, vm.volume - 0.1)); return true
            default:  return false
            }
        }
    }
}

// MARK: - AlbumArtSection

struct AlbumArtSection: View {
    let art: NSImage?
    let spectrumData: [Float]

    var body: some View {
        ZStack(alignment: .bottom) {
            if let art {
                Image(nsImage: art)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .frame(height: 220)
                    .clipped()
                    .overlay(alignment: .bottom) {
                        LinearGradient(
                            colors: [.clear, Color(NSColor.windowBackgroundColor)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 80)
                    }
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(height: 220)
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: 56))
                            .foregroundStyle(.tertiary)
                    }
            }

            SpectrumView(data: spectrumData)
                .frame(height: 40)
                .padding(.horizontal)
                .padding(.bottom, 8)
        }
    }
}

// MARK: - SpectrumView

struct SpectrumView: View {
    let data: [Float]

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(data.indices, id: \.self) { i in
                let v = data[i].isFinite ? data[i].clamped(to: 0...1) : 0
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor.opacity(0.7))
                    .frame(maxWidth: .infinity)
                    .frame(height: max(2, CGFloat(v) * 40))
            }
        }
        .animation(.easeInOut(duration: 0.1), value: data.map { v -> Int in
            let safe = v.isFinite ? v.clamped(to: 0...1) : 0
            return Int(safe * 100)
        })
    }
}

// MARK: - TrackInfoSection

struct TrackInfoSection: View {
    let vm: AudioPlayerViewModel

    var body: some View {
        VStack(spacing: 4) {
            Text(vm.trackTitle)
                .font(.headline)
                .lineLimit(1)
            Text(vm.artistName)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

// MARK: - AudioScrubSection

struct AudioScrubSection: View {
    let vm: AudioPlayerViewModel
    @State private var isScrubbing  = false
    @State private var scrubValue:  Double = 0

    private var displayValue: Double {
        guard vm.duration > 0 else { return 0 }
        return isScrubbing ? scrubValue : (vm.position / vm.duration)
    }

    var body: some View {
        VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { displayValue },
                    set: { val in
                        isScrubbing = true
                        scrubValue  = val
                    }
                )
            ) { editing in
                if !editing {
                    vm.seek(to: scrubValue * vm.duration)
                    isScrubbing = false
                }
            }

            HStack {
                Text(vm.position.formatted)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(vm.duration.formatted)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - AudioControlsRow

struct AudioControlsRow: View {
    let vm: AudioPlayerViewModel
    let playback: PlaybackState
    @Binding var showEQ: Bool

    var body: some View {
        HStack(spacing: 20) {
            // Shuffle
            Button {
                playback.isShuffle.toggle()
            } label: {
                Image(systemName: "shuffle")
                    .foregroundStyle(playback.isShuffle ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)

            // Previous
            Button {
                vm.playPrevious()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .disabled(!playback.hasPrevious)

            // Play / pause
            Button { vm.togglePlay() } label: {
                Image(systemName: vm.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 44))
            }
            .buttonStyle(.plain)

            // Next
            Button {
                vm.playNext()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .disabled(!playback.hasNext)

            // Loop
            Button {
                switch playback.loopMode {
                case .none: playback.loopMode = .all
                case .all:  playback.loopMode = .one
                case .one:  playback.loopMode = .none
                }
            } label: {
                Image(systemName: playback.loopMode.systemImage)
                    .foregroundStyle(playback.loopMode == .none ? Color.secondary : Color.accentColor)
            }
            .buttonStyle(.plain)

            Spacer()

            // Volume
            HStack(spacing: 6) {
                Image(systemName: "speaker.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: Binding(
                    get: { Double(vm.volume) },
                    set: { vm.setVolume(Float($0)) }
                ), in: 0...1)
                .frame(width: 80)
                Image(systemName: "speaker.wave.3.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // EQ toggle
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showEQ.toggle() }
            } label: {
                Image(systemName: showEQ ? "slider.vertical.3" : "slider.horizontal.3")
                    .foregroundStyle(showEQ ? Color.accentColor : Color.primary)
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - EqualizerView

struct EqualizerView: View {
    let vm: AudioPlayerViewModel
    private let sliderHeight: CGFloat = 100
    private let bandWidth:    CGFloat = 36

    var body: some View {
        VStack(spacing: 8) {
            Text("Equalizer")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(alignment: .center, spacing: 4) {
                ForEach(vm.eqBands) { band in
                    VStack(spacing: 6) {
                        Text(band.gain == 0 ? "0" : band.gain > 0 ? "+\(Int(band.gain))" : "\(Int(band.gain))")
                            .font(.system(size: 9).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: bandWidth)

                        Slider(
                            value: Binding(
                                get: { Double(band.gain) },
                                set: { vm.updateBand(id: band.id, gain: Float($0)) }
                            ),
                            in: -24...24
                        )
                        .frame(width: sliderHeight)
                        .rotationEffect(.degrees(-90))
                        .frame(width: bandWidth, height: sliderHeight)

                        Text(band.frequency >= 1000 ? "\(Int(band.frequency / 1000))k" : "\(Int(band.frequency))")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .frame(width: bandWidth)
                    }
                }
            }
            .padding(.horizontal, 8)

            Button("Reset") { vm.resetEQ() }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .frame(height: 220)
    }
}
