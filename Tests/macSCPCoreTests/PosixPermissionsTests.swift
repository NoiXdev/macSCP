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

    @Test func directoryDefaultAddsExecuteWhereReadable() {
        #expect(PosixPermissions.directoryDefault(from: 0o644) == 0o755)
        #expect(PosixPermissions.directoryDefault(from: 0o600) == 0o700)
        #expect(PosixPermissions.directoryDefault(from: 0o640) == 0o750)
        #expect(PosixPermissions.directoryDefault(from: 0o2644) == 0o2755)
        #expect(PosixPermissions.directoryDefault(from: 0o000) == 0o000)
    }

    // MARK: - rwxString (M11m/T1)

    @Test func rwxStringRendersEachTriad() {
        #expect(PosixPermissions(rawValue: 0o644).rwxString == "rw-r--r--")
        #expect(PosixPermissions(rawValue: 0o755).rwxString == "rwxr-xr-x")
        #expect(PosixPermissions(rawValue: 0o000).rwxString == "---------")
        #expect(PosixPermissions(rawValue: 0o777).rwxString == "rwxrwxrwx")
    }
}
