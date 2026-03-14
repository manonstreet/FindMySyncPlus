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

    /// Decode Apple's special location label encoding.
    /// `_$!<home>!$_` → "Home", `_$!<work>!$_` → "Work", etc.
    /// Non-encoded labels pass through unchanged.
    static func decodeLocationLabel(_ raw: String) -> String {
        guard raw.hasPrefix("_$!<") && raw.hasSuffix(">!$_") else { return raw }
        let start = raw.index(raw.startIndex, offsetBy: 4)
        let end = raw.index(raw.endIndex, offsetBy: -4)
        guard start < end else { return raw }
        let inner = String(raw[start..<end])
        return inner.prefix(1).uppercased() + inner.dropFirst()
    }
}
