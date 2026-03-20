import SwiftUI
import CoreLocation

// MARK: - PhotoViewerView

struct PhotoViewerView: View {
    let item: MediaItem
    @State var vm: PhotoViewerViewModel
    let allItems: [MediaItem]
    let onNavigate: (MediaItem) -> Void

    @State private var showInspector = false
    @State private var showNavArrows = false
    // Track index internally so navigation works without view recreation
    @State private var currentIndex: Int = 0

    private var hasPrevious: Bool { currentIndex > 0 }
    private var hasNext: Bool     { currentIndex < allItems.count - 1 }

    private func navigateTo(index: Int) {
        guard index >= 0, index < allItems.count else { return }
        currentIndex = index
        let target = allItems[index]
        Task { await vm.load(url: target.url) }
        onNavigate(target)
    }

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                Color.black

                ZoomPanView(vm: vm)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if case .loading = vm.playerState {
                    ProgressView().tint(.white)
                }

                if case .error(let msg) = vm.playerState {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle).foregroundStyle(.secondary)
                        Text(msg).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                }

                // Left arrow
                if hasPrevious && showNavArrows {
                    HStack {
                        NavArrowButton(direction: .left) {
                            navigateTo(index: currentIndex - 1)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .transition(.opacity)
                }

                // Right arrow
                if hasNext && showNavArrows {
                    HStack {
                        Spacer()
                        NavArrowButton(direction: .right) {
                            navigateTo(index: currentIndex + 1)
                        }
                    }
                    .padding(.horizontal, 12)
                    .transition(.opacity)
                }

                // Counter badge
                if allItems.count > 1 {
                    VStack {
                        HStack {
                            Spacer()
                            Text("\(currentIndex + 1) / \(allItems.count)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.black.opacity(0.5))
                                .clipShape(Capsule())
                                .padding(12)
                        }
                        Spacer()
                    }
                }
            }
            .onHover { showNavArrows = $0 }
            .onWindowKeyPress(id: "photoviewer") { event in
                switch event.keyCode {
                case 123: // ←
                    if hasPrevious { navigateTo(index: currentIndex - 1) }
                    return hasPrevious
                case 124: // →
                    if hasNext { navigateTo(index: currentIndex + 1) }
                    return hasNext
                default:
                    return false
                }
            }
            .onAppear {
                // Seed the initial index from the incoming item
                currentIndex = allItems.firstIndex(where: { $0.id == item.id }) ?? 0
            }

            if showInspector {
                Divider()
                InspectorPanel(item: item, exif: vm.exif)
                    .frame(width: 260)
                    .transition(.move(edge: .trailing))
            }
        }
        .background(Color.black)
        .toolbar { photoToolbar }
        .onChange(of: item.id) { _, _ in
            Task { await vm.load(url: item.url) }
        }
    }

    @ToolbarContentBuilder
    var photoToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { vm.zoomOut() } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .help("Zoom Out  ⌘-")
            .keyboardShortcut("-", modifiers: .command)

            Button { vm.fitToScreen() } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .help("Fit to Screen  ⌘0")
            .keyboardShortcut("0", modifiers: .command)

            Button { vm.zoomTo100() } label: {
                Image(systemName: "1.magnifyingglass")
            }
            .help("Actual Size  ⌘1")
            .keyboardShortcut("1", modifiers: .command)

            Button { vm.zoomIn() } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .help("Zoom In  ⌘+")
            .keyboardShortcut("=", modifiers: .command)

            Divider()

            // Fullscreen — opens dedicated fullscreen panel, not window fullscreen
            Button {
                guard let img = vm.image else { return }
                FullscreenWindowManager.shared.present {
                    FullscreenPhotoView(
                        image: img,
                        allItems: allItems,
                        startIndex: currentIndex,
                        onIndexChange: { newIndex in
                            navigateTo(index: newIndex)
                        }
                    )
                }
            } label: {
                Image(systemName: "arrow.up.backward.and.arrow.down.forward.square")
            }
            .help("Fullscreen  F")
            .keyboardShortcut("f", modifiers: [])

            // Inspector
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showInspector.toggle() }
            } label: {
                Image(systemName: "sidebar.right")
            }
            .help("Show Inspector  ⌘I")
            .keyboardShortcut("i", modifiers: .command)
        }
    }
}

