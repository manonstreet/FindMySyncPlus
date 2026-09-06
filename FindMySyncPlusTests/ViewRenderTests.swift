import XCTest
import SwiftUI
import AppKit
@testable import FindMySyncPlus

/// Renders the Device Manager's row views offscreen and compares them against stored
/// baselines.
///
/// These views take only values and closures, so they render without a `SettingsStore` —
/// which is the point. Constructing one in a test writes to the app's real defaults domain.
///
/// Baseline comparison is opt-in through `FMS_BASELINE_DIR`. Unset, the tests still assert
/// that every variant renders and that two renders of one variant are identical, so they are
/// worth running on their own. Set, each render is compared byte-for-byte against the file of
/// the same name, and a missing baseline is written rather than failed so a new variant can be
/// adopted in one run.
///
/// **Comparison is by pixel with a tolerance, not by bytes.** `ImageRenderer` is not
/// byte-deterministic for these views: repeated renders of the same value differ by a few
/// bytes, which is a handful of antialiased pixels changing PNG compression. A trivial view
/// renders identically, which is what made a first measurement say "use `cmp`" — the wrong
/// conclusion from too simple a subject.
class ViewRenderTests: XCTestCase {

    // MARK: - Harness

    private static let scale: CGFloat = 2
    private static let rowWidth: CGFloat = 560

    /// The canvas the row is drawn on.
    ///
    /// Explicit rather than `Color(nsColor: .controlBackgroundColor)` so a baseline does not
    /// move because macOS restyled a control background. Dynamic colors resolve correctly
    /// either way — see the note on modifier order in `pixels(_:scheme:)`.
    private static let lightCanvas = Color(red: 1, green: 1, blue: 1)
    private static let darkCanvas  = Color(red: 0.12, green: 0.12, blue: 0.13)

    /// Per-channel slack before a pixel counts as changed.
    ///
    /// **Measured, not chosen.** At tolerance 0 repeated renders of one value differ on up to
    /// 0.15% of pixels — antialiasing moving edge pixels by a shade. At tolerance 8 the
    /// difference is exactly 0.000000 across all twelve variant/appearance pairs.
    private static let channelTolerance = 8

    /// Changed-pixel count that separates a match from a difference. **A count, not a
    /// fraction.**
    ///
    /// A fraction gets less sensitive as the render grows, and screen renders are much larger
    /// than rows. It also missed a real change: a chevron flipping direction moves **131
    /// pixels**, which is 0.055% of a row — under a 0.1% threshold, so it passed silently.
    /// That is the failure this whole comparison exists to prevent.
    ///
    /// The measured floor at the tolerance above is exactly 0 pixels, so 16 is margin rather
    /// than headroom over observed noise. Matches `tools/view-baselines/compare`.
    private static let minPixels = 16

    /// Collected as renders happen and written once, so the index cannot disagree with the
    /// images it describes.
    private static var manifest: [[String: Any]] = []

    private var baselineDir: URL? {
        guard let p = ProcessInfo.processInfo.environment["FMS_BASELINE_DIR"], !p.isEmpty
        else { return nil }
        return URL(fileURLWithPath: p)
    }

    /// Raw pixels, so two renders can be compared without PNG encoding in the way.
    ///
    /// **The appearance must be set on AppKit, not only on the SwiftUI environment.**
    /// `\.colorScheme` styles SwiftUI's own content, but dynamic `NSColor`s resolve against
    /// `NSAppearance.current`. Setting only the environment renders dark text on a light
    /// background — white on white — and makes every render depend on the appearance of the
    /// machine that produced it, which is the opposite of a baseline.
    @MainActor
    private func pixels<V: View>(_ view: V, scheme: ColorScheme) throws -> NSBitmapImageRep {
        var rep: NSBitmapImageRep?
        var failure: String?

        // `.environment(\.colorScheme,)` goes LAST, outermost.
        //
        // A modifier applied after it sits outside that environment. With the background
        // applied last, the content resolved dark and the background stayed light -- white
        // text on a white card. Measured on this view: mean luminance 0.993 with the
        // background outermost against 0.162 with the environment outermost.
        //
        // Dynamic `NSColor`s inside a view are unaffected, because they are already within
        // the scope. `SectionCard` reads `.controlBackgroundColor` and renders correctly.
        let renderer = ImageRenderer(
            content: view
                .frame(width: Self.rowWidth)
                .tint(.blue)                       // accentColor follows a system preference
                .background(scheme == .dark ? Self.darkCanvas : Self.lightCanvas)
                .environment(\.colorScheme, scheme))
        renderer.scale = Self.scale
        if let image = renderer.nsImage,
           let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff) {
            rep = bitmap
        } else {
            failure = "ImageRenderer produced no image"
        }

