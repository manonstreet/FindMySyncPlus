import Testing
@testable import FindMySyncPlus

/// Home Assistant entity IDs allow only `[a-z0-9_]` in the object part, while
/// `slugifyAlias` deliberately permits hyphens — and collapses every other
/// disallowed character *into* a hyphen, so any alias typed with a space contains
/// one.
///
/// **This is not a safety measure.** Verified against HA's source (2026-08-23):
/// `default_entity_id` is validated with `cv.string`, not `cv.entity_id`, and
/// `async_generate_entity_id` slugifies its input, so HA would sanitise a hyphen
/// itself and reach the same entity ID. An earlier draft claimed an unslugged
/// value would make HA reject the whole config — that was wrong.
///
/// What it buys is honesty: we publish the value HA will actually create, so the
/// resolved entity ID we log is the real one rather than something HA silently
/// rewrites. It also holds if HA ever tightens that validator to `cv.entity_id`,
/// which its own documentation already describes.
///
/// It must never be applied to `unique_id`, which is the entity registry's
/// identity key and has to stay byte-identical across releases.
@Suite("HA entity object ID slug")
struct HASlugTests {

    @Test("converts hyphens to underscores")
    func hyphensBecomeUnderscores() {
        #expect(haSlug("findmy_ohrapfel-case") == "findmy_ohrapfel_case")
    }

    @Test("leaves an already-valid slug untouched")
    func validSlugUnchanged() {
        #expect(haSlug("findmy_airpods") == "findmy_airpods")
    }

    @Test("lowercases")
    func lowercases() {
        #expect(haSlug("FindMy_AirTag") == "findmy_airtag")
    }

    /// Matches Home Assistant's own slugify, which collapses runs.
    @Test("collapses runs of underscores")
    func collapsesRuns() {
        #expect(haSlug("findmy_-_left--bud") == "findmy_left_bud")
    }

    @Test("trims leading and trailing underscores")
    func trimsEdges() {
        #expect(haSlug("-findmy-case-") == "findmy_case")
    }

    /// `Character.isLetter` is true for "é", which HA would reject — the fold has
    /// to be ASCII-only.
    @Test("replaces characters outside [a-z0-9_]")
    func replacesOtherCharacters() {
        #expect(haSlug("findmy_joe's café") == "findmy_joe_s_caf")
    }

    @Test("digits survive")
    func digitsSurvive() {
        #expect(haSlug("findmy_airtag-2") == "findmy_airtag_2")
    }

    /// Mirrors slugifyAlias's existing empty-input fallback rather than returning
    /// "", which would produce the invalid entity ID "device_tracker.".
    @Test("falls back to device when nothing survives")
    func emptyFallsBack() {
        #expect(haSlug("---") == "device")
        #expect(haSlug("") == "device")
    }
}

/// The entity ID an alias resolves to in Home Assistant.
///
/// Device Manager shows this on the alias row and copies it, and the discovery
/// payload publishes it as `default_entity_id`. Those two must be the same
/// string: a row that displays an entity ID the app does not actually publish
/// would be a more convincing lie than showing nothing, which is roughly what
/// issue #22 was — the user had to subscribe to the MQTT topic to find out what
/// we were really sending.
@Suite("Alias to HA entity ID")
struct AliasEntityIDTests {

    @Test("resolves an alias to its full entity ID")
    func resolvesFullEntityID() {
        #expect(DeviceAlias.haEntityID(for: "ohrapfel-case")
                == "device_tracker.findmy_ohrapfel_case")
    }

    @Test("keeps the findmy_ prefix")
    func keepsPrefix() {
        #expect(DeviceAlias.haEntityID(for: "airpods") == "device_tracker.findmy_airpods")
    }

    /// Single source of truth: what the row shows is what the payload publishes.
    @Test("matches the default_entity_id in the discovery payload")
    func matchesPublishedPayload() {
        let alias = "ohrapfel-case"
        let devId = DeviceAlias.entityID(for: alias)
        let payload = MQTTClient.discoveryPayload(devId: devId,
                                                  displayName: "Case",
                                                  topicPrefix: "findmysyncplus/")

        #expect(payload["default_entity_id"] as? String == DeviceAlias.haEntityID(for: alias))
    }
}
