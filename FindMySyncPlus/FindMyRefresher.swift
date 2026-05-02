import AppKit

@MainActor
enum FindMyRefresher {
    static let bundleID = "com.apple.findmy"

    private static var didRequestLaunchThisSession = false

    static func ensureRunningOnce(
        logger: LogStore,
        enabled: Bool,
        waitSeconds: TimeInterval = 2
    ) async {
        guard enabled else { return }

        if !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
            didRequestLaunchThisSession = true
            logger.debug("Find My is already running; leaving it open.")
            return
        }

        guard !didRequestLaunchThisSession else {
            logger.debug("Find My launch already requested this session; not launching again.")
            return
        }

        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            logger.warn("Find My app not found")
            return
        }

        do {
            _ = try await openApplicationAsync(at: url)
            didRequestLaunchThisSession = true
            logger.info("Find My launched hidden and will be left running.")
        } catch {
            logger.warn("Launch Find My failed: \(error.localizedDescription)")
            return
        }

        do {
            let safe = max(0, min(waitSeconds, 10))
            if safe > 0 {
                try await Task.sleep(for: .seconds(Double(safe)))
            }
        } catch {
            // Ignore cancellation.
        }
    }

    static func refreshBlocking(
        logger: LogStore,
        enabled: Bool,
        waitSeconds: TimeInterval = 2
    ) async {
        await ensureRunningOnce(
            logger: logger,
            enabled: enabled,
            waitSeconds: waitSeconds
        )
    }

    private static func openApplicationAsync(at url: URL) async throws -> NSRunningApplication {
        let config = NSWorkspace.OpenConfiguration()
        config.hides = true
        config.activates = false

        return try await withCheckedThrowingContinuation { cont in
            NSWorkspace.shared.openApplication(at: url, configuration: config) { app, error in
                if let error {
                    cont.resume(throwing: error)
                    return
                }

                if let app {
                    cont.resume(returning: app)
                    return
                }

                if let running = NSRunningApplication
                    .runningApplications(withBundleIdentifier: bundleID)
                    .first {
                    cont.resume(returning: running)
                    return
                }

                cont.resume(throwing: NSError(
                    domain: "FindMyRefresher",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Find My launch returned no running application"
                    ]
                ))
            }
        }
    }
}
