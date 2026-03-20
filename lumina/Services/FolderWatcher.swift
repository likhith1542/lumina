import Foundation

// MARK: - FolderWatcher

/// Watches one or more directories for filesystem changes using
/// DispatchSource (kernel-level, zero polling overhead).
final class FolderWatcher {
    static let shared = FolderWatcher()

    private var sources: [URL: DispatchSourceFileSystemObject] = [:]
    private let queue = DispatchQueue(label: "com.lumina.folderwatcher",
                                      qos: .utility)
    private var debounceTimers: [URL: DispatchWorkItem] = [:]
    private let debounceDelay: TimeInterval = 2.0

    var onChange: ((URL) -> Void)?

    private init() {}

    // MARK: - Watch / Unwatch

    func watch(_ url: URL) {
        guard sources[url] == nil else { return }

        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .link],
            queue: queue
        )

        source.setEventHandler { [weak self] in
            self?.scheduleDebounce(for: url)
        }

        source.setCancelHandler {
            close(fd)
        }

        sources[url] = source
        source.resume()
    }

    func unwatch(_ url: URL) {
        sources[url]?.cancel()
        sources.removeValue(forKey: url)
        debounceTimers[url]?.cancel()
        debounceTimers.removeValue(forKey: url)
    }

    func unwatchAll() {
        sources.keys.forEach { unwatch($0) }
    }

    // MARK: - Private

    private func scheduleDebounce(for url: URL) {
        debounceTimers[url]?.cancel()

        let item = DispatchWorkItem { [weak self] in
            DispatchQueue.main.async { self?.onChange?(url) }
        }
        debounceTimers[url] = item
        queue.asyncAfter(deadline: .now() + debounceDelay, execute: item)
    }
}
