import SwiftUI
import AppKit

/// Renders the app's screens to PNGs after a sync run, then quits.
///
/// Inert unless `demoRenderExport` is set, the same contract as `demoRoot`
/// (`CacheDecryptor.swift`) and `demoLogLevel` (`SettingsStore.swift`). It is deliberately
/// **not** `#if DEBUG`: the demo session runs the installed release build, so debug-only code
/// would not be there to fire.
///
/// Pointed at a fixture tree through `demoRoot`, this makes a run headless end to end —
/// generate a shape, launch, render, quit — with nothing driving the UI. Nothing is clicked;
/// `ImageRenderer` draws a view value offscreen, so no window is ever shown.
///
/// The screens rendered here differ from `ViewRenderTests` in the one way that matters: the
/// app computes what they show from the cache, so a change to parsing, grouping or backfill
/// moves the picture. A component render draws the values it was handed and cannot.
enum ViewSnapshotExport {

    /// Where to write. Absent means do nothing.
    static var outputDirectory: URL? {
        guard let path = UserDefaults.standard.string(forKey: "demoRenderExport"),
              !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Names this run in the manifest — the fixture shape, set by the driver.
    private static var label: String {
        UserDefaults.standard.string(forKey: "demoRenderLabel") ?? "unlabelled"
    }

    /// Renders are compared pixel by pixel, so everything except the code under test is
    /// pinned. Matches `ViewRenderTests`; the two must move together.
    private static let scale: CGFloat = 2
    /// Width is fixed; height follows the content.
    ///
    /// Two earlier attempts were wrong in opposite directions. A fixed 1200 clipped the
    /// *Aliases* section header off the bottom, so the two lists ran together and the render
    /// read as one undivided list. An unbounded height let `SectionCard`'s `GeometryReader`
    /// background expand and paint over the pane below, and the same header vanished under
    /// it — nothing looked broken, a section title simply was not there.
    ///
    /// `SnapshotSafeVSplit` fixes its vertical size while rendering, which gives the stack a
    /// definite ideal height. The image then ends where the content does: nothing clipped,
    /// nothing overpainted, and no acres of empty card.
    private static let renderWidth: CGFloat = 900

    private static let lightCanvas = Color(red: 1, green: 1, blue: 1)
    private static let darkCanvas  = Color(red: 0.12, green: 0.12, blue: 0.13)

    @MainActor private static var didExport = false

    /// True only while a render is in flight. `SnapshotSafeVSplit` and `SnapshotSafeScroll`
    /// read it to substitute a plain stack for a container `ImageRenderer` cannot draw.
    @MainActor private(set) static var isRendering = false

    /// Whether this render should show grouped children nested under their parent.
    ///
    /// Disclosure lives in `DeviceManagerView`'s `@State` and starts closed, so every screen
    /// render was fully collapsed — and grouped nesting, which is what issues #22 and #24
    /// were about, appeared in no baseline at all. The pieces were in the alias list and
    /// hidden behind a chevron nothing could open.
    ///
    /// Both states are rendered: collapsed is what a user opens the window to, expanded is
    /// where the feature is visible.
    @MainActor private(set) static var expandGroups = false

    /// Called when a run finishes. Renders once, then terminates so the demo session's
    /// restore trap fires.
    /// How long to wait after the run before capturing.
    ///
    /// **Not padding.** `resetAfterRun` is a `defer`, so it runs while the log lines the run
    /// produced are still queued: `LogStore.log` appends through `DispatchQueue.main.async`,
    /// and those blocks do not execute until the current work item yields. Capturing
    /// immediately produced a log that stopped at pre-flight and a broker that had seen zero
    /// publishes, while the renders showed a fully parsed device list — the state was right
    /// and the record of how it got there was missing.
    ///
    /// The wait also lets the run's MQTT publishes reach the broker before the app quits.
    private static let settleSeconds: TimeInterval = 3

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

    /// The run's log, in the Status window's Copy format.
    ///
    /// This is what closes the loop: fixtures control the input, the renders show what the UI
    /// made of it, and this shows what the engine said while doing it. Numbers a render cannot
    /// show — how many records were discovered, what was dropped and why, what was posted —
    /// are all here, and a guard that fired silently is visible by its absence.
    ///
    /// Byte-identical to the Copy button because both call `LogStore.plainText()`, so a
    /// headless run produces the same artifact a reporter would paste into an issue.
    /// Records the Aliases list's shape while a snapshot is in flight, once per render.
    ///
    /// Headers and nesting exist only in the UI. Without this a case can assert every field
    /// of every payload and still not notice the list going flat, which is exactly what
    /// issue #22 reported and what §6.1 was built to fix.
    ///
    /// Returns `false` so it can sit in a `let _ =` inside a `ViewBuilder`.
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

    /// The exporter's own lines, which do not belong in the artifact.
    ///
    /// The log is meant to be what the *run* produced — byte-identical to what a user would
    /// paste from the Copy button, and a user's copy never contains snapshot bookkeeping.
    /// These lines also carry the output path, which would make every baseline specific to
    /// the machine that wrote it.
    private static let exporterPrefix = "Snapshot export:"

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
        defer { isRendering = false; expandGroups = false }
        // Both disclosure states. Collapsed is what a user opens the window to; expanded is
        // where grouped children are visible at all, and that is the feature these fixtures
        // exist to exercise.
        let variants: [(name: String, expand: Bool)] = [("collapsed", false), ("expanded", true)]

        for variant in variants {
            expandGroups = variant.expand
            notedPartition = false
            for (appearance, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
                let screen = DeviceManagerView()
                    .environmentObject(settings)
                    .environmentObject(app)
                    .environmentObject(logger)
                    .frame(width: renderWidth)
                    .tint(.blue)                        // accentColor follows a system preference
                    .background(scheme == .dark ? darkCanvas : lightCanvas)
                    .environment(\.colorScheme, scheme) // LAST: a later modifier escapes this

                let renderer = ImageRenderer(content: screen)
                renderer.scale = scale
                let file = "DeviceManagerView--\(label)--\(variant.name)--\(appearance).png"
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
                        "file": file, "tier": "screen", "view": "DeviceManagerView",
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

        // One more hop before reading the log back.
        //
        // Rendering itself logs -- `notePartition` records the Aliases list's shape -- and
        // `LogStore.log` appends through `DispatchQueue.main.async`, so those lines are still
        // queued when the render loop returns. Reading the buffer here would miss exactly the
        // lines this render produced, which is the same mistake the settle before `capture`
        // already fixed once, one level further in.
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
