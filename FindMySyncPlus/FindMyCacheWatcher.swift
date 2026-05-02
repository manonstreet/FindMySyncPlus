import Foundation

@MainActor
final class FindMyCacheWatcher {
    private var sources: [DispatchSourceFileSystemObject] = []
    private var pendingRun: Task<Void, Never>?

    func start(logger: LogStore, onChange: @escaping @MainActor () -> Void) {
        stop()

        let files: [FMIPCacheFile] = [.devices, .items]
        let home = FileManager.default.homeDirectoryForCurrentUser

        for file in files {
            let url = home.appendingPathComponent(file.relativePath)
            let fd = open(url.path, O_EVTONLY)

            guard fd >= 0 else {
                logger.warn("Cache watcher could not open \(url.lastPathComponent)")
                continue
            }

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .extend, .attrib, .rename, .delete],
                queue: DispatchQueue.main
            )

            source.setEventHandler { [weak self] in
                guard let self else { return }
                self.debouncedRun(logger: logger, onChange: onChange)
            }

            source.setCancelHandler {
                close(fd)
            }

            source.resume()
            sources.append(source)

            logger.info("Watching Find My cache: \(url.lastPathComponent)")
        }
    }

    func stop() {
        pendingRun?.cancel()
        pendingRun = nil

        for source in sources {
            source.cancel()
        }

        sources.removeAll()
    }

    private func debouncedRun(
        logger: LogStore,
        onChange: @escaping @MainActor () -> Void
    ) {
        pendingRun?.cancel()

        pendingRun = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }

            logger.debug("Find My cache changed; triggering sync.")
            onChange()
        }
    }
}
