import Foundation

struct RichLocationAttributes: Sendable {
    let verticalAccuracy: Double?
    let altitude: Double?
    let speed: Double?
    let course: Double?
    let timestamp: Date?
    let motionActivityState: Int?
    let locationLabel: String?

    var motionStateDescription: String {
        switch motionActivityState {
        case 0: return "Unknown"
        case 1: return "Stationary"
        case 2: return "Walking"
        case 3: return "Running"
        case 4: return "Automotive"
        case 5: return "Cycling"
        default: return "Unknown"
        }
    }
}
