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
/// FIVE claims, counted 2026-09-10 against the `MARK` sections below. Every
/// negative check among them has a positive check beside it over the SAME
/// span (CLAUDE.md, "Guards that name what they watch": a `!contains` alone
/// starts matching nothing the moment the code it names moves, and reads
/// exactly like a check that is satisfied). Claim 1 is the exception in the
/// other direction — two positives and no negative — and its own doc comment
/// says why:
///
/// 1. The window presents the key-import sheet for a conversion at all.
/// 2. The sheet hands what came back to `convertedKeyImported(` and to the
///    tab CAPTURED when the button was pressed, never to whichever tab is
///    active at dismissal.
/// 3. Both conversion sites read the window's injected `managedKeyStore`
///    rather than building a `ManagedKeyStore(` of their own.
/// 4. The converted key reaches the stored session and the ONE dial path —
///    `updateSession(`, `dropSessionSecret(`, `retryConnect(`,
///    `dismissConnectFailure(` — after asking the two questions that decide
///    which path it takes (`hasStoredPassphrase(`, `loginSetID`), with the
///    drop INSIDE the branch the first question's positive answer opens and
///    nowhere else, and dials nothing itself.
/// 5. The import sheet converts on the way in instead of copying bytes.
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
        case probeNotFound, probeNotBound
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

    /// The `.sheet(item:)` whose closure claims 2 and 3 read. A code token
    /// (the binding `convertFailedKey(_:)` writes), so the blanked view the
    /// scanner searches carries it verbatim.
    private static let conversionSheetAnchor = ".sheet(item: $convertKeyTarget)"

    // MARK: - 2. The sheet applies the conversion to the tab it was opened for

    /// The positive half: the closure calls the handler, and hands it the
    /// tab the presentation item CARRIES.
    ///
    /// `convertedKeyImported(` is named here rather than only in claim 4
    /// because claim 4 reads the handler's own body — it is green for a
    /// perfectly wired handler nothing calls. Replacing the call in this
    /// closure with `_ = key` was measured (fix round 1, review finding I1)
    /// to turn no other check in this target red — the number that used to
    /// stand here (61) was reproducible by no counting rule (fix round 2,
    /// review finding LOW 5).
    ///
    /// `target.tab` is the capture: `ImportKeyTarget` carries the
    /// `SessionTab` taken when "Convert key…" was pressed, the same
    /// "capture now, not later" discipline `PresignedSheetItem` and
    /// `closeRequest` already follow.
    @Test func theConversionSheetAppliesTheKeyToTheTabItWasOpenedFor() throws {
        let closure = try Self.strippedBody(after: Self.conversionSheetAnchor, in: Self.sheetsFile)
        #expect(closure.contains("convertedKeyImported("), """
            the conversion sheet's closure no longer calls `convertedKeyImported(` — the \
            converted key is then created, added to the store and dropped on the floor: the \
            session still points at the PEM file and the tab stays on the failed surface.
            """)
        #expect(closure.contains("target.tab"), """
            the conversion sheet's closure no longer reads the tab off its presentation item \
            — the tab has to be the one that was failing when the button was pressed, not one \
            resolved while the sheet was open.
            """)
    }

    /// The negative half, pinned by the positive one above: the closure does
    /// not resolve `activeTab`.
    ///
    /// The defect this exists for (fix round 1, review finding C1): a
    /// `.sheet(item:)` closure runs at DISMISSAL, and ⌘1-9 switches tabs
    /// while a sheet is open — nothing gates it. Reading `activeTab` there
    /// rewrote and re-dialled whichever tab the person had switched to,
    /// persisting a key path into the wrong stored session
    /// (`updateSession`), while the tab that actually failed was never
    /// re-pointed.
    ///
    /// `editFailedSession(_:)` may read the active tab and this may not:
    /// that one resolves inside the button's own event, where "active" and
    /// "failing" are the same tab by construction.
    @Test func theConversionSheetDoesNotResolveTheTabAtDismissal() throws {
        let closure = try Self.strippedBody(after: Self.conversionSheetAnchor, in: Self.sheetsFile)
        #expect(!closure.contains("activeTab"), """
            the conversion sheet's closure resolves `activeTab` — which is read when the sheet \
            CLOSES, so a tab switch behind the open sheet applies the conversion to the wrong \
            tab: the wrong stored session is rewritten and re-dialled, and the failing one is \
            left pointing at the key that could not be read.
            """)
    }

    // MARK: - 3. Both sites use the window's injected key store

    /// `ContentView` is handed a `ManagedKeyStore` (`managedKeyStore`) for
    /// exactly this: its `init`'s own comment calls the parameter the seam
    /// that lets a `ContentView`-level test point the key store at a
    /// temporary directory instead of this machine's real one. A site that
    /// builds `ManagedKeyStore(directory: SessionStore.defaultDirectory)`
    /// inline is outside that seam and reaches the real directory whatever
    /// a test passes.
    ///
    /// Positive and negative over the same two spans, so neither half can go
    /// stale alone: the property is "this store, not a fresh one".
    @Test func bothConversionSitesUseTheWindowsInjectedKeyStore() throws {
        let closure = try Self.strippedBody(after: Self.conversionSheetAnchor, in: Self.sheetsFile)
        let body = try Self.strippedBody(after: "func convertedKeyImported(", in: Self.contentViewFile)
        #expect(closure.contains("managedKeyStore"), """
            the conversion sheet is no longer handed the window's `managedKeyStore` — a store \
            built at the sheet is outside `ContentView.init`'s injection seam.
            """)
        #expect(!closure.contains("ManagedKeyStore("), """
            the conversion sheet builds a `ManagedKeyStore(` of its own, bypassing the \
            `managedKeyStore` the window was given — the key then lands in the real key \
            directory even when a test pointed the window at a temporary one.
            """)
        #expect(body.contains("managedKeyStore"), """
            `convertedKeyImported(_:for:)` no longer reads the window's \
            `managedKeyStore` to resolve the new key's path.
            """)
        #expect(!body.contains("ManagedKeyStore("), """
            `convertedKeyImported(_:for:)` builds a `ManagedKeyStore(` of its \
            own — it would then resolve the path in a different store than the sheet just \
            wrote the key into.
            """)
    }

    // MARK: - 4. The converted key goes back through the real handlers

    /// The positive half: the handler persists the new key path on the
    /// stored session, drops the session's own passphrase slot and re-dials
    /// through `retryConnect(`, or hands an ad-hoc attempt back to the form
    /// through `dismissConnectFailure(`. SIX tokens are named individually
    /// (counted 2026-09-10 against the `#expect` calls in this function's
    /// body) because "the handler does something" is not the property — the
    /// property is that each of its paths ends in the function that already
    /// owns that action, and that the two facts it branches on are asked
    /// rather than assumed.
    ///
    /// `dropSessionSecret(` is the project's existing no-duplication rule
    /// applied to this new path (fix round 1, review finding I3): a session
    /// that uses a managed key with a stored passphrase carries no copy of
    /// its own, and a leftover copy does not merely duplicate the secret —
    /// `ManagedKeyPassphrase.resolve` answers the TYPED value first, so the
    /// session's stale copy shadows the managed key's real one on every
    /// dial.
    ///
    /// `hasStoredPassphrase(` is what makes that drop safe (fix round 2,
    /// review finding MEDIUM 1). The import sheet's `keptPassphrase` flag
    /// does NOT mean "a slot was written": it starts `true` and is only
    /// cleared when a SAVE throws, so an import with an EMPTY passphrase
    /// reports `true` having written no slot at all. Gating the drop on that
    /// flag deleted the session's own — and then only — copy of a passphrase
    /// the key's slot never received. This function only asks that the
    /// question is PRESENT; which branch of it the drop sits in is
    /// `theSlotDropSitsInsideTheBranchTheProbeOpens` below, and until that
    /// test existed the polarity was guarded by nothing (final whole-branch
    /// review, Critical 1).
    ///
    /// `loginSetID` is the second fact (fix round 2, review finding
    /// MEDIUM 2). A session bound to a login set takes its username, auth
    /// kind, key path AND — for private-key auth — its passphrase from the
    /// SET, not from itself: `LoginResolver.resolve` returns
    /// `SSHFieldSchema.values(from: set)` plus the set's Keychain secret,
    /// and `ConnectionViewModel.applyResolvedCredentials` blanks the whole
    /// credential block before merging them over the session's own values.
    /// Writing the converted path into such a session persists something no
    /// dial ever reads, and dropping the session's slot leaves the set's
    /// shadowing copy untouched.
    @Test func theConvertedKeyIsWiredThroughTheRealHandlers() throws {
        let body = try Self.strippedBody(after: "func convertedKeyImported(", in: Self.contentViewFile)
        #expect(body.contains("updateSession("), """
            `convertedKeyImported(_:for:)` no longer calls `updateSession(` — \
            the converted key would then be written nowhere, and the next dial would read the \
            PEM file again.
            """)
        #expect(body.contains("dropSessionSecret("), """
            `convertedKeyImported(_:for:)` no longer calls \
            `dropSessionSecret(` — the session keeps its own copy of the passphrase beside \
            the managed key's slot, and because `ManagedKeyPassphrase.resolve` answers the \
            typed value first, that stale copy is what every later dial uses.
            """)
        #expect(body.contains("retryConnect("), """
            `convertedKeyImported(_:for:)` no longer calls `retryConnect(` — \
            that redials through the shared `connect(in:stored:)`, which is what keeps TOFU a \
            hard stop and the keychain and login-set rules applied.
            """)
        #expect(body.contains("dismissConnectFailure("), """
            `convertedKeyImported(_:for:)` no longer calls \
            `dismissConnectFailure(` — an \
            ad-hoc attempt has no stored session to redial, so returning it to the form with \
            the new key selected is its only way on, and without this it stays on the failed \
            surface.
            """)
        #expect(body.contains("hasStoredPassphrase("), """
            `convertedKeyImported(_:for:)` no longer asks \
            `ManagedKeyPassphrase.hasStoredPassphrase(` — the import sheet's `keptPassphrase` \
            flag is `true` for an import that wrote no slot (an empty passphrase never reaches \
            the Keychain), so a drop gated on it deletes the only copy there is. This is also \
            the token `theSlotDropSitsInsideTheBranchTheProbeOpens` reads the branch's \
            identifier from, and that test fails closed without it.
            """)
        #expect(body.contains("loginSetID"), """
            `convertedKeyImported(_:for:)` no longer reads `loginSetID` — a session whose \
            login comes from a SET resolves its key path and its passphrase from that set on \
            every fill, so writing the converted path into the session persists a value no \
            dial reads, and dropping the session's own slot leaves the set's shadowing copy \
            in place.
            """)
    }

    /// The POLARITY of that drop, which the token checks above cannot see.
    ///
    /// Measured in the final whole-branch review: planting
    /// `if !keySlotHoldsThePassphrase {` — the inversion that deletes the
    /// session's only copy of the passphrase in exactly the case where the
    /// key's slot holds none — left every App test in this target green. A
    /// check that the probe is asked before the drop is satisfied by the
    /// inverted branch too; the question is which branch the drop sits in.
    ///
    /// So this reads the structure instead of the offsets: the `if` whose
    /// condition names the probe's result POSITIVELY, its span found by the
    /// same brace-balancing helper `strippedBody` uses, and the drop
    /// required to be inside it and nowhere else in the handler. The two
    /// halves are the two ways the property breaks — an inverted (or
    /// missing) gate leaves no span to be inside, and a second drop beside
    /// the branch makes the gate decide nothing.
    ///
    /// The identifier is READ out of the body, never spelled here (CLAUDE.md,
    /// "Guards that name what they watch", rule 2): whatever
    /// `hasStoredPassphrase(`'s result is bound to is the name the branch has
    /// to test, and a rename of that local must not quietly turn this into a
    /// check about nothing. Both helpers throw rather than return an empty
    /// string when they cannot find what they name, so a handler that stops
    /// binding the probe at all is a loud failure here as well as in
    /// `theConvertedKeyIsWiredThroughTheRealHandlers` above.
    @Test func theSlotDropSitsInsideTheBranchTheProbeOpens() throws {
        let body = try Self.strippedBody(after: "func convertedKeyImported(", in: Self.contentViewFile)
        let identifier = try Self.probeResultIdentifier(inBlankedBody: body)
        let gate = Self.positiveGateSpan(on: identifier, inBlankedBody: body)
        let dropsInsideTheGate = gate.map { Self.occurrences(of: "dropSessionSecret(", in: $0) } ?? 0
        let dropsInTheBody = Self.occurrences(of: "dropSessionSecret(", in: body)
        #expect(dropsInsideTheGate >= 1, """
            `convertedKeyImported(_:for:)` does not call `dropSessionSecret(` inside the branch \
            that `\(identifier)` being TRUE opens — either the branch tests the probe's result \
            inverted (`!`, or `== false`), which drops the session's Keychain slot in exactly \
            the case where the managed key's slot holds no passphrase and the session's copy is \
            the only one there is, or the drop has moved out of that branch altogether.
            """)
        #expect(dropsInTheBody == dropsInsideTheGate, """
            `convertedKeyImported(_:for:)` calls `dropSessionSecret(` \(dropsInTheBody) times \
            but only \(dropsInsideTheGate) of those are inside the branch `\(identifier)` gates \
            — a drop outside it runs whatever the probe answered, so the gate decides nothing \
            and the session's own copy of the passphrase goes even when the key's slot never \
            received one.
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
            `convertedKeyImported(_:for:)` dials `CitadelFileSystem.connect` \
            itself — a second \
            dial site is a second place TOFU, the keychain and login-set rules, the plaintext \
            confirmation and the attempt-token lock can each be forgotten.
            """)
        #expect(!body.contains("connect(in:"), """
            `convertedKeyImported(_:for:)` calls `connect(in:` directly \
            instead of going \
            through `retryConnect(_:)` — which resolves the failed attempt's stored session \
            live, and is the guard against dialling a session deleted from another window \
            between the conversion and the redial.
            """)
    }

    // MARK: - 5. The import converts on the way in

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
    // Without these the five claims above could all pass by reading an
    // empty string: a scanner that cannot find its anchor, or one whose
    // body span stops early, makes every positive check red and every
    // negative check green. The positives failing loudly is the intended
    // half; the negatives are why the span itself is measured here.
    //
    // The branch scanner claim 4 added is measured the same way and for a
    // sharper reason: it reports a violation by finding NO span, so a
    // scanner that finds no span for the correct code and one that finds
    // none for the inverted code look identical from the check's side. The
    // fixtures below run it against both spellings of the inversion, against
    // a second drop written beside the branch, and against the shape the
    // real handler has.

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

    /// The anchor is searched in the BLANKED view, not the raw source (fix
    /// round 1, review finding M4): this suite's header claims every anchor
    /// here is a code token, and a raw search buys the first spelling of the
    /// anchor in the file whether it is code or a sentence about code. That
    /// is CLAUDE.md's "Source-scanning guards read comments too", applied to
    /// the anchor rather than to the checks.
    ///
    /// The fixture is the shape that actually happens: an older version of
    /// the handler kept in a comment above the real one. Anchoring there
    /// reads braces that belong to nothing.
    @Test func theBodyScannerDoesNotAnchorInAComment() throws {
        let source = """
            // func convertedKeyImported(_ key: ManagedKey, for tab: SessionTab) {
            //     the shape this handler had before the fix round
            // }
            func convertedKeyImported(_ key: ManagedKey, for tab: SessionTab) {
                dismissConnectFailure(tab)
            }
            """
        let body = try Self.strippedBody(after: "func convertedKeyImported(", in: source)
        #expect(body.contains("dismissConnectFailure(tab)"), """
            the scanner anchored on the commented-out signature instead of the real one — \
            every check above would then be reading a comment, which is the one thing \
            blanking exists to prevent.
            """)
    }

    @Test func theBodyScannerFailsClosedOnAMissingAnchor() {
        #expect(throws: ScanError.self) {
            try Self.strippedBody(after: "func convertedKeyImported(", in: "func other() {}")
        }
    }

    /// A handler in the shape the real one has, with the branch condition and
    /// an extra statement after that branch as the two knobs — the same two
    /// the probes turned in the source when this check was measured.
    private static func handlerFixture(gatedBy condition: String, tail: String = "") -> String {
        """
        func convertedKeyImported(_ key: ManagedKey, for tab: SessionTab) {
            if var updated = failedConnectTarget(for: tab), updated.loginSetID == nil {
                let keySlotHoldsThePassphrase = (try? ManagedKeyPassphrase.hasStoredPassphrase(
                    keyPath: path, store: managedKeyStore, secrets: secretStore)) == true
                if \(condition) {
                    sessionListViewModel.dropSessionSecret(for: updated.id)
                }
        \(tail)
                retryConnect(tab)
            }
        }
        """
    }

    @Test func theBranchScannerReadsTheGuardedDropOutOfTheRealShape() throws {
        let body = try Self.strippedBody(
            after: "func convertedKeyImported(",
            in: Self.handlerFixture(gatedBy: "keySlotHoldsThePassphrase"))
        let identifier = try Self.probeResultIdentifier(inBlankedBody: body)
        #expect(identifier == "keySlotHoldsThePassphrase")
        let gate = Self.positiveGateSpan(on: identifier, inBlankedBody: body)
        #expect(Self.occurrences(of: "dropSessionSecret(", in: gate ?? "") == 1, """
            the branch scanner cannot find the drop in a handler written exactly as the real \
            one is — the check over the source would then be red for the correct code, which \
            is the other way for a guard to be useless.
            """)
    }

    @Test("an inverted gate leaves no positive branch to be inside",
          arguments: ["!keySlotHoldsThePassphrase", "keySlotHoldsThePassphrase == false"])
    func theBranchScannerSeesAnInvertedGate(_ condition: String) throws {
        let body = try Self.strippedBody(
            after: "func convertedKeyImported(",
            in: Self.handlerFixture(gatedBy: condition))
        let identifier = try Self.probeResultIdentifier(inBlankedBody: body)
        let gate = Self.positiveGateSpan(on: identifier, inBlankedBody: body)
        #expect(gate == nil, """
            the branch scanner accepted an inverted gate as the branch a TRUE answer opens — \
            the check over the source would pass over exactly the violation it exists for.
            """)
    }

    @Test func theBranchScannerSeesADropOutsideTheGate() throws {
        let body = try Self.strippedBody(
            after: "func convertedKeyImported(",
            in: Self.handlerFixture(
                gatedBy: "keySlotHoldsThePassphrase",
                tail: "        sessionListViewModel.dropSessionSecret(for: updated.id)"))
        let identifier = try Self.probeResultIdentifier(inBlankedBody: body)
        let gate = Self.positiveGateSpan(on: identifier, inBlankedBody: body)
        let dropsInsideTheGate = gate.map { Self.occurrences(of: "dropSessionSecret(", in: $0) } ?? 0
        let dropsInTheBody = Self.occurrences(of: "dropSessionSecret(", in: body)
        #expect(dropsInsideTheGate == 1)
        #expect(dropsInTheBody == 2, """
            an unconditional second drop written beside the branch is invisible to the span — \
            the equality over the source would then compare two numbers that move together and \
            could not report the drop the gate does not decide.
            """)
    }

    @Test func theProbeReaderFailsClosedWhenNothingIsAsked() {
        #expect(throws: ScanError.self) {
            try Self.probeResultIdentifier(inBlankedBody: "func handler() { dropSessionSecret(id) }")
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
    /// The anchor is searched in the BLANKED view, not the raw source (fix
    /// round 1, review finding M4): every anchor this suite uses is a code
    /// token, and this suite's header says so — a raw search would buy the
    /// first SPELLING of the anchor in the file, comment or code, which is
    /// exactly the collision CLAUDE.md's "Source-scanning guards read
    /// comments too" describes. The two scanners this one copies search raw
    /// because THEIR anchors are `//` comments a global blanking deletes;
    /// none of these is.
    ///
    /// `blankingCommentsAndStrings` replaces characters in place rather than
    /// removing them, so offsets in the blanked view are the raw source's
    /// offsets and the span below is the same span either way.
    private static func strippedBody(after anchor: String, in source: String) throws -> String {
        let blanked = try SwiftSource.blankingCommentsAndStrings(source)
        guard let anchorRange = blanked.range(of: anchor) else { throw ScanError.anchorNotFound }
        let stripped = String(blanked[anchorRange.lowerBound...])
        guard let openBraceIndex = stripped.firstIndex(of: "{") else {
            throw ScanError.openBraceNotFound
        }
        let span = try balancedSpan(from: openBraceIndex, in: stripped)
        return String(stripped[stripped.startIndex..<openBraceIndex]) + span
    }

    /// Everything from the `{` at `openBrace` through the `}` that closes
    /// it. The brace balancing `strippedBody` has always done, lifted out so
    /// the branch scanner below runs the same one over an inner `if` rather
    /// than a second copy of it.
    ///
    /// Its input is a BLANKED view in both callers, which is what makes
    /// counting braces meaningful at all: a `{` inside a comment or a string
    /// literal would otherwise decide where a span ends.
    private static func balancedSpan(from openBrace: String.Index, in source: String) throws -> String {
        var depth = 0
        var index = openBrace
        while index < source.endIndex {
            let character = source[index]
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(source[openBrace...index])
                }
            }
            index = source.index(after: index)
        }
        throw ScanError.unbalancedBraces
    }

    private static func isIdentifierCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    private static func occurrences(of token: String, in source: String) -> Int {
        source.components(separatedBy: token).count - 1
    }

    /// The name the slot probe's answer is bound to, read out of `body`
    /// instead of spelled in this file (CLAUDE.md, "Guards that name what
    /// they watch", rule 2): the `let` whose right-hand side calls
    /// `hasStoredPassphrase(`.
    ///
    /// Throws rather than returning `nil` for either half — no probe, or a
    /// probe whose result is not bound to a name a branch could test — so a
    /// handler that stops asking the question is red here instead of turning
    /// the branch scanner into a search for an empty string.
    private static func probeResultIdentifier(inBlankedBody body: String) throws -> String {
        guard let call = body.range(of: "hasStoredPassphrase(") else { throw ScanError.probeNotFound }
        let beforeTheCall = body[body.startIndex..<call.lowerBound]
        guard let equals = beforeTheCall.range(of: "=", options: .backwards) else {
            throw ScanError.probeNotBound
        }
        let declaration = beforeTheCall[beforeTheCall.startIndex..<equals.lowerBound]
        guard let letKeyword = declaration.range(of: "let ", options: .backwards) else {
            throw ScanError.probeNotBound
        }
        let identifier = declaration[letKeyword.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard identifier.isEmpty == false, identifier.allSatisfy(isIdentifierCharacter) else {
            throw ScanError.probeNotBound
        }
        return identifier
    }

    /// The body of the first `if` in `body` whose condition names
    /// `identifier` POSITIVELY — `nil` when there is none.
    ///
    /// "Positively" is read three ways, all of them on the condition text
    /// between the `if` and its `{`: it does not begin with `!`, it does not
    /// carry `== false`, and the identifier itself is not preceded by `!`.
    /// Each is a spelling of the inversion that the review planted; a
    /// condition that carries none of them is the branch a TRUE answer
    /// opens.
    ///
    /// `nil` rather than a throw: "there is no positive branch" is the
    /// violation this scanner exists to report, and its caller says so in a
    /// sentence the offsets could not.
    private static func positiveGateSpan(on identifier: String, inBlankedBody body: String) -> String? {
        var searchStart = body.startIndex
        while let keyword = body.range(of: "if", range: searchStart..<body.endIndex) {
            searchStart = keyword.upperBound
            let startsAWord = keyword.lowerBound == body.startIndex
                || !isIdentifierCharacter(body[body.index(before: keyword.lowerBound)])
            let endsAWord = keyword.upperBound == body.endIndex
                || !isIdentifierCharacter(body[keyword.upperBound])
            guard startsAWord, endsAWord else { continue }
            guard let openBrace = body[keyword.upperBound...].firstIndex(of: "{") else { continue }
            let condition = String(body[keyword.upperBound..<openBrace])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let named = condition.range(of: identifier) else { continue }
            let negatedInPlace = named.lowerBound > condition.startIndex
                && condition[condition.index(before: named.lowerBound)] == "!"
            guard condition.hasPrefix("!") == false,
                  condition.contains("== false") == false,
                  negatedInPlace == false
            else { continue }
            return try? balancedSpan(from: openBrace, in: body)
        }
        return nil
    }
}
