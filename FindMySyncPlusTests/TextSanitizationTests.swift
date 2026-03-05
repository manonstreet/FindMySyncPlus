import XCTest
@testable import FindMySyncPlus

final class TextSanitizationTests: XCTestCase {

    // MARK: - slugifyAlias

    func testSlugify_simple() {
        XCTAssertEqual(slugifyAlias("AirPods"), "airpods")
    }

    func testSlugify_spacesBecomeDash() {
        XCTAssertEqual(slugifyAlias("My AirTag"), "my-airtag")
    }

    func testSlugify_collapsesMultipleSpaces() {
        XCTAssertEqual(slugifyAlias("a   b"), "a-b")
    }

    func testSlugify_preservesHyphensAndUnderscores() {
        XCTAssertEqual(slugifyAlias("my-air_tag"), "my-air_tag")
    }

    func testSlugify_trimLeadingTrailingHyphens() {
        XCTAssertEqual(slugifyAlias("  hello  "), "hello")
    }

    func testSlugify_accents() {
        XCTAssertEqual(slugifyAlias("café"), "cafe")
    }

    func testSlugify_apostrophe() {
        XCTAssertEqual(slugifyAlias("Joel's AirTag"), "joel-s-airtag")
    }

    func testSlugify_emptyReturnsDevice() {
        XCTAssertEqual(slugifyAlias(""), "device")
    }

    func testSlugify_onlySpecialCharsReturnsDevice() {
        XCTAssertEqual(slugifyAlias("!!!"), "device")
    }

    func testSlugify_maxLength() {
        let long = String(repeating: "a", count: 100)
        let result = slugifyAlias(long)
        XCTAssertLessThanOrEqual(result.count, 48)
    }

    func testSlugify_customMaxLength() {
        let result = slugifyAlias("abcdefghij", maxLen: 5)
        XCTAssertEqual(result, "abcde")
    }

    func testSlugify_numbers() {
        XCTAssertEqual(slugifyAlias("AirTag 42"), "airtag-42")
    }

    // MARK: - normalizeID

    func testNormalizeID_validString() {
        XCTAssertEqual(normalizeID("abc-123"), "abc-123")
    }

    func testNormalizeID_nil() {
        XCTAssertNil(normalizeID(nil))
    }

    func testNormalizeID_nonString() {
        XCTAssertNil(normalizeID(42))
    }

    func testNormalizeID_emptyString() {
        XCTAssertNil(normalizeID(""))
    }

    func testNormalizeID_whitespaceOnly() {
        XCTAssertNil(normalizeID("   "))
    }

    func testNormalizeID_null() {
        XCTAssertNil(normalizeID("null"))
    }

    func testNormalizeID_nullUppercase() {
        XCTAssertNil(normalizeID("NULL"))
    }

    func testNormalizeID_dollarNull() {
        XCTAssertNil(normalizeID("$null"))
    }

    func testNormalizeID_angleBracketNull() {
        XCTAssertNil(normalizeID("<null>"))
    }

    func testNormalizeID_parenNull() {
        XCTAssertNil(normalizeID("(null)"))
    }

    func testNormalizeID_none() {
        XCTAssertNil(normalizeID("none"))
    }

    func testNormalizeID_trimsWhitespace() {
        XCTAssertEqual(normalizeID("  hello  "), "hello")
    }

    func testNormalizeID_preservesCase() {
        XCTAssertEqual(normalizeID("AbC"), "AbC")
    }

    // MARK: - nonNullish extension

    func testNonNullish_validString() {
        let s: String? = "hello"
        XCTAssertEqual(s.nonNullish, "hello")
    }

    func testNonNullish_nil() {
        let s: String? = nil
        XCTAssertNil(s.nonNullish)
    }

    func testNonNullish_nullString() {
        let s: String? = "null"
        XCTAssertNil(s.nonNullish)
    }

    func testNonNullish_empty() {
        let s: String? = ""
        XCTAssertNil(s.nonNullish)
    }

    // MARK: - String.normalized()

    func testNormalized_lowercaseHex() {
        XCTAssertEqual("AB-CD-EF".normalized(), "abcdef")
    }

    func testNormalized_stripsNonHex() {
        XCTAssertEqual("g1h2i3".normalized(), "123")
    }

    // MARK: - macFromAlias

    func testMacFromAlias_format() {
        let mac = macFromAlias("test")
        let parts = mac.split(separator: ":")
        XCTAssertEqual(parts.count, 6)
        for part in parts {
            XCTAssertEqual(part.count, 2)
        }
    }

    func testMacFromAlias_deterministic() {
        XCTAssertEqual(macFromAlias("foo"), macFromAlias("foo"))
    }

    func testMacFromAlias_differentInputsDiffer() {
        XCTAssertNotEqual(macFromAlias("foo"), macFromAlias("bar"))
    }
}
