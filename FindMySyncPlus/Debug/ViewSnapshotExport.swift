import SwiftUI
import AppKit

/// Renders the app's screens to PNGs after a sync run, then quits. Inert unless
/// `demoRenderExport` is set, the same contract as `demoRoot` and `demoLogLevel`; not
/// `#if DEBUG`, because the demo session runs the installed release build. Nothing is
/// clicked — `ImageRenderer` draws offscreen. Unlike `ViewRenderTests`, what these screens
/// show is computed from the cache, so a change to parsing, grouping or backfill moves the
/// picture.
enum ViewSnapshotExport {

    /// Where to write. Absent means do nothing.
    /// Read by `substituting` as well, to keep the fallback branch unreachable without opt-in.
    static var outputDirectory: URL? {
        guard let path = UserDefaults.standard.string(forKey: "demoRenderExport"),
              !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Screens to render besides Tracking, comma-separated. Set by the driver for
    /// one case only: these screens show settings and status, not device data. Their
    /// AppKit-drawn controls (`.switch` toggles, steppers, `ToolTipOverlay`) render as a
    /// deterministic placeholder, so they never cause a false failure and everything around
    /// them is real.
    static var extraScreens: [String] {
        (UserDefaults.standard.string(forKey: "demoRenderScreens") ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Names this run in the manifest — the fixture shape, set by the driver.
    private static var label: String {
        UserDefaults.standard.string(forKey: "demoRenderLabel") ?? "unlabeled"
    }

    /// Renders are compared pixel by pixel, so everything except the code under test is
    /// pinned. Matches `ViewRenderTests`; the two must move together.
    private static let scale: CGFloat = 2
    /// Width is fixed; height follows the content. `AppVSplit` fixes its vertical size while
    /// rendering, which gives the stack a definite ideal height, so the image ends where the
    /// content does — nothing clipped, nothing overpainted.
    private static let renderWidth: CGFloat = 900

    private static let lightCanvas = Color(red: 1, green: 1, blue: 1)
    private static let darkCanvas  = Color(red: 0.12, green: 0.12, blue: 0.13)

    @MainActor private static var didExport = false

    /// True only while a render is in flight. `AppVSplit` and `AppScroll` read it to
    /// substitute a plain stack for a container `ImageRenderer` cannot draw.
    @MainActor private(set) static var isRendering = false

    /// How long to wait after the run before capturing. Not padding: the run's log lines
    /// are appended through `DispatchQueue.main.async` and are still queued when the run
    /// returns, so an immediate capture logged a run that stopped at pre-flight beside a
    /// fully rendered device list. The wait also lets MQTT publishes reach the broker.
    private static let settleSeconds: TimeInterval = 3

    /// Called when a run finishes. Renders once, then terminates so the demo session's
    /// restore trap fires.
    @MainActor
    static func exportIfRequested(app: AppModel, settings: SettingsStore, logger: LogStore) {
        guard outputDirectory != nil else { return }
        guard !didExport else { return }
        didExport = true
        logger.log(.info, "Snapshot export: run finished, settling \(Int(settleSeconds))s before capture")
        DispatchQueue.main.asyncAfter(deadline: .now() + settleSeconds) {
            MainActor.assumeIsolated { capture(app: app, settings: settings, logger: logger) }
        }
    }

    /// Records the Aliases list's shape while a snapshot is in flight, once per render.
    /// Headers and nesting exist only in the UI, so a case can assert every payload field and
    /// still not notice the list going flat. Returns `false` so it can sit in a `let _ =`
    /// inside a `ViewBuilder`.
    @MainActor
    @discardableResult
    static func notePartition(topLevel: Int, headers: [String], nested: Int,
                              logger: LogStore) -> Bool {
        guard isRendering, !notedPartition else { return false }
        notedPartition = true
        let names = headers.isEmpty ? "none" : headers.joined(separator: ", ")
        logger.log(.debug, "Aliases partition: \(topLevel) top-level, "
            + "\(headers.count) header(s) [\(names)], \(nested) nested")
        return false
    }

    @MainActor private static var notedPartition = false

    /// The other screens named by `demoRenderScreens`, once each in both appearances.
    @MainActor
    private static func renderExtraScreens(to dir: URL, app: AppModel,
                                           settings: SettingsStore, logger: LogStore) {
        let wanted = extraScreens
        guard !wanted.isEmpty else { return }

        // A checker of its own, never started, so About draws its resting state. The real
        // one's state depends on the network and on whatever GitHub tagged most recently,
        // which a baseline cannot hold still.
        let updates = SparkleUpdater()

        for name in wanted {
            let screen: AnyView
            switch name {
            case "HomeView":            screen = AnyView(HomeView())
            case "GeneralSettingsView": screen = AnyView(GeneralSettingsView())
            case "AccessSettingsView":  screen = AnyView(AccessSettingsView())
            case "AboutView":           screen = AnyView(AboutView())
            default:
                // Named but unknown: say so rather than skip in silence.
                logger.log(.warn, "Snapshot export: no screen called '\(name)'")
                continue
            }
            for (appearance, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
                let renderer = ImageRenderer(content: screen
                    .environmentObject(settings)
                    .environmentObject(app)
                    .environmentObject(logger)
                    .environmentObject(updates)
                    .frame(width: renderWidth)
                    .tint(.blue)
                    .background(scheme == .dark ? darkCanvas : lightCanvas)
                    .environment(\.colorScheme, scheme))
                renderer.scale = scale
                let file = "\(name)--\(appearance).png"
                guard let image = renderer.nsImage,
                      let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else {
                    logger.log(.error, "Snapshot export: \(file) produced no image")
                    continue
                }
                try? png.write(to: dir.appendingPathComponent(file))
                logger.log(.info, "Snapshot export: wrote \(file) "
                    + "(\(rep.pixelsWide)x\(rep.pixelsHigh))")
            }
        }
    }

    /// The exporter's own lines, which do not belong in the artifact: a user's copy never
    /// contains snapshot bookkeeping, and these carry the output path, which would make every
    /// baseline specific to the machine that wrote it.
    private static let exporterPrefix = "Snapshot export:"

    /// The run's log, in the Status window's Copy format. Byte-identical to the Copy button
    /// because both call `LogStore.plainText()`, so a headless run produces the artifact a
    /// reporter would paste — and a guard that fired silently is visible by its absence.
    @MainActor
    private static func writeLog(to dir: URL, logger: LogStore) {
        let text = logger.plainText()
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.contains(exporterPrefix) }
            .joined(separator: "\n")
        let file = "log--\(label).txt"
        do {
            try text.write(to: dir.appendingPathComponent(file), atomically: true, encoding: .utf8)
            logger.log(.info, "Snapshot export: wrote \(file) (\(text.count) chars)")
        } catch {
            logger.log(.error, "Snapshot export: cannot write \(file) — \(error.localizedDescription)")
        }
    }

    @MainActor
    private static func capture(app: AppModel, settings: SettingsStore, logger: LogStore) {
        guard let dir = outputDirectory else { return }

        logger.log(.info, "Snapshot export: rendering to \(dir.path) as '\(label)'")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            logger.log(.error, "Snapshot export: cannot create \(dir.path) — \(error.localizedDescription)")
            NSApplication.shared.terminate(nil)
            return
        }

        var entries: [[String: Any]] = []
        isRendering = true
        defer { isRendering = false }
        // Both disclosure states. Collapsed is what a user opens the window to; expanded is
        // where grouped children are visible at all, and that is the feature these fixtures
        // exist to exercise.
        let variants: [(name: String, expand: Bool)] = [("collapsed", false), ("expanded", true)]

        for variant in variants {
            notedPartition = false
            for (appearance, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
                let screen = TrackingView(expandAllGroups: variant.expand)
                    .environmentObject(settings)
                    .environmentObject(app)
                    .environmentObject(logger)
                    .frame(width: renderWidth)
                    .tint(.blue)                        // accentColor follows a system preference
                    .background(scheme == .dark ? darkCanvas : lightCanvas)
                    .environment(\.colorScheme, scheme) // LAST: a later modifier escapes this

                let renderer = ImageRenderer(content: screen)
                renderer.scale = scale
                let file = "TrackingView--\(label)--\(variant.name)--\(appearance).png"
                guard let image = renderer.nsImage,
                      let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else {
                    logger.log(.error, "Snapshot export: \(file) produced no image")
                    continue
                }
                do {
                    try png.write(to: dir.appendingPathComponent(file))
                    entries.append([
                        "file": file, "tier": "screen", "view": "TrackingView",
                        "fixture": label, "variant": variant.name, "appearance": appearance,
                        "size": [rep.pixelsWide, rep.pixelsHigh], "scale": scale,
                        "entries": app.lastLocatedEntries.count,
                        "aliases": settings.aliases.count
                    ])
                    logger.log(.info, "Snapshot export: wrote \(file) "
                        + "(\(rep.pixelsWide)x\(rep.pixelsHigh), \(app.lastLocatedEntries.count) entries)")
                } catch {
                    logger.log(.error, "Snapshot export: cannot write \(file) — \(error.localizedDescription)")
                }
            }
        }

        renderExtraScreens(to: dir, app: app, settings: settings, logger: logger)

        // One more hop before reading the log back: rendering itself logs, and `LogStore.log`
        // appends through `DispatchQueue.main.async`, so those lines are still queued when the
        // render loop returns.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                writeLog(to: dir, logger: logger)

                if let data = try? JSONSerialization.data(withJSONObject: entries,
                                                          options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: dir.appendingPathComponent("manifest-\(label).json"))
                }

                logger.log(.info, "Snapshot export: done, quitting")
                NSApplication.shared.terminate(nil)
            }
        }
    }
}