// MARK: - NavArrowButton

struct NavArrowButton: View {
    enum Direction { case left, right }
    let direction: Direction
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: direction == .left
                  ? "chevron.left.circle.fill"
                  : "chevron.right.circle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.white.opacity(0.85))
                .background(Circle().fill(.black.opacity(0.3)))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - ZoomPanView

struct ZoomPanView: View {
    @Bindable var vm: PhotoViewerViewModel

    @State private var lastScale:  CGFloat = 1.0
    @State private var lastOffset: CGSize  = .zero
    @State private var geometrySize: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            Group {
                if let img = vm.image {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .scaleEffect(vm.scale)
                        .offset(vm.offset)
                        .gesture(panGesture)
                        .gesture(magnifyGesture)
                        .onTapGesture(count: 2) { handleDoubleTap() }
                } else if case .loading = vm.playerState {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if case .error(let msg) = vm.playerState {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle).foregroundStyle(.secondary)
                        Text(msg).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .onAppear { geometrySize = geo.size }
            .onChange(of: geo.size) { _, new in geometrySize = new }
        }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { val in
                let delta  = val.magnification / lastScale
                lastScale  = val.magnification
                vm.scale   = (vm.scale * delta).clamped(to: 0.05...20)
            }
            .onEnded { _ in lastScale = 1.0; clampOffset() }
    }

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { val in
                vm.offset = CGSize(
                    width:  lastOffset.width  + val.translation.width,
                    height: lastOffset.height + val.translation.height
                )
            }
            .onEnded { _ in clampOffset(); lastOffset = vm.offset }
    }

    private func handleDoubleTap() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            if vm.scale > 1.01 { vm.fitToScreen(); lastOffset = .zero }
            else               { vm.scale = 2.5 }
        }
    }

    private func clampOffset() {
        guard let img = vm.image else { return }
        let imgW = img.size.width  * vm.scale
        let imgH = img.size.height * vm.scale
        let maxX = max(0, (imgW - geometrySize.width)  / 2)
        let maxY = max(0, (imgH - geometrySize.height) / 2)
        withAnimation(.easeOut(duration: 0.15)) {
            vm.offset = CGSize(
                width:  vm.offset.width.clamped(to:  -maxX...maxX),
                height: vm.offset.height.clamped(to: -maxY...maxY)
            )
        }
        lastOffset = vm.offset
    }
}

// MARK: - InspectorPanel

struct InspectorPanel: View {
    let item: MediaItem
    let exif: EXIFData?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                InspectorSection("File") {
                    InfoRow("Name",     item.fileName)
                    InfoRow("Type",     item.fileExtension.uppercased())
                    InfoRow("Size",     ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file))
                    if let w = item.width, let h = item.height {
                        InfoRow("Dimensions", "\(w) × \(h)")
                    }
                    InfoRow("Added",    item.dateAdded.formatted(date: .abbreviated, time: .omitted))
                    InfoRow("Modified", item.dateModified.formatted(date: .abbreviated, time: .omitted))
                }

                if let e = exif {
                    InspectorSection("Camera") {
                        if let make  = e.make   { InfoRow("Make",  make)  }
                        if let model = e.model  { InfoRow("Model", model) }
                        if let lens  = e.lensModel { InfoRow("Lens", lens) }
                    }
                    InspectorSection("Exposure") {
                        if let f   = e.focalLength  { InfoRow("Focal Length", "\(Int(f))mm") }
                        if let a   = e.aperture     { InfoRow("Aperture", "ƒ/\(String(format: "%.1f", a))") }
                        if let s   = e.shutterSpeed { InfoRow("Shutter", s) }
                        if let iso = e.iso          { InfoRow("ISO", "\(iso)") }
                        if let ev  = e.exposureBias { InfoRow("Exp. Bias", "\(String(format: "%+.1f", ev)) EV") }
                        if let fl  = e.flash        { InfoRow("Flash", fl ? "On" : "Off") }
                    }
                    if e.dateTaken != nil || e.gpsCoordinate != nil {
                        InspectorSection("Date & Location") {
                            if let d = e.dateTaken {
                                InfoRow("Taken", d.formatted(date: .abbreviated, time: .shortened))
                            }
                            if let gps = e.gpsCoordinate {
                                InfoRow("Latitude",  String(format: "%.6f°", gps.latitude))
                                InfoRow("Longitude", String(format: "%.6f°", gps.longitude))
                            }
                        }
                    }
                }
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
    }
}

struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title   = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 16)
                .padding(.bottom, 4)
            content()
            Divider()
        }
    }
}

struct InfoRow: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 90, alignment: .trailing)
            Text(value)
                .font(.caption).foregroundStyle(.primary)
                .textSelection(.enabled)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
    }
}

// MARK: - FullscreenPhotoView

struct FullscreenPhotoView: View {
    let image: NSImage
    let allItems: [MediaItem]
    let startIndex: Int
    let onIndexChange: (Int) -> Void

    @State private var currentIndex: Int
    @State private var currentImage: NSImage
    @State private var scale:      CGFloat = 1.0
    @State private var offset:     CGSize  = .zero
    @State private var showChrome: Bool    = true

    init(image: NSImage, allItems: [MediaItem],
         startIndex: Int, onIndexChange: @escaping (Int) -> Void) {
        self.image         = image
        self.allItems      = allItems
        self.startIndex    = startIndex
        self.onIndexChange = onIndexChange
        _currentIndex = State(initialValue: startIndex)
        _currentImage = State(initialValue: image)
    }

    private var hasPrevious: Bool { currentIndex > 0 }
    private var hasNext:     Bool { currentIndex < allItems.count - 1 }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Image — pan + pinch only, no tap gesture so buttons work
            Image(nsImage: currentImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .scaleEffect(scale)
                .offset(offset)
                .gesture(MagnifyGesture()
                    .onChanged { scale = $0.magnification.clamped(to: 0.1...10) }
                )
                .simultaneousGesture(DragGesture(minimumDistance: 5)
                    .onChanged { offset = $0.translation }
                )

            // Chrome layer — buttons on top, completely separate from image
            if showChrome {
                FsChrome(
                    currentIndex: currentIndex,
                    total: allItems.count,
                    hasPrevious: hasPrevious,
                    hasNext: hasNext,
                    onPrevious: { navigate(by: -1) },
                    onNext:     { navigate(by:  1) },
                    onClose:    { FullscreenWindowManager.shared.dismiss() }
                )
            }
        }
        .onHover { showChrome = $0 }
        .onWindowKeyPress(id: "fullscreen-photo-nav") { event in
            switch event.keyCode {
            case 123: navigate(by: -1); return true
            case 124: navigate(by:  1); return true
            case 53:  FullscreenWindowManager.shared.dismiss(); return true
            default:  return false
            }
        }
    }

    private func navigate(by delta: Int) {
        let next = currentIndex + delta
        guard next >= 0, next < allItems.count else { return }
        currentIndex = next
        scale  = 1.0
        offset = .zero
        onIndexChange(next)
        let url = allItems[next].url
        Task {
            if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
               let cg  = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                await MainActor.run {
                    currentImage = NSImage(cgImage: cg, size: .zero)
                }
            }
        }
    }
}

// MARK: - FsChrome
// Separate NSViewRepresentable so it sits in its own NSView layer,
// fully above the image view — AppKit hit-testing works correctly.

struct FsChrome: NSViewRepresentable {
    let currentIndex: Int
    let total:        Int
    let hasPrevious:  Bool
    let hasNext:      Bool
    let onPrevious:   () -> Void
    let onNext:       () -> Void
    let onClose:      () -> Void

    func makeNSView(context: Context) -> FsChromeView {
        FsChromeView(
            currentIndex: currentIndex, total: total,
            hasPrevious: hasPrevious, hasNext: hasNext,
            onPrevious: onPrevious, onNext: onNext, onClose: onClose
        )
    }

    func updateNSView(_ nsView: FsChromeView, context: Context) {
        nsView.update(
            currentIndex: currentIndex, total: total,
            hasPrevious: hasPrevious, hasNext: hasNext,
            onPrevious: onPrevious, onNext: onNext, onClose: onClose
        )
    }
}

