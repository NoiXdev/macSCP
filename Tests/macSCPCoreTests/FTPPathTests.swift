import Testing

@testable import macSCPCore

/// The one choke point every path and every command argument crosses before
/// the control connection may write it (Review Focus 1 of the FTP plan).
///
/// An FTP command line is terminated by CR LF, so a file name carrying one
/// injects a second command into the control channel — the FTP analogue of
/// header injection. A NUL is refused with it: it terminates a C string, and
/// the byte path from here to a server's own parser is not all Swift.
///
/// The three cases below are the character classes, not the characters: the
/// refusal names the class, so a reader of the error learns which rule the
/// path broke rather than which byte it happened to carry.
@Suite("FTP path validation")
struct FTPPathTests {
    @Test func aPathCarryingCRLFIsRefusedBeforeItReachesTheWire() throws {
        // What the refusal is for: the tail is a whole second command.
        let injecting = "/notes\r\nDELE /invoices/2026.pdf"
        #expect(throws: FTPPathRefusal.forbiddenCharacter(.carriageReturn)) {
            try FTPPath.validated(injecting)
        }
        // A lone LF is refused on its own account, not only as CR LF's tail.
        #expect(throws: FTPPathRefusal.forbiddenCharacter(.lineFeed)) {
            try FTPPath.validated("/notes\nDELE /invoices/2026.pdf")
        }
    }

    @Test func aPathCarryingNULIsRefused() throws {
        #expect(throws: FTPPathRefusal.forbiddenCharacter(.nul)) {
            try FTPPath.validated("/notes\u{00}.txt")
        }
    }

    @Test func anOrdinaryPathWithSpacesAndSemicolonsPassesThrough() throws {
        // Everything a shell would mind and FTP does not: FTP has no shell,
        // and a validator that refused these would refuse real file names.
        let ordinary = "/Invoices 2026/a;b & c $d `e` (f) -g/ünïcode ✓.txt"
        #expect(try FTPPath.validated(ordinary) == ordinary)
        // The empty argument is a path too: `LIST` with no argument.
        #expect(try FTPPath.validated("") == "")
    }

    /// The positive half of the three refusals above: every class the type
    /// declares is actually refused, and the one it reports is the one the
    /// path carried. Derived from `allCases`, so a class added to the enum
    /// without a check in `validated` fails here instead of passing in
    /// silence.
    @Test func everyForbiddenCharacterClassIsRefusedByTheClassItNames() throws {
        for forbidden in FTPPath.ForbiddenCharacter.allCases {
            let path = "/a\(Character(forbidden.scalar))b"
            #expect(throws: FTPPathRefusal.forbiddenCharacter(forbidden)) {
                try FTPPath.validated(path)
            }
        }
        #expect(FTPPath.ForbiddenCharacter.allCases.count == 3)
    }

    /// Each class has a sentence of its own in all four catalogs. The lookup
    /// cannot fail loudly — `CoreL10n.string` falls back to the key text —
    /// so the check is that it does NOT come back as its own key.
    @Test func everyForbiddenCharacterClassHasItsOwnSentence() throws {
        for forbidden in FTPPath.ForbiddenCharacter.allCases {
            let key = forbidden.messageKey
            #expect(CoreL10n.string(key) != key, "no catalog text for \(key)")
        }
    }
}
