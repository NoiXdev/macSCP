import Foundation
import MacSCPTestSupport
import Testing

/// Guards the wiring of the "Convert key…" remedy (PEM private keys plan,
/// Task 4) across the three files it spans: the sheet presentation in
/// `ContentView+Sheets.swift`, the handler in `ContentView.swift` that takes
/// the converted key back to the session, and `ImportKeySheet.performImport`
/// in `SSHKeysSheet.swift`, which is where a picked file becomes a managed
/// key at all.
///
/// Scanned rather than run, for the boundary the rest of this target's guards
/// name: nothing in this project renders SwiftUI, so no test can press the
/// button and watch what happens. Every read goes through
/// `SwiftSource.blankingCommentsAndStrings` first — a doc comment naming
/// `retryConnect(_:)` in prose is indistinguishable from a call to it
/// otherwise, which is CLAUDE.md's "Source-scanning guards read comments
/// too" and was measured on this very target. That also means every anchor
/// here is a CODE token: a string literal would have been blanked away with
/// the comments.
///
/// Three claims, each a positive check with its negative pinned beside it
/// (CLAUDE.md, "Guards that name what they watch": a `!contains` alone
/// starts matching nothing the moment the code it names moves, and reads
/// exactly like a check that is satisfied):
///
/// 1. The window presents the key-import sheet for a conversion at all.
/// 2. The converted key reaches the stored session and the ONE dial path —
///    `updateSession(`, `retryConnect(`, `dismissConnectFailure(` — and
///    dials nothing itself.
/// 3. The import sheet converts on the way in instead of copying bytes.
@Suite("Convert key wiring guard")
struct ConvertKeyWiringGuardTests {
    /// `#filePath` here is
    /// `<repoRoot>/Tests/macSCPAppKitTests/ConvertKeyWiringGuardTests.swift`;
    /// three `deletingLastPathComponent()` calls recover the repo root
    /// regardless of `swift test`'s working directory (same trick as
    /// `ConnectingAttemptWiringGuardTests`).
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let contentViewFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/ContentView.swift")
    private static let sheetsFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/ContentView+Sheets.swift")
    private static let keysSheetFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/SSHKeysSheet.swift")

    private enum ScanError: Error {
        case anchorNotFound, openBraceNotFound, unbalancedBraces
    }

    // MARK: - 1. The sheet is presented

