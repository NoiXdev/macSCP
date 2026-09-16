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
/// NINE claims, counted 2026-09-16 against the `MARK` sections below. Every
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
///    `convertForThisAttemptOnly(` — after asking the two questions that
///    decide which path it takes (`hasStoredPassphrase(`, `loginSetID`), with
///    the drop INSIDE a branch that both the first question's positive
///    answer and `sessionServesAJumpHop(`'s negative answer open, and nowhere
///    else in the app target, and dials nothing itself.
/// 5. The import sheet converts on the way in instead of copying bytes.
/// 6. A session bound to a login set is ASKED whether to update the set
///    (`LoginSetRepointPlan.request(`, `setRepointRequest`) rather than
///    routed to the attempt-only path in silence.
/// 7. Updating the set re-reads it (`LoginSetRepointPlan.currentSet(`),
///    writes it through `saveLoginSet(`, drops the SET's slot only inside a
///    branch that `hasStoredPassphrase(`'s positive answer and
///    `setServesAJumpHop(`'s negative answer both open (and nowhere else in
///    the app target), and re-dials through
///    `retryConnect(` and nothing else — the drop and the re-dial both
///    after a `guard` that returns unless `saveLoginSet(` answered true
///    (technical backlog of 2026-09-16, Task 5).
/// 8. "This attempt only" hands the tab back to the form
///    (`dismissConnectFailure(`) and writes no set.
/// 9. The window presents that question as a `.confirmationDialog(` bound to
///    `setRepointRequest`, titled with the set's name as it stands now
///    (`LoginSetRepointPlan.currentName(`, never the captured `.set.name`),
///    opened only once the conversion sheet has closed
///    and disarmed when a new conversion starts, whose "Update login set"
///    button alone reaches claim 7 and whose cancel-role "This attempt only"
///    button alone reaches claim 8, whose `isPresented:` setter runs neither,
///    and whose text is catalog keys.
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
        case probeNotFound, probeNotBound, dialogNotFound
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
        #expect(code.contains(Self.conversionSheetPresenter), """
            `ContentView+Sheets.swift` no longer presents `.sheet(item: $convertKeyTarget` — \
            the failed-connect surface's "Convert key…" writes that binding and nothing else, \
            so without this presenter the button sets state no view reads.
            """)
        #expect(code.contains("ImportKeySheet("), """
            `ContentView+Sheets.swift` no longer constructs `ImportKeySheet(` — the conversion \
            has no other place to ask for the passphrase and the name, and the key manager's \
            own import is the one implementation of copy-convert-inspect.
            """)
    }

    /// The presenter claim 1 requires. A prefix, not the whole modifier:
    /// since claim 9 the sheet also takes an `onDismiss:` closure, which is
    /// the one place that may open the login-set question.
    private static let conversionSheetPresenter = ".sheet(item: $convertKeyTarget"

    /// Where the closure claims 2 and 3 read begins: the sheet's
    /// construction, whose trailing closure is what runs with the imported
    /// key. Anchored on the construction rather than on the presenter
    /// because `.sheet(item:onDismiss:content:)` puts the `onDismiss:`
    /// closure FIRST — the presenter's first `{` is no longer the content.
    /// A code token, so the blanked view the scanner searches carries it
    /// verbatim.
    private static let conversionSheetAnchor = "ImportKeySheet(fileURL:"

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
    /// through `convertForThisAttemptOnly(` (which claim 8 holds to
    /// `dismissConnectFailure(`). SEVEN tokens are named individually
    /// (counted 2026-09-10 against the `#expect` calls in this function's
    /// body; `sessionServesAJumpHop(` made it seven in Task 2 fix round 1,
    /// counted 2026-09-16) because "the handler does something" is not the
    /// property — the
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
        #expect(body.contains("convertForThisAttemptOnly("), """
            `convertedKeyImported(_:for:)` no longer calls \
            `convertForThisAttemptOnly(` — an \
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
        #expect(body.contains("sessionServesAJumpHop("), """
            `convertedKeyImported(_:for:)` no longer asks `sessionServesAJumpHop(` — a \
            session-mode jump through this session reads the session's own slot first, so \
            dropping that slot leaves every session that jumps through it depending on the \
            managed-key fallback alone. \
            This is also the token `theSlotDropSitsInsideTheBranchTheProbeOpens` reads the \
            jump check's identifier from.
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
    ///
    /// Since Task 2 fix round 1 the same `if` must also carry the NEGATED
    /// result of `sessionServesAJumpHop(`, read out of the body the same way:
    /// a jump hop reads the session's own slot first, so a drop the jump check
    /// does not also gate leaves the sessions that jump through this one
    /// depending on the managed-key fallback alone (kept as defence in depth
    /// since the technical backlog of 2026-09-16, Task 5).
    @Test func theSlotDropSitsInsideTheBranchTheProbeOpens() throws {
        let body = try Self.strippedBody(after: "func convertedKeyImported(", in: Self.contentViewFile)
        let identifier = try Self.probeResultIdentifier(inBlankedBody: body)
        let jumpHop = try Self.resultIdentifier(of: "sessionServesAJumpHop(", inBlankedBody: body)
        let gate = Self.positiveGateSpan(on: identifier, alsoRequiringNegated: jumpHop, inBlankedBody: body)
        let dropsInsideTheGate = gate.map { Self.occurrences(of: "dropSessionSecret(", in: $0) } ?? 0
        let dropsInTheBody = Self.occurrences(of: "dropSessionSecret(", in: body)
        #expect(dropsInsideTheGate >= 1, """
            `convertedKeyImported(_:for:)` does not call `dropSessionSecret(` inside a branch \
            that `\(identifier)` being TRUE and `\(jumpHop)` being FALSE open together — a drop \
            the jump check does not gate removes the slot every session that jumps through this \
            one reads first; or \
            the branch tests the probe's result \
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

    // MARK: - 6. A set-bound session is asked, not routed in silence

    /// Maintainer decision 1 of 2026-09-16: a conversion for a session whose
    /// login comes from a SET asks whether to update the set. Before it, the
    /// handler sent such a session down the attempt-only path without a
    /// word, and the next connect read the PEM file again.
    ///
    /// Both halves positive: the plan is consulted, and its answer reaches
    /// the state the dialog in claim 9 is bound to. Either alone passes over
    /// a handler that builds the request and drops it, or one that assigns
    /// the state from something the plan never decided.
    @Test func aSetBoundSessionIsAskedWhetherToUpdateTheSet() throws {
        let body = try Self.strippedBody(after: "func convertedKeyImported(", in: Self.contentViewFile)
        #expect(body.contains("LoginSetRepointPlan.request("), """
            `convertedKeyImported(_:for:)` no longer consults `LoginSetRepointPlan.request(` — \
            a session bound to a login set is then converted for one attempt without being \
            asked, and every later connect reads the set's PEM path again.
            """)
        #expect(body.contains("setRepointRequest ="), """
            `convertedKeyImported(_:for:)` no longer assigns `setRepointRequest` — the \
            login-set question is built and never presented.
            """)
    }

    // MARK: - 7. Updating the set

    /// The positive half: the set is written through the view model's own
    /// save, the slot question is asked, the set's slot drop exists, and the
    /// tab re-dials through the one function that does.
    ///
    /// `saveLoginSet(` with a nil secret keeps the set's slot as it is; the
    /// drop is the separate, gated step below — decision 2 of 2026-09-16
    /// applied to a set: one passphrase, one place.
    @Test func updatingTheSetGoesThroughTheRealHandlers() throws {
        let body = try Self.strippedBody(after: "func repointLoginSet(", in: Self.contentViewFile)
        #expect(body.contains("LoginSetRepointPlan.currentSet("), """
            `repointLoginSet(_:)` no longer re-reads the set through \
            `LoginSetRepointPlan.currentSet(` — the copy captured when the dialog opened is \
            saved instead, undoing an edit made meanwhile or re-creating a deleted set.
            """)
        #expect(body.contains("convertForThisAttemptOnly("), """
            `repointLoginSet(_:)` no longer falls back to `convertForThisAttemptOnly(` when the \
            set is gone or no longer a private-key set — the tab stays on the failed surface.
            """)
        #expect(body.contains("setServesAJumpHop("), """
            `repointLoginSet(_:)` no longer asks `setServesAJumpHop(` — a jump hop bound to the \
            set reads the set's slot first, so dropping it leaves every session that jumps with \
            this set depending on the managed-key fallback alone.
            """)
        #expect(body.contains("saveLoginSet("), """
            `repointLoginSet(_:)` no longer calls `saveLoginSet(` — the set keeps pointing at \
            the PEM file, and the redial fails the same way again.
            """)
        #expect(body.contains("hasStoredPassphrase("), """
            `repointLoginSet(_:)` no longer asks `ManagedKeyPassphrase.hasStoredPassphrase(` — \
            the set's slot would then be dropped (or kept) without knowing whether the managed \
            key's slot holds the passphrase. This is also the token \
            `theSetSlotDropSitsInsideTheBranchTheProbeOpens` reads the branch's identifier from.
            """)
        #expect(body.contains("dropLoginSetSecret("), """
            `repointLoginSet(_:)` no longer calls `dropLoginSetSecret(` — the set keeps its own \
            copy of the passphrase beside the managed key's, and the connect-time fill types \
            the set's copy first, so it shadows the key's on every dial.
            """)
        #expect(body.contains("retryConnect("), """
            `repointLoginSet(_:)` no longer calls `retryConnect(` — the set is updated and the \
            tab stays on the failed surface with nothing dialled.
            """)
    }

    /// The POLARITY of the set's slot drop — the same structural read
    /// `theSlotDropSitsInsideTheBranchTheProbeOpens` makes for the session's
    /// slot, over `repointLoginSet(_:)`'s body: the drop inside the branch a
    /// TRUE answer and a FALSE `setServesAJumpHop(` answer open together, and
    /// nowhere else.
    @Test func theSetSlotDropSitsInsideTheBranchTheProbeOpens() throws {
        let body = try Self.strippedBody(after: "func repointLoginSet(", in: Self.contentViewFile)
        let identifier = try Self.probeResultIdentifier(inBlankedBody: body)
        let jumpHop = try Self.resultIdentifier(of: "setServesAJumpHop(", inBlankedBody: body)
        let gate = Self.positiveGateSpan(on: identifier, alsoRequiringNegated: jumpHop, inBlankedBody: body)
        let dropsInsideTheGate = gate.map { Self.occurrences(of: "dropLoginSetSecret(", in: $0) } ?? 0
        let dropsInTheBody = Self.occurrences(of: "dropLoginSetSecret(", in: body)
        #expect(dropsInsideTheGate >= 1, """
            `repointLoginSet(_:)` does not call `dropLoginSetSecret(` inside a branch that \
            `\(identifier)` being TRUE and `\(jumpHop)` being FALSE open together — a drop the \
            jump check does not gate removes the slot every jump hop bound to the set reads \
            first; an inverted \
            probe gate drops the set's slot exactly \
            when the managed key's slot holds no passphrase and the set's copy is the only one.
            """)
        #expect(dropsInTheBody == dropsInsideTheGate, """
            `repointLoginSet(_:)` calls `dropLoginSetSecret(` \(dropsInTheBody) times but only \
            \(dropsInsideTheGate) of those are inside the branch `\(identifier)` gates — a drop \
            outside it runs whatever the probe answered.
            """)
    }

    /// Claims 4 and 7 across the whole app target (final review, probe 2):
    /// each slot drop is called exactly ONCE in `Sources/MacSCPAppKit`, and
    /// that one call is the one inside its gate.
    ///
    /// The two checks above count drops only inside the handler they read,
    /// so a `dropLoginSetSecret(for: request.set.id)` planted in
    /// `convertedKeyImported(_:for:)`'s set branch — before the question is
    /// even asked — left them green: it is outside `repointLoginSet(_:)`,
    /// where the set check looks, and it is not `dropSessionSecret(`, which
    /// is what the session check counts. Counting over the target closes
    /// that: one call in the target plus one call inside the gate leaves no
    /// room for a second anywhere.
    ///
    /// Read in the blanked view, so a comment naming either call does not
    /// count. The positive checks — each symbol is found in the target at
    /// all, and the walk read files — sit beside the counts: an exact count
    /// over a scan that read nothing would be red anyway, but it would say
    /// "0 calls" rather than "the scan is broken".
    @Test func eachSlotDropIsCalledOnceInTheTargetAndThatCallIsGated() throws {
        let files = try Self.appTargetFiles()
        #expect(files.count > 20, """
            the app target walk found \(files.count) Swift files under Sources/MacSCPAppKit — \
            this check is not reading the target.
            """)
        var target = ""
        for file in files { target += try Self.strictSource(of: file) + "\n" }

        let sessionBody = try Self.strippedBody(after: "func convertedKeyImported(", in: Self.contentViewFile)
        let sessionProbe = try Self.probeResultIdentifier(inBlankedBody: sessionBody)
        let sessionJump = try Self.resultIdentifier(of: "sessionServesAJumpHop(", inBlankedBody: sessionBody)
        let sessionGate = Self.positiveGateSpan(
            on: sessionProbe, alsoRequiringNegated: sessionJump, inBlankedBody: sessionBody)

        let setBody = try Self.strippedBody(after: "func repointLoginSet(", in: Self.contentViewFile)
        let setProbe = try Self.probeResultIdentifier(inBlankedBody: setBody)
        let setJump = try Self.resultIdentifier(of: "setServesAJumpHop(", inBlankedBody: setBody)
        let setGate = Self.positiveGateSpan(on: setProbe, alsoRequiringNegated: setJump, inBlankedBody: setBody)

        for (drop, gate) in [("dropSessionSecret(", sessionGate), ("dropLoginSetSecret(", setGate)] {
            let inTheTarget = Self.occurrences(of: drop, in: target)
            let inTheGate = gate.map { Self.occurrences(of: drop, in: $0) } ?? 0
            #expect(inTheTarget >= 1, """
                `\(drop)` is not called anywhere in Sources/MacSCPAppKit — the drop moved or was \
                renamed, and this check would count nothing.
                """)
            #expect(inTheTarget == 1, """
                `\(drop)` is called \(inTheTarget) times in Sources/MacSCPAppKit — a second call \
                drops the slot without the probe or the jump-hop check deciding it.
                """)
            #expect(inTheGate == 1, """
                `\(drop)` is called \(inTheGate) times inside the branch the slot probe and the \
                negated jump-hop check open together — the target's one call is not the gated one.
                """)
        }
    }

    /// The negative half, pinned by `retryConnect(` in
    /// `updatingTheSetGoesThroughTheRealHandlers` over the same body: the
    /// set update dials nothing itself.
    @Test func updatingTheSetDialsNothingItself() throws {
        let body = try Self.strippedBody(after: "func repointLoginSet(", in: Self.contentViewFile)
        #expect(!body.contains("CitadelFileSystem.connect"), """
            `repointLoginSet(_:)` dials `CitadelFileSystem.connect` itself — a second dial site \
            is a second place TOFU, the keychain and login-set rules can each be forgotten.
            """)
        #expect(!body.contains("connect(in:"), """
            `repointLoginSet(_:)` calls `connect(in:` directly instead of going through \
            `retryConnect(_:)`, which resolves the failed attempt's stored session live.
            """)
    }

    /// The save's answer gates everything after it (technical backlog of
    /// 2026-09-16, Task 5): a set whose new key path was never written must
    /// not lose its own slot, and must not be redialled against the old PEM
    /// path. `saveGateViolations(inBlankedBody:)` names what it reads; its
    /// positives — one save, at least one drop and one re-dial, all found —
    /// sit beside the negatives in the same list.
    @Test func updatingTheSetDropsAndRedialsOnlyAfterASuccessfulSave() throws {
        let body = try Self.strippedBody(after: "func repointLoginSet(", in: Self.contentViewFile)
        let violations = Self.saveGateViolations(inBlankedBody: body)
        #expect(violations.isEmpty, """
            `repointLoginSet(_:)` does not gate its drop and re-dial on the save's result: \
            \(violations)
            """)
    }

    // MARK: - 8. This attempt only

    /// Positive and negative over the same body: the attempt-only answer
    /// hands the tab back to the form with the converted key selected, and
    /// writes no login set — "no" to the question means the set stays as it
    /// stands.
    @Test func thisAttemptOnlyReturnsToTheFormAndWritesNoSet() throws {
        let body = try Self.strippedBody(after: "func convertForThisAttemptOnly(", in: Self.contentViewFile)
        #expect(body.contains("dismissConnectFailure("), """
            `convertForThisAttemptOnly` no longer calls `dismissConnectFailure(` — the tab stays \
            on the failed surface and the converted key it was handed is never offered.
            """)
        #expect(!body.contains("saveLoginSet("), """
            `convertForThisAttemptOnly` calls `saveLoginSet(` — answering "This attempt only" \
            rewrote the login set for every session that uses it.
            """)
    }

    // MARK: - 9. The question is presented

    /// The dialog bound to `setRepointRequest`: each button reaches its OWN
    /// claim, its presentation waits for the conversion sheet to close, and
    /// every text it shows comes from a catalog key.
    ///
    /// The wait is the conversion sheet's `onDismiss:` arming
    /// `setRepointDialogArmed`, which the dialog's binding reads. The import
    /// sheet calls its completion BEFORE it dismisses itself, and a
    /// presentation raised while a sheet is still up does not appear — the
    /// import-password sheet's `onDismiss:` in the same file says so for the
    /// conflict sheet (M19/T8).
    ///
    /// The pairing is per button (Task 2 fix round 1): a check over the whole
    /// buttons closure stayed green with the two actions swapped, which puts
    /// the shared-set rewrite on the cancel-role button — the one Escape
    /// presses. `dialogViolations(_:)` names what it checks.
    ///
    /// "Catalog keys only" is read in two views at the same offsets: in the
    /// strict view, every `Button(` and `Text(` and the dialog's title open
    /// straight into `L10n.string(` (optionally through `String(format:`);
    /// in the literal-keeping view, every `L10n.string(` names a key under
    /// `connection.convertKey.repoint.`. The first alone would pass a
    /// catalog lookup of some unrelated key; the second alone would pass a
    /// `Text` built from a literal beside a correct lookup.
    @Test func theQuestionIsAConfirmationDialogBoundToTheRequest() throws {
        let source = try String(contentsOf: Self.sheetsFile, encoding: .utf8)
        let dialog = try Self.dialog(boundTo: "setRepointRequest", in: source)
        let violations = Self.dialogViolations(dialog)
        #expect(violations.isEmpty, """
            the login-set question's buttons, setter or presentation are wired wrong: \
            \(violations)
            """)
        // The title names the set as it stands NOW (technical backlog of
        // 2026-09-16, Task 5): the positive names the plan's fresh read, the
        // negative the captured copy, over the same argument list.
        #expect(dialog.arguments.contains("LoginSetRepointPlan.currentName("), """
            the login-set question's title no longer reads `LoginSetRepointPlan.currentName(` \
            — a set renamed in another window while the question is open is asked about \
            under its old name and updated under its new one.
            """)
        #expect(!dialog.arguments.contains(".set.name"), """
            the login-set question's title reads the set name captured with the request \
            (`.set.name`) instead of the fresh read.
            """)
        #expect(dialog.arguments.contains("setRepointDialogArmed"), """
            the login-set question's presentation no longer waits for `setRepointDialogArmed` \
            — it is then raised while the conversion sheet is still up.
            """)
        // The span is the presenter through the close of its first closure,
        // which `.sheet(item:onDismiss:content:)` makes the `onDismiss:` one.
        // The ASSIGNMENT is required, not the name (final review, probe 1):
        // `setRepointDialogArmed = setRepointRequest == nil` carries the name
        // too, and arms the flag exactly when there is no question to ask.
        // Compared with every whitespace character removed on both sides, so
        // a reflow of the line does not read as a violation.
        let sheet = try Self.strippedBody(after: Self.conversionSheetPresenter, in: source)
        let armsOnARequest = Self.removingWhitespace(from: sheet)
            .contains(Self.removingWhitespace(from: Self.armingAssignment))
        #expect(armsOnARequest, """
            the conversion sheet's `onDismiss:` no longer assigns \
            `\(Self.armingAssignment)` — either the flag is never armed and the login-set \
            question is never presented, or it is armed on some other condition, and an \
            inverted one opens a dialog with no request behind it while a set-bound \
            conversion does nothing.
            """)
        #expect(dialog.unlocalizedTexts.isEmpty, """
            the login-set question shows text that does not open into `L10n.string(`: \
            \(dialog.unlocalizedTexts)
            """)
        #expect(dialog.textCount >= 4, """
            the login-set question's text scan found \(dialog.textCount) texts (title, two \
            buttons, message) — the scan is not reading the dialog.
            """)
        #expect(dialog.keys.count >= 4 && dialog.keys.allSatisfy {
            $0.hasPrefix("connection.convertKey.repoint.")
        }, """
            the login-set question reads catalog keys outside `connection.convertKey.repoint.`, \
            or fewer than four: \(dialog.keys)
            """)
    }

    /// Starting a conversion clears whatever the last one left behind (Task 2
    /// fix round 1): a request whose presentation was lost, or an armed flag
    /// no dialog consumed, would otherwise open the previous conversion's
    /// question when this sheet closes. Both positive — the clearing is a
    /// thing that must be present.
    @Test func startingAConversionDisarmsTheLastQuestion() throws {
        let body = try Self.strippedBody(after: "func convertFailedKey(", in: Self.contentViewFile)
        #expect(body.contains("convertKeyTarget = ImportKeyTarget("), """
            `convertFailedKey(_:)` no longer opens the conversion sheet — this check is not \
            reading the function that starts a conversion.
            """)
        #expect(body.contains("setRepointRequest = nil"), """
            `convertFailedKey(_:)` no longer clears `setRepointRequest` — a request left by an \
            earlier conversion is asked again when this one's sheet closes.
            """)
        #expect(body.contains("setRepointDialogArmed = false"), """
            `convertFailedKey(_:)` no longer disarms `setRepointDialogArmed` — a flag left armed \
            by an earlier conversion presents a question the moment a new request appears.
            """)
    }

    // MARK: - Scanner self-tests
    //
    // Without these the nine claims above could all pass by reading an
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
                let jumpHopReadsTheSlot = sessionListViewModel.sessionServesAJumpHop(updated.id)
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

    @Test func theBranchScannerReadsTheJumpGatedDropOutOfTheRealShape() throws {
        let body = try Self.strippedBody(
            after: "func convertedKeyImported(",
            in: Self.handlerFixture(gatedBy: "keySlotHoldsThePassphrase && !jumpHopReadsTheSlot"))
        let identifier = try Self.probeResultIdentifier(inBlankedBody: body)
        let jumpHop = try Self.resultIdentifier(of: "sessionServesAJumpHop(", inBlankedBody: body)
        #expect(jumpHop == "jumpHopReadsTheSlot")
        let gate = Self.positiveGateSpan(on: identifier, alsoRequiringNegated: jumpHop, inBlankedBody: body)
        #expect(Self.occurrences(of: "dropSessionSecret(", in: gate ?? "") == 1, """
            the branch scanner cannot find the drop in a handler gated on both questions the \
            way the real one is — the check over the source would be red for correct code.
            """)
    }

    @Test("a gate that skips or inverts the jump check leaves no branch to be inside",
          arguments: [
            "keySlotHoldsThePassphrase",
            "keySlotHoldsThePassphrase && jumpHopReadsTheSlot",
            "keySlotHoldsThePassphrase && !jumpHopReadsTheSlotElsewhere",
          ])
    func theBranchScannerSeesAGateThatSkipsTheJumpCheck(_ condition: String) throws {
        let body = try Self.strippedBody(
            after: "func convertedKeyImported(", in: Self.handlerFixture(gatedBy: condition))
        let identifier = try Self.probeResultIdentifier(inBlankedBody: body)
        let jumpHop = try Self.resultIdentifier(of: "sessionServesAJumpHop(", inBlankedBody: body)
        let gate = Self.positiveGateSpan(on: identifier, alsoRequiringNegated: jumpHop, inBlankedBody: body)
        #expect(gate == nil, """
            the branch scanner accepted `\(condition)` as gated on the jump check — the check \
            over the source would pass a drop of the slot every jump through the session reads \
            first.
            """)
    }

    @Test func theProbeReaderFailsClosedWhenNothingIsAsked() {
        #expect(throws: ScanError.self) {
            try Self.probeResultIdentifier(inBlankedBody: "func handler() { dropSessionSecret(id) }")
        }
    }

    /// A window with three dialogs, the second bound to the request, and the
    /// bound one's message, button actions and setter as knobs — the shape
    /// `theQuestionIsAConfirmationDialogBoundToTheRequest` reads.
    private static func dialogFixture(
        message: String = "Text(String(format: L10n.string(\"connection.convertKey.repoint.message %lld %@\", \"N\"), request.usageCount, request.key.name))",
        confirmAction: String = "repointLoginSet(request)",
        attemptAction: String = "convertForThisAttemptOnly(request.tab, keyPath: request.keyPath)",
        setter: String = "if !isPresented { setRepointRequest = nil; setRepointDialogArmed = false }",
        extraButton: String = ""
    ) -> String {
        """
        func sheets() -> some View {
            content
            .confirmationDialog(
                L10n.string("tabs.close.title", "Close tab?"),
                isPresented: Binding(get: { closeRequest != nil }, set: { _ in }),
                titleVisibility: .visible
            ) {
                Button(L10n.string("tabs.close.confirm", "Close")) { performClose() }
            } message: {
                Text(closeWarningText)
            }
            .confirmationDialog(
                String(
                    format: L10n.string("connection.convertKey.repoint.title %@", "Update?"),
                    setRepointRequest?.set.name ?? ""),
                isPresented: Binding(
                    get: { setRepointDialogArmed && setRepointRequest != nil },
                    set: { isPresented in \(setter) }),
                titleVisibility: .visible,
                presenting: setRepointRequest
            ) { request in
                Button(L10n.string("connection.convertKey.repoint.confirm", "Update")) {
                    \(confirmAction)
                }
                Button(L10n.string("connection.convertKey.repoint.thisAttempt", "Only"), role: .cancel) {
                    \(attemptAction)
                }
                \(extraButton)
            } message: { request in
                \(message)
            }
            .confirmationDialog(
                L10n.string("tabs.alreadyOpen.title", "Open?"),
                isPresented: .constant(false)
            ) {
                Button(L10n.string("tabs.alreadyOpen.jump", "Go")) { startWithoutAsking() }
            } message: {
                Text(alreadyOpenMessage)
            }
        }
        """
    }

    @Test func theDialogScannerReadsTheBoundDialogAndOnlyIt() throws {
        let dialog = try Self.dialog(boundTo: "setRepointRequest", in: Self.dialogFixture())
        #expect(Self.dialogViolations(dialog).isEmpty, "\(Self.dialogViolations(dialog))")
        #expect(dialog.arguments.contains("setRepointDialogArmed"))
        #expect(dialog.unlocalizedTexts.isEmpty, "\(dialog.unlocalizedTexts)")
        #expect(dialog.textCount == 4)
        #expect(dialog.keys == [
            "connection.convertKey.repoint.title %@",
            "connection.convertKey.repoint.confirm",
            "connection.convertKey.repoint.thisAttempt",
            "connection.convertKey.repoint.message %lld %@",
        ])
        #expect(dialog.buttonSpans.map(\.key) == [
            "connection.convertKey.repoint.confirm", "connection.convertKey.repoint.thisAttempt",
        ])
        #expect(!dialog.buttons.contains("performClose(") && !dialog.buttons.contains("startWithoutAsking("), """
            the dialog span reached into a neighbouring dialog — the bound dialog's checks would \
            then read another dialog's buttons.
            """)
    }

    /// The swap the review planted: each action on the other button. A check
    /// over the whole buttons closure cannot see it; the per-button pairing
    /// must.
    @Test func theDialogScannerSeesSwappedActions() throws {
        let dialog = try Self.dialog(
            boundTo: "setRepointRequest",
            in: Self.dialogFixture(
                confirmAction: "convertForThisAttemptOnly(request.tab, keyPath: request.keyPath)",
                attemptAction: "repointLoginSet(request)"))
        #expect(Self.dialogViolations(dialog).isEmpty == false, """
            swapping the two buttons' actions passed the pairing — Escape would then rewrite \
            the shared login set.
            """)
    }

    /// The review's third button (Task 2 fix round 2): a check that looks
    /// only at the two buttons it knows by key passes a third that reaches
    /// the shared-set rewrite under a key of its own.
    @Test("a third button is reported, whatever it calls",
          arguments: [
            "Button(L10n.string(\"connection.convertKey.repoint.extra\", \"Extra\")) { repointLoginSet(request) }",
            "Button(L10n.string(\"connection.convertKey.repoint.extra\", \"Extra\")) { dismissConnectFailure(request.tab) }",
          ])
    func theDialogScannerSeesAThirdButton(_ extraButton: String) throws {
        let dialog = try Self.dialog(
            boundTo: "setRepointRequest", in: Self.dialogFixture(extraButton: extraButton))
        #expect(dialog.buttonSpans.count == 3, "the scan did not read the third button")
        #expect(Self.dialogViolations(dialog).isEmpty == false, """
            a third button in the login-set question passed the pairing — the dialog's button \
            set is not bounded, so an extra way to rewrite the shared set goes unseen.
            """)
    }

    @Test("a handler in the setter is reported",
          arguments: [
            "if !isPresented { setRepointRequest = nil; repointLoginSet(setRepointRequest!) }",
            "if !isPresented { setRepointRequest = nil; convertForThisAttemptOnly(t, keyPath: p) }",
          ])
    func theDialogScannerSeesAHandlerInTheSetter(_ setter: String) throws {
        let dialog = try Self.dialog(boundTo: "setRepointRequest", in: Self.dialogFixture(setter: setter))
        #expect(Self.dialogViolations(dialog).isEmpty == false, """
            a handler run from the `isPresented:` setter passed — the setter must only clear state.
            """)
    }

    @Test("a text that is not a catalog lookup is reported",
          arguments: ["Text(\"Update the set?\")", "Text(request.set.name)"])
    func theDialogScannerSeesAnUnlocalizedText(_ message: String) throws {
        let dialog = try Self.dialog(boundTo: "setRepointRequest", in: Self.dialogFixture(message: message))
        #expect(dialog.unlocalizedTexts.count == 1, """
            a `Text` that does not open into `L10n.string(` passed the dialog scan — the \
            "catalog keys only" check over the source would pass over exactly that.
            """)
    }

    @Test func theDialogScannerFailsClosedWhenNoDialogIsBound() {
        #expect(throws: ScanError.self) {
            try Self.dialog(boundTo: "setRepointRequest", in: Self.dialogFixture()
                .replacingOccurrences(of: "setRepointRequest", with: "otherRequest"))
        }
    }

    /// `repointLoginSet(_:)`'s shape since Task 5 of the technical backlog,
    /// with the save line and the tail replaceable, for the save-gate
    /// scanner's own measurements.
    private static func repointFixture(
        save: String = "guard sessionListViewModel.saveLoginSet(set, secret: nil) else { return }",
        tail: String = ""
    ) -> String {
        """
        func repointLoginSet(_ request: LoginSetRepointRequest) {
            guard var set = LoginSetRepointPlan.currentSet(
                id: request.set.id, in: sessionListViewModel.loginSets)
            else {
                convertForThisAttemptOnly(request.tab, keyPath: request.keyPath)
                return
            }
            set.keyPath = request.keyPath
            \(save)
            let keySlotHoldsThePassphrase = probe()
            let jumpHopReadsTheSetSlot = sessionListViewModel.setServesAJumpHop(set.id)
            if keySlotHoldsThePassphrase && !jumpHopReadsTheSetSlot {
                sessionListViewModel.dropLoginSetSecret(for: set.id)
            }
            retryConnect(request.tab)
            \(tail)
        }
        """
    }

    @Test func theSaveGateScannerAcceptsTheRealShape() throws {
        let body = try Self.strippedBody(after: "func repointLoginSet(", in: Self.repointFixture())
        #expect(Self.saveGateViolations(inBlankedBody: body).isEmpty)
    }

    @Test("a save the gate does not read, or reads inverted, is reported", arguments: [
        "sessionListViewModel.saveLoginSet(set, secret: nil)",
        "_ = sessionListViewModel.saveLoginSet(set, secret: nil)",
        "guard !sessionListViewModel.saveLoginSet(set, secret: nil) else { return }",
        "guard sessionListViewModel.saveLoginSet(set, secret: nil) == false else { return }",
        "guard sessionListViewModel.saveLoginSet(set, secret: nil) else { print(set) }",
        "guard sessionListViewModel.saveLoginSet(set, secret: nil) != true else { return }",
        "guard canWrite, !sessionListViewModel.saveLoginSet(set, secret: nil) else { return }",
    ])
    func theSaveGateScannerReportsAnUngatedSave(save: String) throws {
        let body = try Self.strippedBody(after: "func repointLoginSet(", in: Self.repointFixture(save: save))
        #expect(Self.saveGateViolations(inBlankedBody: body).isEmpty == false, """
            the save-gate scanner accepted `\(save)` — the check over the source would pass a \
            drop and a re-dial that run whatever the save answered.
            """)
    }

    @Test func theSaveGateScannerSeesADropOrARedialBeforeTheGate() throws {
        for early in [
            "sessionListViewModel.dropLoginSetSecret(for: set.id)",
            "retryConnect(request.tab)",
        ] {
            let save = early + "\n    guard sessionListViewModel.saveLoginSet(set, secret: nil) else { return }"
            let body = try Self.strippedBody(after: "func repointLoginSet(", in: Self.repointFixture(save: save))
            #expect(Self.saveGateViolations(inBlankedBody: body).isEmpty == false, """
                the save-gate scanner accepted `\(early)` written before the gate.
                """)
        }
    }

    @Test func theSaveGateScannerSeesASecondSave() throws {
        let body = try Self.strippedBody(
            after: "func repointLoginSet(",
            in: Self.repointFixture(tail: "sessionListViewModel.saveLoginSet(set, secret: nil)"))
        #expect(Self.saveGateViolations(inBlankedBody: body).isEmpty == false)
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

    /// Every Swift file under `Sources/MacSCPAppKit`, sorted — the whole
    /// target, so the target-wide count reads no list somebody maintains.
    private static func appTargetFiles() throws -> [URL] {
        let root = repoRoot.appendingPathComponent("Sources/MacSCPAppKit")
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        else { throw ScanError.anchorNotFound }
        return walker.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.path < $1.path }
    }

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

    /// What the conversion sheet's `onDismiss:` must assign, as code. Kept
    /// here as the one spelling both the check and its message read.
    private static let armingAssignment = "setRepointDialogArmed = setRepointRequest != nil"

    /// `text` with every whitespace character removed — the normalisation
    /// the arming check compares under, applied to both of its sides.
    private static func removingWhitespace(from text: String) -> String {
        String(text.filter { !$0.isWhitespace })
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
        try resultIdentifier(of: "hasStoredPassphrase(", inBlankedBody: body)
    }

    /// The name the first call to `call` in `body` is bound to by a `let` —
    /// the reader `probeResultIdentifier` has always been, for any call. Used
    /// for the jump-hop checks (Task 2 fix round 1), with the same throws.
    private static func resultIdentifier(of callToken: String, inBlankedBody body: String) throws -> String {
        guard let call = body.range(of: callToken) else { throw ScanError.probeNotFound }
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
    ///
    /// With `jumpHop` (Task 2 fix round 1) the condition must ALSO carry
    /// `!jumpHop` as a whole word — the drop is allowed only when no jump hop
    /// reads the slot. A condition naming `jumpHop` without the `!`, or not
    /// at all, is not the branch. The probe has to be written first: the
    /// `hasPrefix("!")` rule above reads a condition that opens with `!` as
    /// an inverted probe.
    private static func positiveGateSpan(
        on identifier: String, alsoRequiringNegated jumpHop: String? = nil, inBlankedBody body: String
    ) -> String? {
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
            if let jumpHop {
                guard let negated = condition.range(of: "!" + jumpHop) else { continue }
                let endsTheWord = negated.upperBound == condition.endIndex
                    || !isIdentifierCharacter(condition[negated.upperBound])
                guard endsTheWord else { continue }
            }
            return try? balancedSpan(from: openBrace, in: body)
        }
        return nil
    }

    /// What is wrong with `body`'s save gate, as sentences — empty when the
    /// shape claim 7 requires is there (technical backlog of 2026-09-16,
    /// Task 5).
    ///
    /// The gate is a `guard` whose whole condition is the `saveLoginSet(`
    /// call (`isExactlyTheSaveCall`) — nothing negating, comparing or
    /// joining it — and whose `else` block contains a `return`. Everything else is measured against
    /// where that block ends: every `dropLoginSetSecret(` and every
    /// `retryConnect(` in the body must start after it. The positives sit in
    /// the same list: exactly one `saveLoginSet(` (a second, ungated save
    /// would write around the gate), and at least one drop and one re-dial —
    /// without those, "every drop is after the gate" is true of nothing.
    private static func saveGateViolations(inBlankedBody body: String) -> [String] {
        var violations: [String] = []
        let saves = occurrences(of: "saveLoginSet(", in: body)
        let drops = occurrences(of: "dropLoginSetSecret(", in: body)
        let redials = occurrences(of: "retryConnect(", in: body)
        if saves != 1 { violations.append("`saveLoginSet(` is called \(saves) times, not once") }
        if drops < 1 { violations.append("no `dropLoginSetSecret(` found — the scan reads nothing") }
        if redials < 1 { violations.append("no `retryConnect(` found — the scan reads nothing") }
        guard let gateEnd = saveGateEnd(inBlankedBody: body) else {
            violations.append(
                "no `guard` returns unless `saveLoginSet(` answered true")
            return violations
        }
        for token in ["dropLoginSetSecret(", "retryConnect("] {
            let total = occurrences(of: token, in: body)
            let after = occurrences(of: token, in: String(body[gateEnd...]))
            if after != total {
                violations.append("\(total - after) of \(total) `\(token)` run before the save gate")
            }
        }
        return violations
    }

    /// Where the first positive save gate in `body` ends — the index just
    /// past its `else` block — or `nil` when there is none.
    private static func saveGateEnd(inBlankedBody body: String) -> String.Index? {
        var searchStart = body.startIndex
        while let keyword = body.range(of: "guard", range: searchStart..<body.endIndex) {
            searchStart = keyword.upperBound
            let startsAWord = keyword.lowerBound == body.startIndex
                || !isIdentifierCharacter(body[body.index(before: keyword.lowerBound)])
            let endsAWord = keyword.upperBound == body.endIndex
                || !isIdentifierCharacter(body[keyword.upperBound])
            guard startsAWord, endsAWord else { continue }
            guard let elseKeyword = body.range(of: "else", range: keyword.upperBound..<body.endIndex)
            else { return nil }
            let condition = String(body[keyword.upperBound..<elseKeyword.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard condition.contains("saveLoginSet("), isExactlyTheSaveCall(condition) else { continue }
            guard let openBrace = body[elseKeyword.upperBound...].firstIndex(of: "{"),
                  let elseBlock = try? balancedSpan(from: openBrace, in: body),
                  elseBlock.contains("return")
            else { continue }
            return body.index(openBrace, offsetBy: elseBlock.count)
        }
        return nil
    }

    /// Whether a blanked `guard` condition is EXACTLY one `saveLoginSet(` call
    /// expression — an optional receiver chain of identifiers and dots, the
    /// call, and its balanced argument list ending the condition (fix round 1
    /// of the technical backlog's Task 5). Anything else is refused as a
    /// whole: a `!` before it, a comparison after it (`== false`, `!= true`),
    /// or a second clause beside it (`guard canWrite, !…`) — a list of
    /// forbidden spellings would keep missing the next one.
    private static func isExactlyTheSaveCall(_ condition: String) -> Bool {
        guard let call = condition.range(of: "saveLoginSet(") else { return false }
        let receiver = condition[condition.startIndex..<call.lowerBound]
        guard receiver.allSatisfy({ isIdentifierCharacter($0) || $0 == "." }) else { return false }
        var depth = 0
        var index = condition.index(before: call.upperBound)
        while index < condition.endIndex {
            if condition[index] == "(" { depth += 1 }
            if condition[index] == ")" {
                depth -= 1
                if depth == 0 { return condition.index(after: index) == condition.endIndex }
            }
            index = condition.index(after: index)
        }
        return false
    }

    /// One `.confirmationDialog(` read out of a source file.
    private struct Dialog {
        /// The parenthesised argument list, strict view.
        let arguments: String
        /// The buttons closure, strict view.
        let buttons: String
        /// The `message:` closure, strict view.
        let message: String
        /// Every title, `Button(` or `Text(` in the dialog that does not open
        /// straight into `L10n.string(` (directly or through
        /// `String(format:`), as the strict text it opens into.
        let unlocalizedTexts: [String]
        /// How many texts were checked: the title plus every `Button(` and
        /// `Text(`.
        let textCount: Int
        /// Every key literal an `L10n.string(` in the dialog names, in order.
        let keys: [String]
        /// The `isPresented:` binding's `set:` closure, strict view.
        let setter: String
        /// Each `Button(` in the buttons closure, in order.
        let buttonSpans: [ButtonSpan]
    }

    /// One `Button(` of a dialog: the catalog key its label names, read from
    /// the comment-only view, beside its argument list and trailing action,
    /// read from the strict view — at the same offsets, which is what pairs
    /// a key with its action.
    private struct ButtonSpan {
        let key: String?
        let arguments: String
        let action: String
    }

    /// Everything the login-set question's wiring must satisfy, one sentence
    /// per broken property (Task 2 fix round 1). Empty means wired right.
    ///
    /// Each button's action must reach its own handler and NOT the other's;
    /// the cancel role must sit on "This attempt only" (Escape presses the
    /// cancel button) and not on "Update login set"; the setter must clear
    /// the request and run neither handler; and the request must reach the
    /// buttons through `presenting:`.
    ///
    /// The button SET is bounded too (Task 2 fix round 2): exactly two
    /// `Button(` spans, whose keys are exactly the two above, and
    /// `repointLoginSet(` exactly once in the whole buttons closure. Checking
    /// only the buttons named by key passed a third button with a key of its
    /// own that called the set rewrite.
    private static func dialogViolations(_ dialog: Dialog) -> [String] {
        var violations: [String] = []
        let confirm = dialog.buttonSpans.filter { $0.key == "connection.convertKey.repoint.confirm" }
        let attempt = dialog.buttonSpans.filter { $0.key == "connection.convertKey.repoint.thisAttempt" }
        let expectedKeys: Set<String?> = [
            "connection.convertKey.repoint.confirm", "connection.convertKey.repoint.thisAttempt",
        ]
        if dialog.buttonSpans.count != 2 {
            violations.append("\(dialog.buttonSpans.count) buttons, not 2")
        }
        if Set(dialog.buttonSpans.map(\.key)) != expectedKeys {
            violations.append("button keys \(dialog.buttonSpans.map(\.key)) are not exactly confirm and thisAttempt")
        }
        let rewrites = occurrences(of: "repointLoginSet(", in: dialog.buttons)
        if rewrites != 1 {
            violations.append("repointLoginSet( occurs \(rewrites) times in the buttons closure, not once")
        }
        if confirm.count != 1 { violations.append("\(confirm.count) Update-login-set buttons") }
        if attempt.count != 1 { violations.append("\(attempt.count) This-attempt-only buttons") }
        for button in confirm {
            if !button.action.contains("repointLoginSet(") {
                violations.append("Update login set does not call repointLoginSet(")
            }
            if button.action.contains("convertForThisAttemptOnly(") {
                violations.append("Update login set calls convertForThisAttemptOnly(")
            }
            if button.arguments.contains(".cancel") {
                violations.append("Update login set carries the cancel role")
            }
        }
        for button in attempt {
            if !button.action.contains("convertForThisAttemptOnly(") {
                violations.append("This attempt only does not call convertForThisAttemptOnly(")
            }
            if button.action.contains("repointLoginSet(") {
                violations.append("This attempt only calls repointLoginSet(")
            }
            if !button.arguments.contains(".cancel") {
                violations.append("This attempt only does not carry the cancel role")
            }
        }
        if !dialog.setter.contains("setRepointRequest = nil") {
            violations.append("the setter does not clear setRepointRequest")
        }
        if dialog.setter.contains("repointLoginSet(") {
            violations.append("the setter calls repointLoginSet(")
        }
        if dialog.setter.contains("convertForThisAttemptOnly(") {
            violations.append("the setter calls convertForThisAttemptOnly(")
        }
        if !dialog.arguments.contains("presenting:") {
            violations.append("the request does not reach the buttons through presenting:")
        }
        return violations
    }

    /// The first `.confirmationDialog(` whose ARGUMENT LIST names `state`,
    /// with its buttons and `message:` closures, read in the strict view for
    /// code and in the comment-only view for key literals.
    ///
    /// Both views blank in place, so one offset addresses the same character
    /// in each (`SwiftSource`'s own doc comment); the spans are balanced in
    /// the strict view, where a brace or parenthesis inside a literal cannot
    /// decide where they end. Throws when no dialog names `state` or when
    /// the dialog's shape cannot be read, so a moved dialog is a loud
    /// failure rather than an empty span that satisfies every negative.
    private static func dialog(boundTo state: String, in source: String) throws -> Dialog {
        let strict = Array(try SwiftSource.blankingCommentsAndStrings(source))
        let literal = Array(try SwiftSource.blankingComments(source))
        guard strict.count == literal.count else { throw ScanError.dialogNotFound }
        let opener = Array(".confirmationDialog(")
        var start = 0
        while let found = firstOffset(of: opener, in: strict, from: start) {
            start = found + opener.count
            let parenOpen = found + opener.count - 1
            guard let parenClose = closingOffset(from: parenOpen, in: strict, open: "(", close: ")")
            else { throw ScanError.unbalancedBraces }
            let arguments = String(strict[parenOpen...parenClose])
            guard arguments.contains(state) else { continue }
            guard let buttonsOpen = firstOffset(of: ["{"], in: strict, from: parenClose),
                  let buttonsClose = closingOffset(from: buttonsOpen, in: strict, open: "{", close: "}"),
                  let label = firstOffset(of: Array("message:"), in: strict, from: buttonsClose),
                  let messageOpen = firstOffset(of: ["{"], in: strict, from: label),
                  let messageClose = closingOffset(from: messageOpen, in: strict, open: "{", close: "}")
            else { throw ScanError.dialogNotFound }

            var textStarts = [parenOpen + 1]
            for token in [Array("Button("), Array("Text(")] {
                var from = parenOpen
                while let hit = firstOffset(of: token, in: strict, from: from), hit < messageClose {
                    textStarts.append(hit + token.count)
                    from = hit + token.count
                }
            }
            let unlocalized = textStarts.compactMap { offset -> String? in
                let window = String(strict[offset..<min(offset + 120, strict.count)])
                    .filter { !$0.isWhitespace }
                let localized = window.hasPrefix("L10n.string(")
                    || window.hasPrefix("String(format:L10n.string(")
                return localized ? nil : String(window.prefix(40))
            }
            guard let setLabel = firstOffset(of: Array("set:"), in: strict, from: parenOpen),
                  setLabel < parenClose,
                  let setterOpen = firstOffset(of: ["{"], in: strict, from: setLabel),
                  let setterClose = closingOffset(from: setterOpen, in: strict, open: "{", close: "}"),
                  setterClose < parenClose
            else { throw ScanError.dialogNotFound }

            // Offsets pair the two views: both blank in place, so the key
            // literal at an offset in `literal` belongs to the `Button(` at
            // the same offset in `strict`.
            var buttonSpans: [ButtonSpan] = []
            var buttonFrom = buttonsOpen
            let buttonToken = Array("Button(")
            while let hit = firstOffset(of: buttonToken, in: strict, from: buttonFrom), hit < buttonsClose {
                let argsOpen = hit + buttonToken.count - 1
                guard let argsClose = closingOffset(from: argsOpen, in: strict, open: "(", close: ")"),
                      let actionOpen = firstOffset(of: ["{"], in: strict, from: argsClose),
                      strict[(argsClose + 1)..<actionOpen].allSatisfy(\.isWhitespace),
                      let actionClose = closingOffset(from: actionOpen, in: strict, open: "{", close: "}")
                else { throw ScanError.dialogNotFound }
                let labelLiteral = String(literal[argsOpen...argsClose])
                buttonSpans.append(ButtonSpan(
                    key: Self.catalogKeys(in: labelLiteral).first,
                    arguments: String(strict[argsOpen...argsClose]),
                    action: String(strict[actionOpen...actionClose])))
                buttonFrom = actionClose
            }

            let span = String(literal[parenOpen...messageClose])
            let keys = Self.catalogKeys(in: span)
            return Dialog(
                arguments: arguments,
                buttons: String(strict[buttonsOpen...buttonsClose]),
                message: String(strict[messageOpen...messageClose]),
                unlocalizedTexts: unlocalized,
                textCount: textStarts.count,
                keys: keys,
                setter: String(strict[setterOpen...setterClose]),
                buttonSpans: buttonSpans)
        }
        throw ScanError.dialogNotFound
    }

    /// Every key literal an `L10n.string(` in `text` names, in order.
    /// Walked by hand rather than matched with a regex literal: the project's
    /// source strippers read every test file, and a bare `/…/` literal
    /// carrying a quote is what they cannot parse.
    private static func catalogKeys(in text: String) -> [String] {
        var keys: [String] = []
        for piece in text.components(separatedBy: "L10n.string(").dropFirst() {
            let rest = piece.drop(while: { $0.isWhitespace })
            guard rest.first == "\"" else { continue }
            keys.append(String(rest.dropFirst().prefix(while: { $0 != "\"" })))
        }
        return keys
    }

    private static func firstOffset(of token: [Character], in text: [Character], from start: Int) -> Int? {
        guard !token.isEmpty, text.count >= token.count, start <= text.count - token.count else { return nil }
        for offset in start...(text.count - token.count) where text[offset..<(offset + token.count)].elementsEqual(token) {
            return offset
        }
        return nil
    }

    private static func closingOffset(
        from open: Int, in text: [Character], open opener: Character, close closer: Character
    ) -> Int? {
        var depth = 0
        for offset in open..<text.count {
            if text[offset] == opener { depth += 1 }
            if text[offset] == closer {
                depth -= 1
                if depth == 0 { return offset }
            }
        }
        return nil
    }
}
