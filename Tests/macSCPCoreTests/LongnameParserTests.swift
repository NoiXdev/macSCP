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

    // MARK: - Trailing permission-field markers (M11m/T1 fix round)

    @Test func selinuxDotMarkerYieldsOwnerAndGroup() {
        // SELinux security-context marker `.` — the default on
        // RHEL/CentOS/Fedora/Rocky/AlmaLinux, present on every entry.
        let longname = "-rw-r--r--. 1 www-data staff 2454 Jul 30 14:22 config.php"
        let result = LongnameParser.ownerGroup(from: longname)
        #expect(result?.owner == "www-data")
        #expect(result?.group == "staff")
    }

    @Test func aclPlusMarkerYieldsOwnerAndGroup() {
        // POSIX ACL marker `+` — files/dirs with extended ACLs (Samba, `setfacl`).
        let longname = "-rw-r--r--+ 1 alice devs 10 Jan 1 00:00 f"
        let result = LongnameParser.ownerGroup(from: longname)
        #expect(result?.owner == "alice")
        #expect(result?.group == "devs")
    }

    @Test func macOSAtMarkerYieldsOwnerAndGroup() {
        // Extended-attribute marker `@` — nearly every file on a
        // macOS-hosted SFTP server.
        let longname = "-rw-r--r--@ 1 me wheel 5 Jan 1 00:00 g"
        let result = LongnameParser.ownerGroup(from: longname)
        #expect(result?.owner == "me")
        #expect(result?.group == "wheel")
    }

    @Test func garbageEleventhCharacterYieldsNil() {
        // The marker set is closed to `. + @`; any other 11th character
        // still means "doesn't confidently look like an ls -l line".
        let longname = "-rw-r--r--X 1 www-data staff 2454 Jul 30 14:22 config.php"
        #expect(LongnameParser.ownerGroup(from: longname) == nil)
    }

    @Test func directoryWithSelinuxMarkerYieldsOwnerAndGroup() {
        let longname = "drwxr-xr-x. 2 root root 4096 Jul 30 14:22 etc"
        let result = LongnameParser.ownerGroup(from: longname)
        #expect(result?.owner == "root")
        #expect(result?.group == "root")
    }
}
