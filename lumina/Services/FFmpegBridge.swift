import Foundation
import AVFoundation

// MARK: - TranscodeResult

enum TranscodeResult {
    case success(URL)
    case notNeeded
    case failed(String)
}

// MARK: - AudioStreamInfo

struct AudioStreamInfo: Identifiable {
    let id: Int          // stream index in source file
    let language: String
    let title: String
    let codec: String
    let isDefault: Bool
}

// MARK: - FFmpegBridge

@MainActor
final class FFmpegBridge {
    static let shared = FFmpegBridge()

    private let tempDir: URL
    private var activeProcess: Process?

    static let unsupportedExtensions: Set<String> = [
        "mkv", "avi", "wmv", "flv", "divx", "vob",
        "webm", "ogv", "asf", "rmvb", "rm", "m2ts"
    ]

    private init() {
        tempDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LuminaTranscode", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    // MARK: - Public API

    /// Synchronous path lookup for use from non-actor contexts (e.g. ThumbnailService)
    nonisolated var ffmpegPathSync: String? {
        let destURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lumina/bin/ffmpeg")
        if FileManager.default.isExecutableFile(atPath: destURL.path) { return destURL.path }
        return ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
            .first { FileManager.default.fileExists(atPath: $0) }
    }

    var ffmpegPath: String? {
        if let bundled = bundledBinaryPath { return bundled }
        return ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
            .first { FileManager.default.fileExists(atPath: $0) }
            ?? pathSearch("ffmpeg")
    }

    var isFFmpegInstalled: Bool { ffmpegPath != nil }

    /// Probe audio streams from a file — fast, just reads metadata
    func probeAudioStreams(url: URL) async -> [AudioStreamInfo] {
        guard let ffmpeg = ffmpegPath else { return [] }

        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpeg)
            // -i with no output just dumps stream info to stderr
            process.arguments = ["-i", url.path]
            process.standardOutput = FileHandle.nullDevice

            let pipe = Pipe()
            process.standardError = pipe

            process.terminationHandler = { _ in
                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                                   encoding: .utf8) ?? ""
                let streams = Self.parseAudioStreams(from: output)
                continuation.resume(returning: streams)
            }

