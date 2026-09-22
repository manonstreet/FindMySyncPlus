import Testing
@testable import FindMySyncPlus

/// The version comparison behind the update check. Releases are tagged `v1.4.7b`, `v1.5b`,
/// `v1.6b`, so the numbers decide and the suffix letter, which every version carries, does
/// not. The awkward pair is `1.5b` against `1.4.7b`: the newer version has fewer components.
@Suite("Update version comparison")
struct UpdateCheckerTests {

    @Test("A later minor is newer")
    func laterMinor() {
        #expect(UpdateChecker.isNewer("v1.6b", than: "1.5b"))
        #expect(!UpdateChecker.isNewer("v1.5b", than: "1.6b"))
    }

    @Test("Fewer components can still be newer")
    func fewerComponentsCanBeNewer() {
        #expect(UpdateChecker.isNewer("v1.5b", than: "1.4.7b"))
        #expect(!UpdateChecker.isNewer("v1.4.7b", than: "1.5b"))
    }

    @Test("The running version is not an update")
    func sameVersion() {
        #expect(!UpdateChecker.isNewer("v1.5b", than: "1.5b"))
        #expect(!UpdateChecker.isNewer("1.5b", than: "1.5b"))
    }

    @Test("Patch numbers compare as numbers, not as text")
    func patchIsNumeric() {
        #expect(UpdateChecker.isNewer("v1.4.10b", than: "1.4.9b"))
        #expect(!UpdateChecker.isNewer("v1.4.9b", than: "1.4.10b"))
    }

    @Test("A trailing zero component is not an update")
    func trailingZero() {
        #expect(!UpdateChecker.isNewer("v1.5.0b", than: "1.5b"))
        #expect(!UpdateChecker.isNewer("v1.5b", than: "1.5.0b"))
    }

    @Test("A tag that cannot be read never claims an update")
    func unreadableTagIsNotNewer() {
        #expect(!UpdateChecker.isNewer("nightly", than: "1.5b"))
        #expect(!UpdateChecker.isNewer("", than: "1.5b"))
        #expect(!UpdateChecker.isNewer("v1.6b", than: ""))
    }

    @Test("The displayed version drops the tag's v")
    func displayDropsPrefix() {
        #expect(UpdateChecker.displayVersion("v1.6b") == "1.6b")
        #expect(UpdateChecker.displayVersion("1.6b") == "1.6b")
    }
}
