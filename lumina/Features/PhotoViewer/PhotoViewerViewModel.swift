import AppKit
import ImageIO
import CoreLocation

// MARK: - EXIFData

struct EXIFData {
    var make:          String?
    var model:         String?
    var lensModel:     String?
    var focalLength:   Double?
    var aperture:      Double?
    var shutterSpeed:  String?
    var iso:           Int?
    var exposureBias:  Double?
    var flash:         Bool?
    var dateTaken:     Date?
    var gpsCoordinate: CLLocationCoordinate2D?
    var dpiX:          Double?
    var dpiY:          Double?
}

// MARK: - PhotoViewerViewModel

@Observable
final class PhotoViewerViewModel {
    var item:        MediaItem
    var image:       NSImage?   = nil
    var exif:        EXIFData?  = nil
    var playerState: PlayerState = .idle
    var errorMessage: String?   = nil
    var scale:       CGFloat    = 1.0
    var offset:      CGSize     = .zero

    private let repo = MediaItemRepository()

    init(item: MediaItem) {
        self.item = item
        try? repo.incrementPlayCount(id: item.id)   // track for Recently Played
        Task { await load(url: item.url) }
    }

    // MARK: - Load

    @MainActor
    func load(url: URL) async {
        playerState = .loading(url)
        image = nil

        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            playerState = .error("Cannot open: \(url.lastPathComponent)")
            return
        }

        let cgImage: CGImage? = await Task.detached(priority: .userInitiated) {
            let opts: [CFString: Any] = [
                kCGImageSourceShouldCacheImmediately:    true,
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            return CGImageSourceCreateImageAtIndex(src, 0, opts as CFDictionary)
        }.value

        guard let cg = cgImage else {
            playerState = .error("Failed to decode: \(url.lastPathComponent)")
            return
        }

        image       = NSImage(cgImage: cg, size: .zero)
        exif        = extractEXIF(from: src)
        playerState = .ready
        fitToScreen()
    }

    // MARK: - EXIF

    private func extractEXIF(from src: CGImageSource) -> EXIFData {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { return EXIFData() }

        var data     = EXIFData()
        let exifDict = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiffDict = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let gpsDict  = props[kCGImagePropertyGPSDictionary]  as? [CFString: Any] ?? [:]

        data.make        = tiffDict[kCGImagePropertyTIFFMake]  as? String
        data.model       = tiffDict[kCGImagePropertyTIFFModel] as? String
        data.lensModel   = exifDict[kCGImagePropertyExifLensModel]  as? String
        data.focalLength = exifDict[kCGImagePropertyExifFocalLength] as? Double
        data.aperture    = exifDict[kCGImagePropertyExifFNumber]      as? Double
        data.iso         = (exifDict[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first
        data.exposureBias = exifDict[kCGImagePropertyExifExposureBiasValue] as? Double

        if let ev = exifDict[kCGImagePropertyExifExposureTime] as? Double {
            data.shutterSpeed = ev < 1
                ? "1/\(Int(round(1 / ev)))s"
                : "\(String(format: "%.1f", ev))s"
        }

        if let flash = exifDict[kCGImagePropertyExifFlash] as? Int {
            data.flash = (flash & 0x1) != 0
        }

        if let dateStr = exifDict[kCGImagePropertyExifDateTimeOriginal] as? String {
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy:MM:dd HH:mm:ss"
            data.dateTaken = fmt.date(from: dateStr)
        }

        if let lat = gpsDict[kCGImagePropertyGPSLatitude]  as? Double,
           let lon = gpsDict[kCGImagePropertyGPSLongitude] as? Double {
            let latRef = gpsDict[kCGImagePropertyGPSLatitudeRef]  as? String ?? "N"
            let lonRef = gpsDict[kCGImagePropertyGPSLongitudeRef] as? String ?? "E"
            data.gpsCoordinate = CLLocationCoordinate2D(
                latitude:  latRef == "S" ? -lat : lat,
                longitude: lonRef == "W" ? -lon : lon
            )
        }

        data.dpiX = tiffDict[kCGImagePropertyTIFFXResolution] as? Double
        data.dpiY = tiffDict[kCGImagePropertyTIFFYResolution] as? Double

        return data
    }

    // MARK: - Zoom helpers

    func fitToScreen() { scale = 1.0; offset = .zero }
    func zoomTo100()   { scale = 1.0; offset = .zero }
    func zoomIn()      { scale = (scale * 1.25).clamped(to: 0.05...20) }
    func zoomOut()     { scale = (scale / 1.25).clamped(to: 0.05...20) }
}
