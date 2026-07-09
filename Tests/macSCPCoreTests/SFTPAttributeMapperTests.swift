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
}
