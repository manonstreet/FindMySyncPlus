import XCTest
@testable import FindMySyncPlus

final class KeychainIsolationTests: XCTestCase {

    func testProductionProcessUsesTheBundleService() {
        XCTAssertEqual(
            Keychain.serviceName(
                bundleIdentifier: "com.manonstreet.FindMySyncPlus",
                environment: [:],
                processIdentifier: 42),
            "com.manonstreet.FindMySyncPlus")
    }

    func testHostedTestUsesAPerProcessService() {
        XCTAssertEqual(
            Keychain.serviceName(
                bundleIdentifier: "com.manonstreet.FindMySyncPlus",
                environment: ["XCTestConfigurationFilePath": "/tmp/session.xctestconfiguration"],
                processIdentifier: 42),
            "com.manonstreet.FindMySyncPlus.xctest.42")
    }

    func testTestProcessesDoNotShareAKeychainNamespace() {
        let environment = ["XCTestConfigurationFilePath": "/tmp/session.xctestconfiguration"]
        XCTAssertNotEqual(
            Keychain.serviceName(
                bundleIdentifier: "com.manonstreet.FindMySyncPlus",
                environment: environment,
                processIdentifier: 41),
            Keychain.serviceName(
                bundleIdentifier: "com.manonstreet.FindMySyncPlus",
                environment: environment,
                processIdentifier: 42))
    }
}
