import Foundation

struct PostSummary: Sendable {
    let successCount: Int
    let authRejectedCount: Int
    let transientCount: Int
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
