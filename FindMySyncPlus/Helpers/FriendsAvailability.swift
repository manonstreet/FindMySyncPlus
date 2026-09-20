import Foundation

/// How a key's indicator should read. The FMF and LocalStorage keys serve Friends only, so
/// when Friends cannot run they are not missing — they are irrelevant, and showing them as
/// unset leaves two warnings the user has no way to clear.
enum KeyApplicability: Equatable {
    /// Report the key's real status.
    case reported
    /// This macOS does not provide friend locations.
    case needsNewerOS
    /// The user switched Friends off.
    case friendsOff

    /// Replaces the status text, naming the reason in place, so the indicator stands on its
    /// own. Terse because the row is name-then-status in a window free to narrow, and the
    /// greyed name and minus icon already say "not applicable"; the reason is the information.
    var label: String? {
        switch self {
        case .reported:     return nil
        case .needsNewerOS: return FriendsAvailability.shortRestriction
        case .friendsOff:   return "Friends off"
        }
    }

    var isNotApplicable: Bool { self != .reported }
}

/// Whether friend locations can work on this machine. They require macOS 15: on 14 the
/// Find My app itself has no location for shared people, so there is nothing on disk to
/// read and the `secureLocations` table is never created.
///
/// Gated on the version rather than on the table, because checking for the table means
/// opening the database, which parses the WAL, which fires the stale-salt warning the gate
/// exists to remove. The version is a stored property so the macOS 14 branch can be
/// exercised on hardware that cannot run it.
struct FriendsAvailability {

    /// The lowest macOS that holds a friend location at all.
    static let minimumMajorVersion = 15

    /// The version this decision was made against — the running one, unless spoofed.
    let osVersion: OperatingSystemVersion

    /// Whether `osVersion` came from `spoofOSVersion` rather than from the machine.
    /// The caller logs this, so a spoofed run is never mistaken for a real one.
    let isSpoofed: Bool

    init(osVersion: OperatingSystemVersion, isSpoofed: Bool = false) {
        self.osVersion = osVersion
        self.isSpoofed = isSpoofed
    }

    /// True when this version of macOS provides friend locations.
    var isSupported: Bool { osVersion.majorVersion >= Self.minimumMajorVersion }

    /// `14.8.9`. Named in the status log, because the running version is the fact a
    /// reporter would otherwise be asked for.
    var versionDescription: String {
        "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
    }

    /// Whether the Friends path should run: the user asked for it and this macOS provides it.
    /// Applied by the engine rather than trusting the toggle, because a stored `true` can
    /// arrive from an upgraded machine or synced defaults.
    func isEnabled(userToggle: Bool) -> Bool { userToggle && isSupported }

    /// How the FMF and LocalStorage indicators should read. Both serve Friends only, so
    /// whenever Friends will not run they say so, and say why, rather than showing a
    /// warning the user has no way to clear.
    ///
    /// The macOS reason outranks the toggle: it is the one the user cannot act on.
    func keyApplicability(userToggle: Bool) -> KeyApplicability {
        guard isSupported else { return .needsNewerOS }
        return userToggle ? .reported : .friendsOff
    }

    /// Named from the predicate itself, so the copy cannot outlive a change to the gate.
    static var minimumVersionName: String { "macOS \(minimumMajorVersion)" }

    /// Trailing status on the key indicators, which have nothing after them on the row.
    static var shortRestriction: String { "Needs \(minimumVersionName)" }

    /// Parenthetical after a toggle's label, matching "(minutes)" and "(seconds)" in the same
    /// window — lower case for that reason; the key rows capitalize because there it stands alone.
    static var toggleQualifier: String { "needs \(minimumVersionName)" }

    /// Shown in the status log once per launch when the version rules Friends out.
    var restrictionMessage: String {
        "Friends: requires macOS 15 or later — skipping. This Mac reports \(versionDescription)."
    }

    /// Shown whenever the version was substituted, so a spoofed run is never mistaken
    /// for a real one — a screenshot of either would otherwise look identical.
    var spoofMessage: String {
        "spoofOSVersion is set: macOS is being reported as \(versionDescription) for this launch."
    }
}

extension FriendsAvailability {

    /// The live value for this launch. `spoofOSVersion` substitutes a version so the macOS 14
    /// presentation can be seen on hardware that cannot run it — inert unless set, like
    /// `demoRoot`, and it changes nothing that is written.
    ///
    ///     defaults write <bundle-id> spoofOSVersion 14.8.9
    static var current: FriendsAvailability {
        resolve(spoof: UserDefaults.standard.string(forKey: "spoofOSVersion"),
                actual: ProcessInfo.processInfo.operatingSystemVersion)
    }

    /// Pure, so the macOS 14 branch is testable without writing to the app's real
    /// `UserDefaults`. A value that does not parse falls back to `actual`: a typo in an
    /// undocumented key must not silently disable a working feature.
    static func resolve(spoof: String?, actual: OperatingSystemVersion) -> FriendsAvailability {
        guard let spoof, let spoofed = parse(spoof) else {
            return FriendsAvailability(osVersion: actual)
        }
        return FriendsAvailability(osVersion: spoofed, isSpoofed: true)
    }

    /// `14`, `14.8` and `14.8.9` all parse; absent components are zero. Anything else
    /// returns nil rather than a version that looks plausible.
    static func parse(_ value: String) -> OperatingSystemVersion? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 3 else { return nil }

        var components = [0, 0, 0]
        for (index, part) in parts.enumerated() {
            guard let number = Int(part), number >= 0 else { return nil }
            components[index] = number
        }
        return OperatingSystemVersion(majorVersion: components[0],
                                      minorVersion: components[1],
                                      patchVersion: components[2])
    }
}
