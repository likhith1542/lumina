import Foundation
import AVFoundation
import UniformTypeIdentifiers

// MARK: - URL + Lumina

extension URL {
    var mediaType: MediaType? { MediaType.detect(from: self) }

    var isMediaFile: Bool { mediaType != nil }

    var fileSize: Int64 {
        (try? resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map { Int64($0) } ?? 0
    }

    var contentModificationDate: Date? {
        (try? resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// Returns a UTType for registering with NSOpenPanel
    var utType: UTType? { UTType(filenameExtension: pathExtension.lowercased()) }
}

// MARK: - CMTime + Lumina

extension CMTime {
    var seconds: Double { CMTimeGetSeconds(self) }

    init(seconds: Double) {
        self = CMTime(seconds: seconds, preferredTimescale: 600)
    }

    var formatted: String {
        guard isValid, !isIndefinite else { return "--:--" }
        let total = Int(max(0, seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}

// MARK: - TimeInterval formatting

extension TimeInterval {
    var formatted: String {
        CMTime(seconds: self).formatted
    }
}

// MARK: - String SHA256

import CryptoKit

extension String {
    /// A stable short hash used as a deletion tombstone key.
    var sha256: String {
        let digest = SHA256.hash(data: Data(utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }
}
