import Foundation
import CocoaMQTT

/// What `MQTTClient` needs from a broker connection: publishing, and the one subscription it
/// holds. Narrow on purpose: a test cannot construct a `CocoaMQTT` without a socket, and
/// everything worth asserting is what goes on the wire, in what order.
///
/// Named `send` rather than `publish` because `CocoaMQTT.publish` returns `Int` and so
/// cannot satisfy a `Void` requirement directly. The subscription pair carries labels because
/// `CocoaMQTT.subscribe(_:qos:)` has a defaulted parameter and could not witness an
/// unlabeled requirement.
@MainActor
protocol MQTTPublishing: AnyObject {
    func send(_ message: CocoaMQTTMessage)
    func subscribe(to topic: String)
    func unsubscribe(from topic: String)
}

extension CocoaMQTT: MQTTPublishing {
    func send(_ message: CocoaMQTTMessage) { _ = publish(message) }
    func subscribe(to topic: String) { subscribe(topic, qos: .qos1) }
    func unsubscribe(from topic: String) { unsubscribe(topic) }
}
