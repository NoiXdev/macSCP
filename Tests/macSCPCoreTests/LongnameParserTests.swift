import Testing
@testable import macSCPCore

/// `LongnameParser` reads the server-formatted `ls -l` style `longname`
/// field SFTP directory listings carry (M11m/T1): field order after the
/// permission string is link count, owner, group. The parser is pure and
/// defensive — anything that doesn't clearly look like an `ls -l` line
/// returns `nil` rather than guessing (see the M11m design doc's "honest
/// about longname fragility" section).
@Suite("LongnameParser")
struct LongnameParserTests {
    @Test func standardLineYieldsOwnerAndGroup() {
        let longname = "-rw-r--r-- 1 www-data staff 2454 Jul 30 14:22 config.php"
        let result = LongnameParser.ownerGroup(from: longname)
        #expect(result?.owner == "www-data")
        #expect(result?.group == "staff")
    }

    @Test func directoryLineYieldsOwnerAndGroup() {
        let longname = "drwxr-xr-x 5 tim staff 160 Jul 30 14:22 sub"
        let result = LongnameParser.ownerGroup(from: longname)
        #expect(result?.owner == "tim")
        #expect(result?.group == "staff")
    }

    @Test func multipleSpacesBetweenFieldsAreTolerated() {
        let longname = "-rw-r--r--    1   www-data   staff   2454 Jul 30 14:22 config.php"
        let result = LongnameParser.ownerGroup(from: longname)
        #expect(result?.owner == "www-data")
        #expect(result?.group == "staff")
    }

    @Test func ownerAndGroupWithSpecialCharactersParseCorrectly() {
        let longname = "-rw-r--r-- 1 john.doe_1 dev-team 2454 Jul 30 14:22 config.php"
        let result = LongnameParser.ownerGroup(from: longname)
        #expect(result?.owner == "john.doe_1")
        #expect(result?.group == "dev-team")
    }

    @Test func emptyStringYieldsNil() {
        #expect(LongnameParser.ownerGroup(from: "") == nil)
    }

    @Test func tooShortLineYieldsNil() {
        #expect(LongnameParser.ownerGroup(from: "-rw-r--r-- 1 www-data") == nil)
    }

    @Test func lineWithoutGroupFieldYieldsNil() {
        // Only permissions, link count, owner — group column missing.
        #expect(LongnameParser.ownerGroup(from: "-rw-r--r-- 1 www-data") == nil)
    }

    @Test func lineWithNonNumericLinkCountYieldsNil() {
        let longname = "-rw-r--r-- www-data staff 2454 Jul 30 14:22 config.php"
        #expect(LongnameParser.ownerGroup(from: longname) == nil)
    }

    @Test func lineWithMalformedPermissionFieldYieldsNil() {
        let longname = "garbage 1 www-data staff 2454 Jul 30 14:22 config.php"
        #expect(LongnameParser.ownerGroup(from: longname) == nil)
    }

    @Test func totalSummaryLineYieldsNil() {
        // `ls -l` sometimes emits a leading "total N" line — must never be
        // mistaken for an entry.
        #expect(LongnameParser.ownerGroup(from: "total 8") == nil)
    }
}
