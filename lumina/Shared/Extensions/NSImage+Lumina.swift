import AppKit

extension NSImage {
    /// Returns a JPEG-compressed Data representation.
    func jpegData(compressionFactor: CGFloat = 0.85) -> Data? {
        guard let tiff = tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(
            using: .jpeg,
            properties: [.compressionFactor: compressionFactor]
        )
    }

    /// Resize to fit within maxSize preserving aspect ratio.
    func resized(to maxSize: CGSize) -> NSImage {
        let aspect = size.width / size.height
        var newSize: CGSize
        if size.width > size.height {
            newSize = CGSize(width: maxSize.width, height: maxSize.width / aspect)
        } else {
            newSize = CGSize(width: maxSize.height * aspect, height: maxSize.height)
        }
        let img = NSImage(size: newSize)
        img.lockFocus()
        draw(in: NSRect(origin: .zero, size: newSize),
             from: NSRect(origin: .zero, size: size),
             operation: .copy, fraction: 1.0)
        img.unlockFocus()
        return img
    }
}
