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
    /// The category picked when an item is set up on iPhone — one of a fixed list
    /// (Backpack, Keys, Wallet, …), with the emoji chosen beside it. Items only; a
    /// device carries none.
    ///
    /// Absent when the owner typed a name instead of picking a category: Apple stores
    /// the literal string "Custom Name" there, and the name they actually typed is the
    /// item's `name`. `CacheDecryptor` drops that placeholder, so this is either a real
    /// category or nothing.
    let role: String?
    let roleEmoji: String?
    /// One pre-formatted address line, `address.mediumAddressModern` — house number,
    /// street and city. Apple writes four widths and this is the one chosen; nothing is
    /// assembled or parsed here.
    ///
    /// Deliberately not `streetAddress`, which is the house number alone, and not the
    /// whole `address` dict, which is ~670 B churning on every position change.
    let address: String?
    /// Which piece a grouped entity's coordinate came from — `Case`, `Left Bud` — or
    /// `self` when the group's own record supplied it.
    ///
    /// A group's position is sometimes its own and sometimes borrowed, and without this
    /// the two are indistinguishable. `self` covers a coordinate Apple sourced elsewhere
    /// too: it is still the group's record that holds it, and inferring otherwise would
    /// mean cross-matching against other devices.
    let positionSource: String?
    /// Whether the pieces of a grouped accessory are `together`, `separated`, or
    /// `unknown` because at least one position is too stale to compare.
    ///
    /// Three states rather than a boolean: a stale piece 40 km away means it reported
    /// yesterday, not that it is elsewhere now.
    let separationStatus: String?
    /// Where each piece of a separated group is: name, address and age, one entry per
    /// piece.
    ///
    /// Carried only while `separationStatus` is `separated`, because that is the moment a
    /// piece has been left somewhere and the question "which one, and where" has an
    /// answer worth publishing. A tracker entity per piece answers it badly — it is
    /// permanent, and the question is momentary.
    let pieces: [[String: String]]?

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
            // Only FMIP records carry these four — a friend record has no role and no
            // address — so in practice ours always survive. Merged the same way
            // regardless, so the rule stays one rule.
            isInaccurate: other.isInaccurate ?? isInaccurate,
            role: other.role ?? role,
            roleEmoji: other.roleEmoji ?? roleEmoji,
            address: other.address ?? address,
            positionSource: other.positionSource ?? positionSource,
            separationStatus: other.separationStatus ?? separationStatus,
            pieces: other.pieces ?? pieces
        )
    }

    /// A copy naming where a grouped entity's coordinate came from.
    ///
    /// The backfill already decides this — it either keeps the parent's own position or
    /// takes a child's — so the value is recorded at the point of the decision rather
    /// than reconstructed afterwards.
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
