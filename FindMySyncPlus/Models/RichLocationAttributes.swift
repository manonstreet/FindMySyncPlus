import Foundation

struct RichLocationAttributes: Sendable {
    let verticalAccuracy: Double?
    let altitude: Double?
    let speed: Double?
    let course: Double?
    let timestamp: Date?
    let motionActivityState: Int?
    let locationLabel: String?
    /// Apple's own staleness flag for the fix, passed through rather than turned
    /// into a rule of ours about what counts as stale. Absent stays absent: a
    /// fabricated `false` would claim Apple called the fix current, which is a
    /// different statement from Apple saying nothing.
    let isOld: Bool?
    /// Apple's name for how the fix was obtained — `Wifi`, `GPS`, `crowdsourced`,
    /// `ownedDeviceLocation` so far. Passed through verbatim: an unmapped value must
    /// stay visible rather than be folded into a plausible-looking default.
    ///
    /// It matters most when a position came from the crowdsourced fallback, where the
    /// source would otherwise be silently substituted.
    let positionType: String?
    /// Apple's own accuracy judgement on the fix, passed through the same way `isOld`
    /// is. Measured `false` on every item so far, so the `true` branch is unexercised —
    /// which is a reason not to claim it is validated, not a reason to withhold it.
    let isInaccurate: Bool?
    /// `Left` / `Right` / `Case` — Apple's vocabulary for a piece of a grouped
    /// accessory, and the same words the grouped-accessory work already deals in.
    /// Absent on anything that is not part of a pair.
    let partName: String?
    /// The user's own label for the item, chosen by them in Find My, and its emoji.
    /// Content rather than vocabulary: fine to publish to their own broker, and never
    /// to be printed in a diagnostic.
    let role: String?
    let roleEmoji: String?
    /// One pre-formatted address line, `address.mediumAddressModern` — house number,
    /// street and city. Apple writes four widths and this is the one chosen; nothing is
    /// assembled or parsed here.
    ///
    /// Deliberately not `streetAddress`, which measured as the house number alone (`9`,
    /// `999`), and deliberately not the whole 19-key dict, which is ~670 B churning on
    /// every position change.
    let address: String?

    /// Explicit rather than memberwise so `isOld` can default — every other field
    /// is a `let` with no default, so adding one would otherwise break all five
    /// existing call sites.
    init(verticalAccuracy: Double?,
         altitude: Double?,
         speed: Double?,
         course: Double?,
         timestamp: Date?,
         motionActivityState: Int?,
         locationLabel: String?,
         isOld: Bool? = nil,
         positionType: String? = nil,
         isInaccurate: Bool? = nil,
         partName: String? = nil,
         role: String? = nil,
         roleEmoji: String? = nil,
         address: String? = nil) {
        self.verticalAccuracy = verticalAccuracy
        self.altitude = altitude
        self.speed = speed
        self.course = course
        self.timestamp = timestamp
        self.motionActivityState = motionActivityState
        self.locationLabel = locationLabel
        self.isOld = isOld
        self.positionType = positionType
        self.isInaccurate = isInaccurate
        self.partName = partName
        self.role = role
        self.roleEmoji = roleEmoji
        self.address = address
    }

    /// Overlay `other`'s populated fields onto these, field by field.
    ///
    /// A family device appears in both caches: FMIP gives the location plus
    /// `timestamp` and `isOld`, and the friend record in LocalStorage gives the
    /// richer fields — altitude, speed, course, motion state, location label. The
    /// friend record wins wherever it has a value, which preserves the behavior
    /// from when it replaced the device's attributes outright; ours fill the gaps
    /// it does not cover, `isOld` in particular, which only FMIP reports.
    func mergedPreferring(_ other: RichLocationAttributes) -> RichLocationAttributes {
        RichLocationAttributes(
            verticalAccuracy: other.verticalAccuracy ?? verticalAccuracy,
            altitude: other.altitude ?? altitude,
            speed: other.speed ?? speed,
            course: other.course ?? course,
            timestamp: other.timestamp ?? timestamp,
            motionActivityState: other.motionActivityState ?? motionActivityState,
            locationLabel: other.locationLabel ?? locationLabel,
            isOld: other.isOld ?? isOld,
            positionType: other.positionType ?? positionType,
            // Only FMIP records carry these five — a friend record has no parts, no
            // role and no address — so in practice ours always survive. Merged the
            // same way regardless, so the rule stays one rule.
            isInaccurate: other.isInaccurate ?? isInaccurate,
            partName: other.partName ?? partName,
            role: other.role ?? role,
            roleEmoji: other.roleEmoji ?? roleEmoji,
            address: other.address ?? address
        )
    }

    var motionStateDescription: String {
        switch motionActivityState {
        case 0: return "Unknown"
        case 1: return "Stationary"
        case 2: return "Walking"
        case 3: return "Running"
        case 4: return "Automotive"
        case 5: return "Cycling"
        case .none: return "Unknown"
        case .some(let raw):
            // Apple has added activity types before. Folding an unmapped value into
            // "Unknown" makes it indistinguishable from a genuine 0 and impossible to
            // notice, so the raw value stays visible — the same reasoning as
            // `decodeLocationLabel` passing unrecognized input through unchanged.
            return "Unmapped(\(raw))"
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
