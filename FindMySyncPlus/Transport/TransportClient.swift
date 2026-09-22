import Foundation

struct PostSummary: Sendable {
    let successCount: Int
    let authRejectedCount: Int
    let transientCount: Int
    /// Entities whose payload was identical to the one already on the broker, so
    /// nothing was published.
    ///
    /// Its own count rather than folded into any other: three separate reasons a
    /// device did not publish now coexist — no location, unassigned, and unchanged —
    /// and a single `skipped` would not say which. Always 0 while the setting is off,
    /// and always 0 for REST, which has no retained equivalent to skip against.
    let skippedUnchangedCount: Int

    init(successCount: Int,
         authRejectedCount: Int,
         transientCount: Int,
         skippedUnchangedCount: Int = 0) {
        self.successCount = successCount
        self.authRejectedCount = authRejectedCount
        self.transientCount = transientCount
        self.skippedUnchangedCount = skippedUnchangedCount
    }
}

@MainActor
protocol TransportClient {
    func post(_ devices: [DevicePoint],
              aliasByUUID: [String: String],
              settings: SettingsStore,
              logger: LogStore,
              dryRun: Bool) async -> PostSummary

    func ensureConnected(settings: SettingsStore) async -> Bool

    func testConnection(settings: SettingsStore) async -> (Bool, String)
}