    /// Both halves are positive, and deliberately: the presentation is the
    /// thing that either exists or does not, and a check that it is absent
    /// would be a check about nothing. `$convertKeyTarget` is the binding
    /// `convertFailedKey(_:)` writes, and `ImportKeySheet(` is the sheet it
    /// opens — either one alone would pass over a `.sheet(item:)` that
    /// presents something else, or over a construction of the sheet that no
    /// presenter ever reaches.
    @Test func theConversionSheetIsPresentedFromTheWindow() throws {
        let code = try Self.strictSource(of: Self.sheetsFile)
        #expect(code.contains(".sheet(item: $convertKeyTarget)"), """
            `ContentView+Sheets.swift` no longer presents `.sheet(item: $convertKeyTarget)` — \
            the failed-connect surface's "Convert key…" writes that binding and nothing else, \
            so without this presenter the button sets state no view reads.
            """)
        #expect(code.contains("ImportKeySheet("), """
            `ContentView+Sheets.swift` no longer constructs `ImportKeySheet(` — the conversion \
            has no other place to ask for the passphrase and the name, and the key manager's \
            own import is the one implementation of copy-convert-inspect.
            """)
    }

    // MARK: - 2. The converted key goes back through the real handlers

    /// The positive half: the handler persists the new key path on the
    /// stored session and re-dials through `retryConnect(`, or hands an
    /// ad-hoc attempt back to the form through `dismissConnectFailure(`.
    /// All three are named individually because "the handler does
    /// something" is not the property — the property is that each of its
    /// two paths ends in the function that already owns that action.
    @Test func theConvertedKeyIsWiredThroughTheRealHandlers() throws {
        let body = try Self.strippedBody(after: "func convertedKeyImported(", in: Self.contentViewFile)
        #expect(body.contains("updateSession("), """
            `convertedKeyImported(_:for:)` no longer calls `updateSession(` — the converted \
            key would then be written nowhere, and the next dial would read the PEM file \
            again.
            """)
        #expect(body.contains("retryConnect("), """
            `convertedKeyImported(_:for:)` no longer calls `retryConnect(` — the one function \
            that redials through the shared `connect(in:stored:)`, which is what keeps TOFU a \
            hard stop and the keychain and login-set rules applied.
            """)
        #expect(body.contains("dismissConnectFailure("), """
            `convertedKeyImported(_:for:)` no longer calls `dismissConnectFailure(` — an \
            ad-hoc attempt has no stored session to redial, so returning it to the form with \
            the new key selected is its only way on, and without this it stays on the failed \
            surface.
            """)
    }

    /// The negative half, pinned by the positive one above: the handler
    /// reaches a dial only THROUGH `retryConnect(`, never by opening one of
    /// its own. That is the property `ReconnectWiringGuardTests` holds for
    /// this surface's other buttons, restated for the one action that adds
    /// a new way onto it.
    ///
    /// Read as "not present outside a literal", which is what a negative
    /// check over the strict view can mean at all (see
    /// `SwiftSource.blankingCommentsAndStrings`' own doc comment). It is
    /// not a check standing on its own:
    /// `theConvertedKeyIsWiredThroughTheRealHandlers` above asserts the same
    /// body is found and carries the three calls, so a renamed or deleted
    /// `convertedKeyImported(` fails there loudly instead of turning this
    /// into a filter that matches nothing.
    @Test func theConversionHandlerDialsNothingItself() throws {
        let body = try Self.strippedBody(after: "func convertedKeyImported(", in: Self.contentViewFile)
        #expect(!body.contains("CitadelFileSystem.connect"), """
            `convertedKeyImported(_:for:)` dials `CitadelFileSystem.connect` itself — a second \
            dial site is a second place TOFU, the keychain and login-set rules, the plaintext \
            confirmation and the attempt-token lock can each be forgotten.
            """)
        #expect(!body.contains("connect(in:"), """
            `convertedKeyImported(_:for:)` calls `connect(in:` directly instead of going \
            through `retryConnect(_:)` — which resolves the failed attempt's stored session \
            live, and is the guard against dialling a session deleted from another window \
            between the conversion and the redial.
            """)
    }

    // MARK: - 3. The import converts on the way in

    /// The positive half: the import runs the converter. Since Task 4 a key
    /// enters the managed store in OpenSSH format or not at all — a PEM key
    /// copied byte for byte would connect (the reader handles it) but could
    /// never be exported, because `EmbeddedKeyPorter` requires the OpenSSH
    /// boundary.
    @Test func theImportSheetConvertsOnTheWayIn() throws {
        let body = try Self.strippedBody(after: "private func performImport(", in: Self.keysSheetFile)
        #expect(body.contains("SSHKeyConverter.copyAsOpenSSH("), """
            `ImportKeySheet.performImport()` no longer calls \
            `SSHKeyConverter.copyAsOpenSSH(` — the managed key store stops being homogeneous, \
            and a key imported in PEM format lands in it unexportable.
            """)
    }

    /// The negative half, pinned by the positive one above: the plain byte
    /// copy that used to do this job is gone. `copyAsOpenSSH` performs the
    /// copy itself, so a `copyItem(` left here is either a second copy
    /// racing the converter's destination check or the old order restored.
    ///
    /// Pinned rather than free-standing:
    /// `theImportSheetConvertsOnTheWayIn` asserts the same body is found and
    /// carries the converter call, so a renamed `performImport(` fails there
    /// rather than leaving this one matching an empty string.
    @Test func theImportSheetNoLongerCopiesTheFileItself() throws {
        let body = try Self.strippedBody(after: "private func performImport(", in: Self.keysSheetFile)
        #expect(!body.contains("copyItem("), """
            `ImportKeySheet.performImport()` copies the picked file itself again — the copy is \
            `SSHKeyConverter.copyAsOpenSSH`'s job, which also refuses an existing destination \
            and removes its own partial work on failure.
            """)
    }

    // MARK: - Scanner self-tests
    //
    // Without these the four claims above could all pass by reading an
    // empty string: a scanner that cannot find its anchor, or one whose
    // body span stops early, makes every positive check red and every
    // negative check green. The positives failing loudly is the intended
    // half; the negatives are why the span itself is measured here.

    @Test func theBodyScannerReadsToTheEndOfTheFunction() throws {
        let source = """
            func convertedKeyImported(_ key: ManagedKey, for tab: SessionTab) {
                guard let path = store.privateKeyURL(for: key) else { return }
                if let stored = failedConnectTarget(for: tab) {
                    sessionListViewModel.updateSession(updated, newSecret: nil)
                    retryConnect(tab)
                } else {
                    dismissConnectFailure(tab)
                }
            }

            func somethingElse() {
                connect(in: tab, stored: stored)
            }
            """
        let body = try Self.strippedBody(after: "func convertedKeyImported(", in: source)
        #expect(body.contains("updateSession("))
        #expect(body.contains("retryConnect(tab)"))
        #expect(body.contains("dismissConnectFailure(tab)"))
        #expect(!body.contains("connect(in:"), """
            the span ran past the function's closing brace and swallowed the next \
            declaration — every negative check above would then be reading code that is not \
            the handler's.
            """)
    }

    @Test func theBodyScannerSeesADialPlantedInsideTheFunction() throws {
        let source = """
            func convertedKeyImported(_ key: ManagedKey, for tab: SessionTab) {
                connect(in: tab, stored: stored)
            }
            """
        let body = try Self.strippedBody(after: "func convertedKeyImported(", in: source)
        #expect(body.contains("connect(in:"), """
            a dial written straight into the handler is invisible to the span — the negative \
            checks above would pass over exactly the violation they exist for.
            """)
    }

    @Test func theBodyScannerFailsClosedOnAMissingAnchor() {
        #expect(throws: ScanError.self) {
            try Self.strippedBody(after: "func convertedKeyImported(", in: "func other() {}")
        }
    }

    @Test func theScannedFilesAreTheOnesThisSuiteNames() throws {
        for file in [Self.contentViewFile, Self.sheetsFile, Self.keysSheetFile] {
            let code = try Self.strictSource(of: file)
            #expect(code.count > 1000, """
                \(file.lastPathComponent) read back as \(code.count) characters — this suite \
                is not scanning the file it names.
                """)
        }
    }

    // MARK: - Scanner

    private static func strictSource(of file: URL) throws -> String {
        try SwiftSource.blankingCommentsAndStrings(try String(contentsOf: file, encoding: .utf8))
    }

    private static func strippedBody(after anchor: String, in file: URL) throws -> String {
        try strippedBody(after: anchor, in: try String(contentsOf: file, encoding: .utf8))
    }

    /// Everything from the anchor through the balanced-brace close of the
    /// first `{` after it, comments and string literals blanked FIRST — the
    /// same scanner `ConnectingAttemptWiringGuardTests` and
    /// `ReconnectWiringGuardTests` use, and for the same two reasons: a
    /// brace inside a comment would otherwise decide where the body ends,
    /// and a sentence about a call would otherwise satisfy a check for the
    /// call. Throws rather than returning `nil` so a moved anchor is a loud
    /// failure, not an empty string that makes every negative check pass.
    ///
    /// The anchor is searched in the RAW source: it is a code token here, so
    /// searching the blanked view would work too, but the raw search keeps
    /// this scanner interchangeable with the two it copies, whose anchors
    /// are `//` comments a global blanking would delete.
    private static func strippedBody(after anchor: String, in source: String) throws -> String {
        guard let anchorRange = source.range(of: anchor) else { throw ScanError.anchorNotFound }
        let stripped = try SwiftSource.blankingCommentsAndStrings(
            String(source[anchorRange.lowerBound...]))
        guard let openBraceIndex = stripped.firstIndex(of: "{") else {
            throw ScanError.openBraceNotFound
        }
        var depth = 0
        var index = openBraceIndex
        while index < stripped.endIndex {
            let character = stripped[index]
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(stripped[stripped.startIndex...index])
                }
            }
            index = stripped.index(after: index)
        }
        throw ScanError.unbalancedBraces
    }
}
