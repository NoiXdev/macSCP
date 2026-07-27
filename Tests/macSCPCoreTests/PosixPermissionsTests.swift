import Testing
@testable import macSCPCore

@Suite("PosixPermissions")
struct PosixPermissionsTests {
    @Test func rawValueIsMaskedToLow12Bits() {
        #expect(PosixPermissions(rawValue: 0o100644).rawValue == 0o644)
    }

    @Test func octalStringRoundtrip() {
        #expect(PosixPermissions(rawValue: 0o640).octalString == "640")
        #expect(PosixPermissions(rawValue: 0o4755).octalString == "4755")
        #expect(PosixPermissions(octalString: "640")?.rawValue == 0o640)
        #expect(PosixPermissions(octalString: "4755")?.rawValue == 0o4755)
        #expect(PosixPermissions(octalString: "9") == nil)
        #expect(PosixPermissions(octalString: "") == nil)
        #expect(PosixPermissions(octalString: "77777") == nil)
    }

    @Test func bitAccessorsMatchOctal() {
        var p = PosixPermissions(rawValue: 0o640)
        #expect(p[.owner, .read] && p[.owner, .write] && !p[.owner, .execute])
        #expect(p[.group, .read] && !p[.group, .write])
        #expect(!p[.other, .read])
        p[.other, .read] = true
        #expect(p.rawValue == 0o644)
    }
}
