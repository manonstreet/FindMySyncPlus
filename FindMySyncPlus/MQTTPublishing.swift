import Foundation
import CocoaMQTT

/// The one thing `MQTTClient` needs from a broker connection. Narrow on purpose: a test
/// cannot construct a `CocoaMQTT` without a socket, and everything worth asserting about a
/// publish sequence is what goes on the wire, in what order.
///
/// Named `send` rather than `publish` because `CocoaMQTT.publish` returns `Int` and so
/// cannot satisfy a `Void` requirement directly.
@MainActor
protocol MQTTPublishing: AnyObject {
    func send(_ message: CocoaMQTTMessage)
}

extension CocoaMQTT: MQTTPublishing {
    func send(_ message: CocoaMQTTMessage) { _ = publish(message) }
}
