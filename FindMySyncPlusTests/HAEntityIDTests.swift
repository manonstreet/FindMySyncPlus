import Testing
@testable import FindMySyncPlus

/// Home Assistant entity IDs allow only `[a-z0-9_]` in the object part, while
/// `slugifyAlias` deliberately permits hyphens — and collapses every other
/// disallowed character *into* a hyphen, so any alias typed with a space contains
/// one. Publishing an unslugged value as `default_entity_id` fails HA's entity-ID
/// validation, which rejects the whole discovery config: the entity vanishes
/// rather than merely being misnamed. That is worse than the bug it fixes, so
/// this conversion gets its own tests.
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
