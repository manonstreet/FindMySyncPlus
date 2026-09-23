import Testing
import Foundation
@testable import FindMySyncPlus

/// `publishStatusEntity` had no direct test: its inputs came from the app model, the settings
/// and the logger, none of which a test may construct. The decision and the report are pure
/// now, and the publish takes the connection it writes to.
@Suite("The status entity, from a run to the wire")
@MainActor
struct StatusEntityTests {

    private static let prefix = "findmysyncplus/"

    /// Distinct numbers per source, so a sum that dropped one would show.
    private func metrics() -> RunMetrics {
        RunMetrics(discoveredDevices: 2, discoveredItems: 3, discoveredFriends: 4,
                   locatedDevices: 1, locatedItems: 2, locatedFriends: 3,
                   unassignedCount: 5, notTrackedCount: 1, toPostCount: 7, noLocationCount: 6)
    }

    private func run(startedAt: Date = Date(), dryRun: Bool = false,
                     findMyLaunched: Bool = true, cacheWritten: Date? = nil) -> SyncEngine.StatusRun {
        SyncEngine.StatusRun(startedAt: startedAt, metrics: metrics(),
                             postSummary: PostSummary(successCount: 4, authRejectedCount: 0,
                                                      transientCount: 1, skippedUnchangedCount: 2),
                             dryRun: dryRun, findMyLaunched: findMyLaunched,
                             cacheWritten: cacheWritten)
    }

    private func report(_ run: SyncEngine.StatusRun, now: Date = Date()) -> SyncStatusReport {
        let context = SyncEngine.StatusContext(version: "1.5b", sleptDuringRun: false,
                                               keys: "fmip valid, fmf valid, localstorage valid",
                                               fullDiskAccess: true, lastError: nil,
                                               newUnassigned: 3)
        return SyncEngine.statusReport(for: run, context: context, now: now)
    }

    // MARK: - Whether to publish

    /// A dry run publishes nothing, and a status entity claiming a sync had just happened
    /// would be the one thing it did publish.
    @Test("a dry run publishes no status")
    func dryRunPublishesNothing() {
        #expect(SyncEngine.publishesStatus(dryRun: true, transport: .mqtt) == false)
    }

    @Test("REST has no status entity")
    func restHasNone() {
        #expect(SyncEngine.publishesStatus(dryRun: false, transport: .rest) == false)
    }

    @Test("a live MQTT run publishes")
    func liveMQTTPublishes() {
        #expect(SyncEngine.publishesStatus(dryRun: false, transport: .mqtt))
    }

    // MARK: - The report

    @Test("discovered and located sum the three sources")
    func sums() {
        let report = report(run())
        #expect(report.discovered == 9)
        #expect(report.located == 6)
    }

    @Test("the counts come from the run, not from each other")
    func counts() {
        let report = report(run())
        #expect(report.tracked == 7)
        #expect(report.published == 4)
        #expect(report.skippedUnchanged == 2)
        #expect(report.noLocation == 6)
        #expect(report.unassigned == 5)
    }

    @Test("run_seconds is measured from the run's start")
    func runSeconds() {
        let now = Date()
        let report = report(run(startedAt: now.addingTimeInterval(-5)), now: now)
        #expect(report.runSeconds == 5)
    }

    @Test("the Find My and cache inputs pass through untouched")
    func passThrough() {
        let written = Date(timeIntervalSince1970: 1_700_000_000)
        let report = report(run(findMyLaunched: false, cacheWritten: written))
        #expect(report.findMyLaunched == false)
        #expect(report.cacheWritten == written)
        #expect(report.version == "1.5b")
        #expect(report.keys == "fmip valid, fmf valid, localstorage valid")
        #expect(report.fullDiskAccess)
        #expect(report.lastError == nil)
    }

    // MARK: - The wire

    @Test("the state carries the last successful sync and the attributes follow, both retained")
    func stateThenAttributes() throws {
        let recorder = RecordingPublisher()
        let synced = Date(timeIntervalSince1970: 1_700_000_000)
        MQTTClient().publishStatus(client: recorder, report: report(run()),
                                   lastSuccessfulSync: synced, prefix: Self.prefix,
                                   iso: ISO8601DateFormatter())

        #expect(recorder.topics == ["findmysyncplus/status/state",
                                    "findmysyncplus/status/attributes"])
        for message in recorder.messages {
            #expect(message.retained, "the entity keeps its values while the app is away")
        }

        let state = try #require(recorder.messages.first)
        #expect(String(bytes: state.payload, encoding: .utf8) == "2023-11-14T22:13:20Z")

        let data = Data(try #require(recorder.messages.last).payload)
        let attributes = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(attributes["published"] as? Int == 4)
        #expect(attributes["version"] as? String == "1.5b")
    }

    /// Before the first successful sync there is no time to publish; the attributes still
    /// describe the run that just happened.
    @Test("with no successful sync yet, only the attributes are published")
    func attributesOnly() {
        let recorder = RecordingPublisher()
        MQTTClient().publishStatus(client: recorder, report: report(run()),
                                   lastSuccessfulSync: nil, prefix: Self.prefix,
                                   iso: ISO8601DateFormatter())
        #expect(recorder.topics == ["findmysyncplus/status/attributes"])
    }
}
