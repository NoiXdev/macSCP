import Foundation
import MacSCPTestSupport
import Testing

@testable import macSCPCore

/// An error `LocalFileSystem` does not recognise is reduced to its
/// `localizedDescription`, never to `String(describing:)`.
///
/// The rule is this project's, stated where it was first measured:
/// `DialSupport.reason(for:)`'s doc comment, and again on
/// `CitadelFileSystem.mapSFTPError` ("`localizedDescription`, not
/// `String(describing:)` … `String(describing:)` on an arbitrary error
/// prints its stored properties"). `LocalFileSystem` had five throws that
/// broke it, and until 2026-09-25 that cost nothing visible: the text was
/// dropped again wherever it was shown. It stopped being free when
/// `TransferFailureLabel` began putting a `protocolError`'s `reason` on
/// screen as a transfer row's technical detail — `String(describing:)` on
/// an `NSError` prints its domain, its code and the whole `userInfo`, so a
/// full local path and an `NSUnderlyingError` dump went to the user.
///
/// Two checks, deliberately of different kinds. The behavioural one drives
/// the real mapping with an error carrying a fat `userInfo` and reads what
/// comes out; the source scan catches the four throws no test can reach
/// without a failing disk. A scan alone would be a rule nobody drove; a
/// behavioural test alone would cover one site of five.
@Suite struct LocalFileSystemErrorTextGuardTests {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let sourceFile = repoRoot
        .appendingPathComponent("Sources/macSCPCore/RemoteFS/LocalFileSystem.swift")

    /// A key a describing rendering prints and a localized description
    /// does not. Never a secret — this is a fixture, and what it proves is
    /// that the `userInfo` DUMP is gone, not that any particular value was
    /// redacted.
    private static let userInfoMarker = "ZZ-USERINFO-MARKER-ZZ"

    /// An error none of `map`'s arms recognise: a domain it does not read,
    /// carrying a description and a `userInfo` entry beside it.
    private static func unrecognisedError() -> NSError {
        NSError(
            domain: "test.localfilesystem", code: 42,
            userInfo: [
                NSLocalizedDescriptionKey: "The operation could not be completed.",
                NSFilePathErrorKey: userInfoMarker,
            ])
    }

    /// The one site a test can drive: the fallback at the end of `map`.
    @Test func anUnrecognisedErrorIsReducedToItsLocalizedDescription() throws {
        let error = Self.unrecognisedError()
        let mapped = LocalFileSystem.map(error, path: "/tmp/x")
        guard case RemoteFSError.protocolError(let reason) = mapped else {
            Issue.record("an unrecognised error is no longer a protocolError"); return
        }
        // Positive first: the reason IS the localized description.
        #expect(reason == error.localizedDescription)
        // Then the two things it must not be. Computed before the
        // expectation so neither the dump nor its spelling reaches a
        // failure message (`CLAUDE.md`, "two exits").
        let carriesTheUserInfoDump = reason.contains(Self.userInfoMarker)
        let describesTheError = reason == String(describing: error)
        #expect(carriesTheUserInfoDump == false)
        #expect(describesTheError == false)
    }

    /// The four throws above `map` that only a failing disk reaches — a
    /// seek past a closed handle, a read that faults, an append whose
    /// `seekToEnd` fails, a digest that cannot be streamed.
    ///
    /// The positive beside the negative is what keeps this from going stale:
    /// if the file stopped constructing these errors at all, the negative
    /// would match nothing and read exactly like a rule that is kept.
    @Test func noThrowInTheFileDescribesAnError() throws {
        let code = try SourceCorpus.code(of: Self.sourceFile)
        let withLiterals = try SourceCorpus.commentFree(of: Self.sourceFile)
        // Positive: the file still builds the errors this rule is about.
        #expect(
            code.contains("RemoteFSError.protocolError(reason:"),
            "LocalFileSystem no longer builds a protocolError — the scan below guards nothing")
        #expect(
            code.contains("error.localizedDescription"),
            "LocalFileSystem reduces no error to its localized description")
        for (label, body) in [("code", code), ("literals", withLiterals)] {
            #expect(!body.contains("String(describing:"), "\(label): an error is described")
            #expect(!body.contains("reason: \"\\(error"), "\(label): an error is interpolated")
        }
    }
}