        if let failure { XCTFail(failure) }
        return try XCTUnwrap(rep)
    }

    /// Count of pixels differing by more than `channelTolerance` on any channel.
    ///
    /// A size mismatch returns every pixel: a view that changed shape has not drifted, it has
    /// changed, and no smaller number describes that usefully.
    private func difference(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Int {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else {
            return a.pixelsWide * a.pixelsHigh
        }
        guard let pa = a.bitmapData, let pb = b.bitmapData else { return a.pixelsWide * a.pixelsHigh }
        let bytes = a.bytesPerRow * a.pixelsHigh
        let spp = max(1, a.samplesPerPixel)
        var differing = 0
        var index = 0
        while index < bytes {
            var pixelDiffers = false
            for channel in 0..<spp where index + channel < bytes {
                if abs(Int(pa[index + channel]) - Int(pb[index + channel])) > Self.channelTolerance {
                    pixelDiffers = true
                    break
                }
            }
            if pixelDiffers { differing += 1 }
            index += spp
        }
        return differing
    }

    private func png(_ rep: NSBitmapImageRep) throws -> Data {
        try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    /// Renders `view` in both appearances, measures render-to-render noise, and diffs
    /// against baselines.
    @MainActor
    private func verify<V: View>(_ view: V, _ variant: String,
                                 file: StaticString = #filePath, line: UInt = #line) throws {
        for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
            let rep = try pixels(view, scheme: scheme)
            XCTAssertGreaterThan(rep.pixelsWide, 0, "\(variant)--\(name) rendered empty",
                                 file: file, line: line)

            // The noise floor. A baseline is only meaningful if a rerun sits under the
            // threshold used to judge it.
            let noise = difference(rep, try pixels(view, scheme: scheme))
            XCTAssertLessThanOrEqual(noise, Self.minPixels,
                                     "\(variant)--\(name) render-to-render noise \(noise) px exceeds \(Self.minPixels)",
                                     file: file, line: line)

            guard let dir = baselineDir else { continue }
            Self.manifest.append([
                "file": "\(variant)--\(name).png",
                "tier": "component",
                "variant": variant,
                "appearance": name,
                "size": [rep.pixelsWide, rep.pixelsHigh],
                "scale": Self.scale,
                "channelTolerance": Self.channelTolerance,
                "minPixels": Self.minPixels
            ])
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("\(variant)--\(name).png")
            guard FileManager.default.fileExists(atPath: url.path),
                  let stored = NSBitmapImageRep(data: try Data(contentsOf: url)) else {
                try png(rep).write(to: url)
                print("baseline written: \(url.lastPathComponent)")
                continue
            }
            let drift = difference(rep, stored)
            if drift > Self.minPixels {
                let failed = dir.appendingPathComponent("\(variant)--\(name).failed.png")
                try png(rep).write(to: failed)
                XCTFail("\(variant)--\(name) differs from baseline by \(drift) px (limit \(Self.minPixels)) — wrote \(failed.lastPathComponent)",
                        file: file, line: line)
            }
        }
    }

    private func row(tracked: Bool = true,
                     uuids: [String] = ["A1B2C3D4-0000-0000-0000-000000000001"],
                     lastSeen: String? = "Test AirTag",
                     badge: DeviceSource? = .item,
                     name: String = "Test AirTag",
                     transport: TransportMode = .mqtt,
                     disclosure: (isCollapsed: Bool, onToggle: () -> Void)? = nil) -> AliasRowView {
        AliasRowView(aliasKey: "test-alias",
                     tracked: tracked,
                     knownUUIDs: uuids,
                     lastSeenName: lastSeen,
                     sourceBadge: badge,
                     nameLabel: name,
                     transportMode: transport,
                     disclosure: disclosure,
                     onToggleTracked: { _ in },
                     onRename: {},
                     onDelete: {},
                     onReRegister: {},
                     onDeleteUUID: { _ in })
    }

    // MARK: - AliasRowView

    @MainActor func testAliasRowTracked() throws {
        try verify(row(), "AliasRowView--tracked")
    }

    @MainActor func testAliasRowUntracked() throws {
        try verify(row(tracked: false), "AliasRowView--untracked")
    }

    /// The two disclosure states are the reason these views are worth rendering separately:
    /// they live in the parent's `@State`, so a whole-screen render only ever shows the default.
    @MainActor func testAliasRowGroupedCollapsed() throws {
        try verify(row(badge: .group, name: "Test AirPods",
                       disclosure: (isCollapsed: true, onToggle: {})),
                   "AliasRowView--grouped-collapsed")
    }

    @MainActor func testAliasRowGroupedExpanded() throws {
        try verify(row(badge: .group, name: "Test AirPods",
                       disclosure: (isCollapsed: false, onToggle: {})),
                   "AliasRowView--grouped-expanded")
    }

    @MainActor func testAliasRowManyUUIDs() throws {
        try verify(row(uuids: (1...4).map { "A1B2C3D4-0000-0000-0000-00000000000\($0)" }),
                   "AliasRowView--many-uuids")
    }

    @MainActor func testAliasRowRestTransport() throws {
        try verify(row(transport: .rest), "AliasRowView--rest")
    }

    /// A name long enough to force truncation. Layout breaks show here before anywhere else.
    @MainActor func testAliasRowLongName() throws {
        try verify(row(lastSeen: "A very long device name that will not fit on one line",
                       name: "A very long device name that will not fit on one line"),
                   "AliasRowView--long-name")
    }

    override class func tearDown() {
        defer { super.tearDown() }
        guard let p = ProcessInfo.processInfo.environment["FMS_BASELINE_DIR"], !p.isEmpty,
              !manifest.isEmpty,
              let data = try? JSONSerialization.data(
                withJSONObject: manifest.sorted { ($0["file"] as? String ?? "") < ($1["file"] as? String ?? "") },
                options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? data.write(to: URL(fileURLWithPath: p).appendingPathComponent("manifest.json"))
    }

    /// `SectionCard` reads `.controlBackgroundColor` and `.separatorColor`. It is covered
    /// here because those were once believed to block rendering, and do not.
    @MainActor func testSectionCardDynamicColors() throws {
        try verify(SectionCard(gutter: 0, innerTrailing: 0) {
            Text("Section content").font(.callout).padding(10)
        }, "SectionCard--dynamic-colors")
    }

    /// PNG storage must not change a pixel, or a baseline is not what it claims to be.
    @MainActor func testPNGRoundTripIsLossless() throws {
        let rendered = try pixels(row(badge: .group, name: "Test AirPods",
                                      disclosure: (isCollapsed: true, onToggle: {})),
                                  scheme: .dark)
        let encoded = try XCTUnwrap(rendered.representation(using: .png, properties: [:]))
        let decoded = try XCTUnwrap(NSBitmapImageRep(data: encoded))
        XCTAssertEqual(difference(rendered, decoded), 0,
                       "PNG round-trip altered pixels — baselines cannot be trusted")
    }

    // MARK: - The noise floor itself

    /// Measures render-to-render variation across every row variant and reports it.
    ///
    /// This is the measurement the whole comparison rests on: a threshold below the floor
    /// flags everything, which is indistinguishable from flagging nothing. Run with
    /// `-only-testing` and read the printed table when changing `threshold`.
    @MainActor func testNoiseFloorIsBelowThreshold() throws {
        let cases: [(String, AliasRowView)] = [
            ("tracked", row()),
            ("untracked", row(tracked: false)),
            ("grouped-collapsed", row(badge: .group, name: "Test AirPods",
                                      disclosure: (isCollapsed: true, onToggle: {}))),
            ("many-uuids", row(uuids: (1...4).map { "A1B2C3D4-0000-0000-0000-00000000000\($0)" })),
            ("rest", row(transport: .rest)),
            ("long-name", row(lastSeen: "A very long device name that will not fit on one line",
                                      name: "A very long device name that will not fit on one line"))
        ]
        var worst = 0
        var report = "variant            appearance  noise\n"
        for (label, view) in cases {
            for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
                // Three renders, so a floor that only shows intermittently is still seen.
                let a = try pixels(view, scheme: scheme)
                let b = try pixels(view, scheme: scheme)
                let c = try pixels(view, scheme: scheme)
                let d = max(difference(a, b), max(difference(b, c), difference(a, c)))
                worst = max(worst, d)
                report += String(format: "%-18@ %-11@ %d px\n", label as NSString, name as NSString, d)
            }
        }
        report += String(format: "\nWORST %d px   limit %d px\n", worst, Self.minPixels)
        print(report)
        // The floor belongs next to the baselines it justifies.
        if let dir = baselineDir {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? report.write(to: dir.appendingPathComponent("noise-report.txt"),
                              atomically: true, encoding: .utf8)
        }
        XCTAssertLessThanOrEqual(worst, Self.minPixels,
                                 "the measured floor has reached the limit, which makes every comparison meaningless")
    }

    // MARK: - Components

    @MainActor func testAliasGroupHeader() throws {
        try verify(AliasGroupHeader(name: "Test AirPods"), "AliasGroupHeader--default")
    }

    @MainActor func testAssignedBadge() throws {
        try verify(AssignedBadge(), "AssignedBadge--default")
    }
}
