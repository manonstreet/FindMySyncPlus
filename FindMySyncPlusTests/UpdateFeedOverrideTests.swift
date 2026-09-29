import Testing
@testable import FindMySyncPlus

/// `SparkleUpdater.usableFeedOverride`: only an https feed replaces the one in Info.plist.
struct UpdateFeedOverrideTests {

    @Test func anHTTPSFeedIsUsed() {
        let staging = "https://manonstreet.github.io/FindMySyncPlus/appcast-staging.xml"
        #expect(SparkleUpdater.usableFeedOverride(staging) == staging)
    }

    @Test func anythingElseIsIgnored() {
        #expect(SparkleUpdater.usableFeedOverride("") == nil)
        #expect(SparkleUpdater.usableFeedOverride("http://example.com/appcast.xml") == nil)
        #expect(SparkleUpdater.usableFeedOverride("file:///tmp/appcast.xml") == nil)
        #expect(SparkleUpdater.usableFeedOverride("not a url") == nil)
    }
}
