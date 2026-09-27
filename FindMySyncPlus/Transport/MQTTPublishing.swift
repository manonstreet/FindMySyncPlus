import Foundation
import CocoaMQTT

/// What `MQTTClient` needs from a broker connection: publishing, and the one subscription it
/// holds. Narrow on purpose: a test cannot construct a `CocoaMQTT` without a socket, and
/// everything worth asserting is what goes on the wire, in what order.
///
/// Named `send` rather than `publish` because `CocoaMQTT.publish` returns an `Int` message id
/// and so cannot satisfy a `Bool` requirement directly. The subscription pair carries labels
/// because `CocoaMQTT.subscribe(_:qos:)` has a defaulted parameter and could not witness an
/// unlabeled requirement.
@MainActor
protocol MQTTPublishing: AnyObject {
    /// `false` when the client dropped the message, which CocoaMQTT does when its outgoing
    /// queue is full.
    @discardableResult
    func send(_ message: CocoaMQTTMessage) -> Bool
    func subscribe(to topic: String)
    func unsubscribe(from topic: String)
}

extension CocoaMQTT: MQTTPublishing {
    @discardableResult
    func send(_ message: CocoaMQTTMessage) -> Bool { publish(message) >= 0 }
    func subscribe(to topic: String) { subscribe(topic, qos: .qos1) }
    func unsubscribe(from topic: String) { unsubscribe(topic) }
}
