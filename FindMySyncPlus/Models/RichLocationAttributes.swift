import Foundation

struct RichLocationAttributes: Sendable {
    let verticalAccuracy: Double?
    let altitude: Double?
    let speed: Double?
    let course: Double?
    let timestamp: Date?
    let motionActivityState: Int?
    let locationLabel: String?
    /// Apple's own staleness flag, passed through rather than turned into a rule of ours.
    /// Absent stays absent: a fabricated `false` would claim Apple called the fix current.
    let isOld: Bool?
    /// Apple's name for how the fix was obtained — `Wifi`, `GPS`, `crowdsourced`,
    /// `ownedDeviceLocation` so far. Passed through verbatim: an unmapped value must stay
    /// visible rather than be folded into a plausible default.
    let positionType: String?
    /// Apple's own accuracy judgement, passed through like `isOld`. The `true` branch has not
    /// been observed, which is a reason not to claim it is validated, not to withhold it.
    let isInaccurate: Bool?
    /// The category picked when an item is set up on iPhone — Backpack, Keys, Wallet — with
    /// the emoji chosen beside it. Items only. Absent when the owner typed a name instead:
    /// Apple stores the literal "Custom Name" there, which `CacheDecryptor` drops.
    let role: String?
    let roleEmoji: String?
    /// One pre-formatted address line, `address.mediumAddressModern`. Not `streetAddress`,
    /// which is the house number alone, and not the whole `address` dict, which churns on
    /// every position change.
    let address: String?
    /// Which piece a grouped entity's coordinate came from — `Case`, `Left Bud` — or `self`
    /// when the group's own record supplied it. Without this a borrowed position and an own
    /// position are indistinguishable.
    let positionSource: String?
    /// Whether the pieces of a grouped accessory are `together`, `separated`, or `unknown`
    /// because a position is too stale to compare. Three states, not a boolean: a stale piece
    /// 40 km away means it reported yesterday, not that it is elsewhere now.
    let separationStatus: String?
    /// Where each piece of a separated group is: name, address and age. Carried only while
    /// `separationStatus` is `separated` — the moment a piece has been left somewhere and
    /// "which one, and where" has an answer worth publishing.
    let pieces: [[String: String]]?

    /// Explicit rather than memberwise so the later fields can default without breaking
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
         role: String? = nil,
         roleEmoji: String? = nil,
         address: String? = nil,
         positionSource: String? = nil,
         separationStatus: String? = nil,
         pieces: [[String: String]]? = nil) {
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
        self.role = role
        self.roleEmoji = roleEmoji
        self.address = address
        self.positionSource = positionSource
        self.separationStatus = separationStatus
        self.pieces = pieces
    }

    /// Overlay `other`'s populated fields onto these. A family device appears in both caches:
    /// FMIP gives the location, `timestamp` and `isOld`; the LocalStorage friend record gives
    /// the richer fields. The friend record wins wherever it has a value; ours fill the gaps,
    /// `isOld` in particular, which only FMIP reports.
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
            // Only FMIP records carry these — a friend record has no role or address — so ours
            // survive in practice. Merged the same way regardless, so the rule stays one rule.
            isInaccurate: other.isInaccurate ?? isInaccurate,
            role: other.role ?? role,
            roleEmoji: other.roleEmoji ?? roleEmoji,
            address: other.address ?? address,
            positionSource: other.positionSource ?? positionSource,
            separationStatus: other.separationStatus ?? separationStatus,
            pieces: other.pieces ?? pieces
        )
    }

    /// A copy naming where a grouped entity's coordinate came from, recorded at the point
    /// the backfill decides it rather than reconstructed afterwards.
    func namingSource(_ source: String) -> RichLocationAttributes {
        RichLocationAttributes(
            verticalAccuracy: verticalAccuracy, altitude: altitude,
            speed: speed, course: course, timestamp: timestamp,
            motionActivityState: motionActivityState, locationLabel: locationLabel,
            isOld: isOld, positionType: positionType, isInaccurate: isInaccurate,
            role: role, roleEmoji: roleEmoji, address: address,
            positionSource: source, separationStatus: separationStatus, pieces: pieces)
    }

    /// A copy carrying a group's separation state, and where its pieces are when they
    /// are apart.
    func naming(separation: String, pieces: [[String: String]]? = nil) -> RichLocationAttributes {
        RichLocationAttributes(
            verticalAccuracy: verticalAccuracy, altitude: altitude,
            speed: speed, course: course, timestamp: timestamp,
            motionActivityState: motionActivityState, locationLabel: locationLabel,
            isOld: isOld, positionType: positionType, isInaccurate: isInaccurate,
            role: role, roleEmoji: roleEmoji, address: address,
            positionSource: positionSource, separationStatus: separation,
            pieces: pieces ?? self.pieces)
    }

    /// Everything absent. For a group parent that reached the plan with no attributes of
    /// its own but still needs to say where its position came from.
    static var empty: RichLocationAttributes {
        RichLocationAttributes(verticalAccuracy: nil, altitude: nil, speed: nil,
                               course: nil, timestamp: nil, motionActivityState: nil,
                               locationLabel: nil)
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
            // Apple has added activity types before. Folding an unmapped value into "Unknown"
            // makes it indistinguishable from a genuine 0, so the raw value stays visible — the
            // same reasoning as `decodeLocationLabel` passing unrecognized input through.
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
