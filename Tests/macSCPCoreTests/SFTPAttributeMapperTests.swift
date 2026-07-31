import Foundation
import Testing
@testable import macSCPCore

@Suite("SFTPAttributeMapper")
struct SFTPAttributeMapperTests {
    @Test func directoryBitYieldsDirectoryKind() {
        #expect(SFTPAttributeMapper.kind(fromPermissions: 0o040755) == .directory)
    }

    @Test func regularFileBitYieldsFileKind() {
        #expect(SFTPAttributeMapper.kind(fromPermissions: 0o100644) == .file)
    }

    @Test func symlinkBitYieldsSymlinkKind() {
        #expect(SFTPAttributeMapper.kind(fromPermissions: 0o120777) == .symlink)
    }

    @Test func missingPermissionsYieldOtherKind() {
        #expect(SFTPAttributeMapper.kind(fromPermissions: nil) == .other)
    }

    @Test func itemStripsFileTypeBitsFromPermissions() {
        let item = SFTPAttributeMapper.item(
            name: "notes.txt",
            directory: "/home/tim",
            size: 1024,
            permissions: 0o100644,
            modifiedAt: nil
        )
        #expect(item.path == "/home/tim/notes.txt")
        #expect(item.kind == .file)
        #expect(item.permissions == 0o644)
        #expect(item.size == 1024)
    }

    // MARK: - Owner/group precedence (M11m/T1)

    /// longname parses successfully → its NAMES win, even when numeric
    /// uidgid is also present (the readdir case per the M11m design doc).
    @Test func longnameNamesWinOverNumericUidgid() {
        let item = SFTPAttributeMapper.item(
            name: "config.php",
            directory: "/var/www",
            size: 2454,
            permissions: 0o100644,
            modifiedAt: nil,
            longname: "-rw-r--r-- 1 www-data staff 2454 Jul 30 14:22 config.php",
            uidgid: (userId: 33, groupId: 33)
        )
        #expect(item.owner == "www-data")
        #expect(item.group == "staff")
    }

    /// No longname (the single-`stat` case) → numeric uidgid as a string.
    @Test func numericUidgidIsUsedWithoutLongname() {
        let item = SFTPAttributeMapper.item(
            name: "config.php",
            directory: "/var/www",
            size: 2454,
            permissions: 0o100644,
            modifiedAt: nil,
            uidgid: (userId: 1000, groupId: 1000)
        )
        #expect(item.owner == "1000")
        #expect(item.group == "1000")
    }

    /// longname present but unparsable → falls back to numeric uidgid,
    /// never a guessed/partial value from the malformed longname.
    @Test func malformedLongnameFallsBackToNumericUidgid() {
        let item = SFTPAttributeMapper.item(
            name: "config.php",
            directory: "/var/www",
            size: 2454,
            permissions: 0o100644,
            modifiedAt: nil,
            longname: "not an ls -l line",
            uidgid: (userId: 1000, groupId: 1000)
        )
        #expect(item.owner == "1000")
        #expect(item.group == "1000")
    }

    /// Neither longname nor uidgid → nil, never a guess.
    @Test func neitherLongnameNorUidgidYieldsNilOwnerAndGroup() {
        let item = SFTPAttributeMapper.item(
            name: "config.php",
            directory: "/var/www",
            size: 2454,
            permissions: 0o100644,
            modifiedAt: nil
        )
        #expect(item.owner == nil)
        #expect(item.group == nil)
    }
}