// Pure AppKit view — no SwiftUI gesture conflicts
final class FsChromeView: NSView {
    private var onPrevious: () -> Void = {}
    private var onNext:     () -> Void = {}
    private var onClose:    () -> Void = {}
    private var hasPrevious = false
    private var hasNext     = false
    private var currentIndex = 0
    private var total        = 0

    private let prevBtn  = NSButton()
    private let nextBtn  = NSButton()
    private let closeBtn = NSButton()
    private let label    = NSTextField(labelWithString: "")
    private let hint     = NSTextField(labelWithString: "← → navigate  ·  Esc to close")

    init(currentIndex: Int, total: Int,
         hasPrevious: Bool, hasNext: Bool,
         onPrevious: @escaping () -> Void,
         onNext: @escaping () -> Void,
         onClose: @escaping () -> Void) {
        super.init(frame: .zero)
        self.onPrevious   = onPrevious
        self.onNext       = onNext
        self.onClose      = onClose
        self.hasPrevious  = hasPrevious
        self.hasNext      = hasNext
        self.currentIndex = currentIndex
        self.total        = total
        setup()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(currentIndex: Int, total: Int,
                hasPrevious: Bool, hasNext: Bool,
                onPrevious: @escaping () -> Void,
                onNext: @escaping () -> Void,
                onClose: @escaping () -> Void) {
        self.onPrevious   = onPrevious
        self.onNext       = onNext
        self.onClose      = onClose
        self.hasPrevious  = hasPrevious
        self.hasNext      = hasNext
        self.currentIndex = currentIndex
        self.total        = total
        refresh()
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        // Configure buttons
        for btn in [prevBtn, nextBtn, closeBtn] {
            btn.bezelStyle  = .circular
            btn.isBordered  = false
            btn.wantsLayer  = true
            btn.layer?.cornerRadius = 22
            btn.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
            addSubview(btn)
        }

        let cfg = NSImage.SymbolConfiguration(pointSize: 32, weight: .medium)
        prevBtn.image  = NSImage(systemSymbolName: "chevron.left",  accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        nextBtn.image  = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        closeBtn.image = NSImage(systemSymbolName: "xmark",         accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 18, weight: .medium))

        for btn in [prevBtn, nextBtn, closeBtn] {
            btn.contentTintColor = .white
        }

        prevBtn.target  = self; prevBtn.action  = #selector(didPrev)
        nextBtn.target  = self; nextBtn.action  = #selector(didNext)
        closeBtn.target = self; closeBtn.action = #selector(didClose)

        // Counter label
        label.textColor   = .white
        label.font        = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        label.alignment   = .center
        label.isBezeled   = false
        label.drawsBackground = false
        addSubview(label)

        // Hint
        hint.textColor    = NSColor.white.withAlphaComponent(0.35)
        hint.font         = NSFont.systemFont(ofSize: 12)
        hint.alignment    = .center
        hint.isBezeled    = false
        hint.drawsBackground = false
        addSubview(hint)
    }

    private func refresh() {
        prevBtn.isHidden  = !hasPrevious
        nextBtn.isHidden  = !hasNext
        label.stringValue = total > 1 ? "\(currentIndex + 1) / \(total)" : ""
        label.sizeToFit()
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        let h = bounds.height
        let btnSize: CGFloat = 52

        // Left arrow — vertically centred
        prevBtn.frame  = NSRect(x: 20, y: (h - btnSize) / 2, width: btnSize, height: btnSize)
        // Right arrow — vertically centred
        nextBtn.frame  = NSRect(x: w - 20 - btnSize, y: (h - btnSize) / 2, width: btnSize, height: btnSize)
        // Close — top left
        closeBtn.frame = NSRect(x: 20, y: h - 52 - 16, width: 40, height: 40)
        // Counter — top center
        label.sizeToFit()
        label.frame = NSRect(x: (w - label.frame.width) / 2,
                             y: h - label.frame.height - 20,
                             width: label.frame.width,
                             height: label.frame.height)
        // Hint — bottom center
        hint.sizeToFit()
        hint.frame = NSRect(x: (w - hint.frame.width) / 2,
                            y: 12,
                            width: hint.frame.width,
                            height: hint.frame.height)
    }

    @objc private func didPrev()  { onPrevious() }
    @objc private func didNext()  { onNext() }
    @objc private func didClose() { onClose() }
}
