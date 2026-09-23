import Testing
@testable import FindMySyncPlus

/// The Licenses sheet shows the bundle's license files with the wraps inside a paragraph
/// undone, so a paragraph fills the sheet instead of stopping at the file's seventy-odd
/// columns. These pin what is joined and what is left alone, on the shapes the four files
/// actually have: the GPL's centered headings, indented first lines and notice template,
/// the EDL's short title lines, MIT's plain paragraphs under both Ink and Sparkle.
@Suite("License text reflow")
struct LicenseReflowTests {

    @Test("A wrapped paragraph becomes one line, its first-line indent dropped")
    func wrappedParagraphJoins() {
        let raw = """
          The GNU General Public License is a free, copyleft license for
        software and other kinds of works.
        """
        #expect(ShippedLicense.reflow(raw) ==
                "The GNU General Public License is a free, copyleft license for software and other kinds of works.")
    }

    @Test("A blank line still separates paragraphs")
    func blankLinesSeparateParagraphs() {
        let raw = """
        Permission is hereby granted, free of charge, to any person obtaining a copy
        of this software and associated documentation files (the "Software").

        THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
        IMPLIED.
        """
        let lines = ShippedLicense.reflow(raw).components(separatedBy: "\n")
        #expect(lines.count == 3)
        #expect(lines[1] == "")
        #expect(lines[2] == "THE SOFTWARE IS PROVIDED \"AS IS\", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED.")
    }

    @Test("Centered headings stay on their own lines, trimmed")
    func centeredHeadingsStandAlone() {
        let raw = """
                            GNU GENERAL PUBLIC LICENSE
                               Version 3, 29 June 2007
        """
        #expect(ShippedLicense.reflow(raw) == "GNU GENERAL PUBLIC LICENSE\nVersion 3, 29 June 2007")
    }

    @Test("Short lines are not run together")
    func shortLinesStayApart() {
        let raw = """
        CocoaMQTT
        Copyright (c) 2015 emqx.io. All rights reserved.
        https://github.com/emqx/CocoaMQTT
        """
        #expect(ShippedLicense.reflow(raw) == raw)
    }

    @Test("A section heading stays a line of its own")
    func sectionHeadingStandsAlone() {
        let raw = """
          0. Definitions.

          "This License" refers to version 3 of the GNU General Public License.
        """
        #expect(ShippedLicense.reflow(raw) ==
                "0. Definitions.\n\n\"This License\" refers to version 3 of the GNU General Public License.")
    }

    @Test("A placeholder line ending in > is not continued by the next line")
    func placeholderLinesStayApart() {
        let raw = """
            <one line to give the program's name and a brief idea of what it does.>
            Copyright (C) <year>  <name of author>
        """
        #expect(ShippedLicense.reflow(raw) ==
                "<one line to give the program's name and a brief idea of what it does.>\nCopyright (C) <year>  <name of author>")
    }

    /// Every case resolves to a file in the bundle.
    ///
    /// `text` falls back to "<name>.txt is missing from the app bundle.", which is what the
    /// sheet then shows. The reflow tests above run on synthetic strings and open the bundle
    /// at no point, so a case added without its file reached a user unchallenged. 2.0b shipped
    /// `Sparkle.framework` with no Sparkle notice anywhere; this is what keeps the fourth file
    /// in the bundle now that it is there.
    @Test("Every shipped license resolves to real text", arguments: ShippedLicense.allCases)
    func everyLicenseResolves(_ license: ShippedLicense) {
        let text = license.text
        #expect(text.hasSuffix("is missing from the app bundle.") == false,
                "\(license.rawValue).txt did not reach the bundle")
        // Every one of these is a real license; the shortest is MIT at well over this.
        #expect(text.count > 500)
    }
}
