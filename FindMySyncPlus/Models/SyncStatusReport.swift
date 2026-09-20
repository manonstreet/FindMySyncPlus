import Foundation

/// One run, as Home Assistant sees it.
///
/// Every field is state the app already holds and shows on screen. Availability says
/// whether the app is alive; these counts say what it did — without them, "nothing changed"
/// and "broken" look identical from Home Assistant.
struct SyncStatusReport {
    let version: String
    let runSeconds: Double
    let discovered: Int
    let located: Int
    let tracked: Int
    let published: Int
    let skippedUnchanged: Int
    let noLocation: Int
    let unassigned: Int
    let sleptDuringRun: Bool
    /// Whether this run relaunched Find My. The cache advances because we launch Find My, so
    /// "did the cache move" only means something beside "did we ask it to".
    let findMyLaunched: Bool
    /// When Apple last wrote the newest cache we read. Published raw, never as a freshness
    /// verdict: mtime says a write happened, not that a position arrived. Beside
    /// `find_my_launched` and `skipped_unchanged` it separates "asked, wrote, nothing new"
    /// from "asked, never wrote" from "never asked".
    let cacheWritten: Date?
    let keys: String
    let fullDiskAccess: Bool
    let lastError: String?

    /// The attribute payload, exactly as published. People template against these, so a
    /// rename after shipping is a breaking change. Three reasons a device did not publish
    /// coexist — `no_location`, `unassigned`, `skipped_unchanged` — and a single `skipped`
    /// would not say which. Per-device staleness stays on each device's own attributes.
    var attributes: [String: Any] {
        [
            "version": version,
            // Raw, like `gps_accuracy`; Foundation serializes inexact Doubles at full precision anyway.
            "run_seconds": runSeconds,
            "discovered": discovered,
            "located": located,
            "tracked": tracked,
            "published": published,
            "skipped_unchanged": skippedUnchanged,
            "no_location": noLocation,
            "unassigned": unassigned,
            // A run that overlapped a sleep looks broken and is not; this says why it took so long.
            "slept_during_run": sleptDuringRun,
            "find_my_launched": findMyLaunched,
            // Built here rather than held as a static: `ISO8601DateFormatter` is not
            // `Sendable`, and this runs once per sync.
            "cache_written": cacheWritten.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull(),
            "keys": keys,
            "full_disk_access": fullDiskAccess,
            // `NSNull` rather than an omitted key: an attribute that disappears when
            // things are healthy makes every template that reads it need a guard.
            "last_error": lastError ?? NSNull()
        ]
    }

    /// `fmip ok, fmf missing` — one line naming every key's state. Fixed order so the string
    /// is stable run to run; `fmf` and `localstorage` are reported even with Friends off,
    /// because "no key" and "switched off" are different answers.
    static func keysDescription(fmip: KeyStatus, fmf: KeyStatus, localStorage: KeyStatus) -> String {
        [("fmip", fmip), ("fmf", fmf), ("localstorage", localStorage)]
            .map { "\($0.0) \(describe($0.1))" }
            .joined(separator: ", ")
    }

    /// Deliberately four words, not two. `present` means a key is stored but has never
    /// decrypted anything, and reporting it as `ok` would send a user looking anywhere
    /// but at the key that is actually wrong.
    private static func describe(_ status: KeyStatus) -> String {
        switch status {
        case .notPresent: return "missing"
        case .present:    return "present"
        case .valid:      return "ok"
        case .invalid:    return "invalid"
        }
    }
}