            try? process.run()
        }
    }

    /// Prepare a file for playback with a specific audio stream index
    func prepare(url: URL, audioStreamIndex: Int = -1, knownDuration: TimeInterval = 0,
                 progress: @escaping (Double) -> Void) async -> TranscodeResult {
        let ext = url.pathExtension.lowercased()
        guard Self.unsupportedExtensions.contains(ext) else {
            let playable = await checkNativePlayback(url: url)
            return playable ? .notNeeded : await transcode(url: url, audioStreamIndex: audioStreamIndex,
                                                           knownDuration: knownDuration, progress: progress)
        }
        return await transcode(url: url, audioStreamIndex: audioStreamIndex,
                               knownDuration: knownDuration, progress: progress)
    }

    func cancel() {
        activeProcess?.terminate()
        activeProcess = nil
    }

    func clearCache() {
        try? FileManager.default.removeItem(at: tempDir)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    func cacheSizeString() -> String {
        ByteCountFormatter.string(fromByteCount: directorySize(tempDir), countStyle: .file)
    }

    // MARK: - Bundled binary

    private var bundledBinaryPath: String? {
        let arch = isAppleSilicon ? "arm64" : "x86_64"
        let binaryName = "ffmpeg_\(arch)"

        // Print("🔧 FFmpegBridge: arch=\(arch), looking for \(binaryName)")

        let destDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lumina/bin")
        let destURL = destDir.appendingPathComponent("ffmpeg")

        // Print("🔧 FFmpegBridge: destURL=\(destURL.path)")

        if FileManager.default.fileExists(atPath: destURL.path) {
            if FileManager.default.isExecutableFile(atPath: destURL.path) {
                // Print("🔧 FFmpegBridge: using cached binary")
                return destURL.path
            }
            try? FileManager.default.removeItem(at: destURL)
        }

        let bundleURL = Bundle.main.url(forResource: binaryName, withExtension: nil)
            ?? Bundle.main.url(forResource: binaryName, withExtension: nil, subdirectory: "ffmpeg")

        // Print("🔧 FFmpegBridge: bundleURL=\(bundleURL?.path ?? "NIL")")
        guard let bundleURL else { return nil }

        do {
            try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: bundleURL, to: destURL)
            // Print("🔧 FFmpegBridge: copied binary to \(destURL.path)")
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destURL.path)

            let sign = Process()
            sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            sign.arguments = ["--force", "--sign", "-", destURL.path]
            try? sign.run()
            sign.waitUntilExit()
            // Print("🔧 FFmpegBridge: codesign exit=\(sign.terminationStatus)")

            guard FileManager.default.isExecutableFile(atPath: destURL.path) else { return nil }
            // Print("🔧 FFmpegBridge: binary ready at \(destURL.path)")
            return destURL.path
        } catch {
            // Print("🔧 FFmpegBridge: error: \(error)")
            return nil
        }
    }

    private var isAppleSilicon: Bool {
        var sysinfo = utsname()
        uname(&sysinfo)
        let machine = withUnsafeBytes(of: &sysinfo.machine) {
            $0.bindMemory(to: CChar.self).baseAddress.map { String(cString: $0) } ?? ""
        }
        return machine.contains("arm64")
    }

    // MARK: - Transcode

    private func transcode(url: URL, audioStreamIndex: Int, knownDuration: TimeInterval,
                           progress: @escaping (Double) -> Void) async -> TranscodeResult {
        guard let ffmpeg = ffmpegPath else { return .failed("ffmpeg not found.") }
        guard FileManager.default.isExecutableFile(atPath: ffmpeg) else { return .failed("ffmpeg not executable.") }

        // Include audio index in cache key so different audio tracks get separate cache files
        let outputURL = tempURL(for: url, audioIndex: audioStreamIndex)

        // Print("🎬 FFmpegBridge: input=\(url.lastPathComponent) audioStream=\(audioStreamIndex)")
        // Print("🎬 FFmpegBridge: output=\(outputURL.lastPathComponent)")

        if FileManager.default.fileExists(atPath: outputURL.path),
           let srcMod = modDate(url), let destMod = modDate(outputURL), destMod > srcMod {
            // Print("🎬 FFmpegBridge: using cached file")
            return .success(outputURL)
        }
        try? FileManager.default.removeItem(at: outputURL)

        var duration = knownDuration
        if duration <= 0 { duration = await assetDuration(url: url) }

        // Stream copy — single selected audio track only
        let copyResult = await runStreamCopy(ffmpeg: ffmpeg, url: url, outputURL: outputURL,
                                             audioStreamIndex: audioStreamIndex)
        if case .success = copyResult { return copyResult }

        // Fallback: re-encode with hardware encoder
        // Print("🎬 FFmpegBridge: stream copy failed, falling back to re-encode")
        try? FileManager.default.removeItem(at: outputURL)
        return await runEncode(ffmpeg: ffmpeg, url: url, outputURL: outputURL,
                               audioStreamIndex: audioStreamIndex, duration: duration, progress: progress)
    }

    private func runStreamCopy(ffmpeg: String, url: URL, outputURL: URL,
                               audioStreamIndex: Int) async -> TranscodeResult {
        // First extract subtitles to a sidecar .srt file (works for ASS/SSA/SRT)
        // This is more reliable than embedding in the container
        await extractSubtitles(ffmpeg: ffmpeg, url: url, outputURL: outputURL)

        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpeg)

            let audioMap = audioStreamIndex >= 0 ? "0:a:\(audioStreamIndex)" : "0:a:0"
            process.arguments = [
                "-i", url.path,
                "-map", "0:v:0",
                "-map", audioMap,
                "-c:v", "copy",
                "-c:a", "copy",
                "-sn",              // no embedded subtitles — using sidecar .srt instead
                "-y", outputURL.path
            ]
            process.standardError  = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice

            process.terminationHandler = { proc in
                Task { @MainActor in
                    if proc.terminationStatus == 0, FileManager.default.fileExists(atPath: outputURL.path) {
                        // Print("🎬 FFmpegBridge: stream copy SUCCESS")
                        continuation.resume(returning: .success(outputURL))
                    } else {
                        // Print("🎬 FFmpegBridge: stream copy failed (\(proc.terminationStatus))")
                        continuation.resume(returning: .failed("stream copy failed"))
                    }
                }
            }

            do {
                try process.run()
                // Print("🎬 FFmpegBridge: stream copy PID=\(process.processIdentifier)")
                self.activeProcess = process
            } catch {
                continuation.resume(returning: .failed(error.localizedDescription))
            }
        }
    }

    /// Extract the first subtitle track to a sidecar .srt file next to the output
    private func extractSubtitles(ffmpeg: String, url: URL, outputURL: URL) async {
        let srtURL = outputURL.deletingPathExtension().appendingPathExtension("srt")
        if FileManager.default.fileExists(atPath: srtURL.path) { return }

        // First probe to get subtitle track name
        let trackName = await probeSubtitleName(ffmpeg: ffmpeg, url: url)

        // Name the SRT after the subtitle track name if available, else source filename
        let rawName = trackName ?? url.deletingPathExtension().lastPathComponent
        // Sanitize for use as filename — remove chars invalid on macOS
        let displayName = rawName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let namedSrtURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent(displayName)
            .appendingPathExtension("srt")

        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpeg)
            process.arguments = [
                "-i", url.path,
                "-map", "0:s:0",
                "-c:s", "srt",
                "-y", namedSrtURL.path
            ]
            process.standardError  = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice

            process.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    // Print("🎬 FFmpegBridge: subtitle extracted as '\(displayName).srt'")
                    // Also create hash-named symlink so sidecarSubtitleURL(for:) finds it
                    if namedSrtURL.path != srtURL.path {
                        try? FileManager.default.createSymbolicLink(at: srtURL, withDestinationURL: namedSrtURL)
                    }
                } else {
                    try? FileManager.default.removeItem(at: namedSrtURL)
                    // Print("🎬 FFmpegBridge: no extractable subtitles")
                }
                continuation.resume()
            }

            try? process.run()
        }
    }

    /// Probe the name/title of the first subtitle track
    private func probeSubtitleName(ffmpeg: String, url: URL) async -> String? {
        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpeg)
            process.arguments = ["-i", url.path]
            process.standardOutput = FileHandle.nullDevice

            let pipe = Pipe()
            process.standardError = pipe

            process.terminationHandler = { _ in
                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                                   encoding: .utf8) ?? ""
                // Parse subtitle stream lines and look for title metadata
                // ffmpeg output example:
                //   Stream #0:3(eng): Subtitle: subrip
                //     Metadata:
                //       title           : English
                let name = Self.parseSubtitleName(from: output)
                continuation.resume(returning: name)
            }

            try? process.run()
        }
    }

    /// Returns the properly-named SRT URL for a transcoded file if it exists.
    func sidecarSubtitleURL(for outputURL: URL, sourceURL: URL) -> URL? {
        let hashSrt = outputURL.deletingPathExtension().appendingPathExtension("srt")
        guard FileManager.default.fileExists(atPath: hashSrt.path) else { return nil }
        // hashSrt is a symlink pointing to the titled SRT — resolve it
        if let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: hashSrt.path) {
            return URL(fileURLWithPath: dest)
        }
        return hashSrt
    }

    nonisolated static func parseSubtitleName(from output: String) -> String? {
        let lines = output.components(separatedBy: "\n")
        var inSubtitleStream = false

        for line in lines {
            // Detect subtitle stream line
            if line.contains(": Subtitle:") {
                inSubtitleStream = true
                continue
            }
            // Once in subtitle stream, look for title metadata
            if inSubtitleStream {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.lowercased().hasPrefix("title") {
                    let parts = trimmed.components(separatedBy: ":")
                    if parts.count >= 2 {
                        let title = parts.dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
                        if !title.isEmpty { return title }
                    }
                }
                // Stop if we hit another stream
                if trimmed.hasPrefix("Stream #") { inSubtitleStream = false }
            }
        }

        // Fallback: try language code from subtitle stream
        let pattern = #"Stream #0:\d+\((\w+)\): Subtitle"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
           let range = Range(match.range(at: 1), in: output) {
            let lang = String(output[range])
            return Locale.current.localizedString(forLanguageCode: lang) ?? lang.uppercased()
        }

        return nil
    }

    private func runEncode(ffmpeg: String, url: URL, outputURL: URL,
                           audioStreamIndex: Int, duration: TimeInterval,
                           progress: @escaping (Double) -> Void) async -> TranscodeResult {
        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpeg)
            let audioMap = audioStreamIndex >= 0 ? "0:a:\(audioStreamIndex)" : "0:a:0"
            process.arguments = [
                "-i", url.path,
                "-map", "0:v:0",
                "-map", audioMap,
                "-c:v", "h264_videotoolbox", "-b:v", "8M",
                "-c:a", "aac", "-b:a", "192k",
                "-y", outputURL.path
            ]

            let pipe = Pipe()
            process.standardError  = pipe
            process.standardOutput = FileHandle.nullDevice

            var buffer = ""
            var parsedDur = duration

            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
                buffer += str
                if parsedDur <= 0, let d = parseDuration(from: buffer) { parsedDur = d }
                if parsedDur > 0, let pct = parseProgress(from: buffer, duration: parsedDur) {
                    Task { @MainActor in progress(pct) }
                }
                if buffer.count > 8192 { buffer = String(buffer.suffix(2048)) }
            }

            process.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                Task { @MainActor in
                    self.activeProcess = nil
                    if proc.terminationStatus == 0 {
                        continuation.resume(returning: .success(outputURL))
                    } else if proc.terminationReason == .uncaughtSignal {
                        try? FileManager.default.removeItem(at: outputURL)
                        continuation.resume(returning: .failed("Cancelled."))
                    } else {
                        continuation.resume(returning: .failed(
                            "Transcode failed (code \(proc.terminationStatus))."))
                    }
                }
            }

            do {
                try process.run()
                // Print("🎬 FFmpegBridge: encode launched PID=\(process.processIdentifier)")
                self.activeProcess = process
            } catch {
                continuation.resume(returning: .failed("Could not launch ffmpeg: \(error.localizedDescription)"))
            }
        }
    }

    // MARK: - Stream parsing

    nonisolated static func parseAudioStreams(from ffmpegOutput: String) -> [AudioStreamInfo] {
        var streams: [AudioStreamInfo] = []
        // Match lines like: Stream #0:1(tam): Audio: aac, 48000 Hz, ...
        let pattern = #"Stream #0:(\d+)(?:\((\w+)\))?: Audio: (\w+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        let lines = ffmpegOutput.components(separatedBy: "\n")
        var audioIndex = 0

        for line in lines {
            let range = NSRange(line.startIndex..., in: line)
            guard let match = regex.firstMatch(in: line, range: range) else { continue }

            let langCode = Range(match.range(at: 2), in: line).map { String(line[$0]) } ?? "und"
            let codec    = Range(match.range(at: 3), in: line).map { String(line[$0]) } ?? "?"

            // Get language name from code
            let langName = Locale.current.localizedString(forLanguageCode: langCode)
                ?? langCode.uppercased()

            // Extract title from metadata if present (line above usually has it)
            let isDefault = line.contains("(default)")

            // Extract channel info
            var title = langName
            if line.contains("5.1") { title += " 5.1" }
            else if line.contains("stereo") { title += " Stereo" }
            else if line.contains("7.1") { title += " 7.1" }

            streams.append(AudioStreamInfo(
                id: audioIndex,
                language: langCode,
                title: title,
                codec: codec.uppercased(),
                isDefault: isDefault
            ))
            audioIndex += 1
        }
        return streams
    }

    // MARK: - Helpers

    private func checkNativePlayback(url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.load(.tracks) else { return false }
        return !tracks.isEmpty
    }

    private func tempURL(for url: URL, audioIndex: Int) -> URL {
        let hash = String(url.path.hash).replacingOccurrences(of: "-", with: "n")
        let suffix = audioIndex >= 0 ? "_a\(audioIndex)" : "_a0"
        return tempDir.appendingPathComponent("\(hash)\(suffix).mov")
    }

    private func modDate(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private func assetDuration(url: URL) async -> Double {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return 0 }
        return duration.seconds
    }

    private func pathSearch(_ name: String) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        task.arguments = [name]
        let pipe = Pipe()
        task.standardOutput = pipe
        try? task.run()
        task.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return output?.isEmpty == false ? output : nil
    }

    private func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return enumerator.compactMap { $0 as? URL }
            .compactMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }
            .reduce(0) { $0 + Int64($1) }
    }
}

// MARK: - Parsers

private func parseDuration(from text: String) -> Double? {
    let pattern = #"Duration:\s*(\d{2}):(\d{2}):(\d{2})\.(\d{2})"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    else { return nil }
    func g(_ i: Int) -> Double {
        guard let r = Range(match.range(at: i), in: text) else { return 0 }
        return Double(text[r]) ?? 0
    }
    let s = g(1) * 3600 + g(2) * 60 + g(3) + g(4) / 100
    return s > 0 ? s : nil
}

private func parseProgress(from text: String, duration: Double) -> Double? {
    let pattern = #"time=(\d{2}):(\d{2}):(\d{2})\.(\d{2})"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).last
    else { return nil }
    func g(_ i: Int) -> Double {
        guard let r = Range(match.range(at: i), in: text) else { return 0 }
        return Double(text[r]) ?? 0
    }
    let s = g(1) * 3600 + g(2) * 60 + g(3) + g(4) / 100
    return min(0.99, s / duration)
}
