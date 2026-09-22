import AppKit

enum FindMyRefresher {
    static let bundleID = "com.apple.findmy"

    static func refreshBlocking(logger: LogStore, enabled: Bool, waitSeconds: TimeInterval = 10) async {
        guard enabled else { return }
        let secs = max(0, waitSeconds)
        logger.debug("Refreshing Find My caches by launching and killing the app (blocking \(Int(secs))s)")

        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            logger.warn("Find My app not found")
            return
        }

        do {
            _ = try await openApplicationAsync(at: url)
            logger.info("Find My launched hidden")
        } catch {
            logger.warn("Launch Find My failed: \(error.localizedDescription)")
            return
        }

        do {
            let safe = max(0, min(waitSeconds, 30))
            try await Task.sleep(for: .seconds(Double(safe)))
        } catch {
            // If the sleep is cancelled, just proceed to termination attempt.
        }

        await terminateAsync(logger: logger)
    }

    @discardableResult
    private static func terminate(logger: LogStore) -> Int {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        var terminated = 0
        for a in apps {
            if a.terminate() { terminated += 1 }
            if !a.isTerminated { a.forceTerminate() }
        }
        logger.info("Find My terminated (\(apps.count))")
        return terminated
    }

    private static func terminateAsync(logger: LogStore) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
                _ = terminate(logger: logger)
                cont.resume()
            }
        }
    }

    private static func openApplicationAsync(at url: URL) async throws -> NSRunningApplication {
        let config = NSWorkspace.OpenConfiguration()
        config.hides = true
        config.activates = false
        return try await withCheckedThrowingContinuation { cont in
            NSWorkspace.shared.openApplication(at: url, configuration: config) { app, error in
                if let error { cont.resume(throwing: error); return }
                // If the returned app is nil, we still proceed (we only need the side-effect of launch).
                cont.resume(returning: app ?? NSRunningApplication())
            }
        }
    }
}
