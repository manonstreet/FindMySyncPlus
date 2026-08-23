import Foundation
import CocoaMQTT

/// The one thing `MQTTClient` needs from a broker connection.
///
/// Narrow on purpose. `MQTTClient` published straight to a concrete `CocoaMQTT`,
/// which a test cannot construct without a socket, so the publish sequences — the
/// tombstone drain and the clear-then-republish of a re-registration — had no
/// coverage and could only be checked by hand against a live broker. Everything
/// worth asserting about them is *what goes on the wire, in what order*, which
/// this makes an ordinary unit test.
///
/// Named `send` rather than `publish` because `CocoaMQTT.publish` returns `Int`
/// and so cannot satisfy a `Void` requirement directly.
@MainActor
protocol MQTTPublishing: AnyObject {
    func send(_ message: CocoaMQTTMessage)
}

extension CocoaMQTT: MQTTPublishing {
    func send(_ message: CocoaMQTTMessage) { _ = publish(message) }
}
