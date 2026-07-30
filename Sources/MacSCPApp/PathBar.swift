import AppKit
import SwiftUI
import macSCPCore

/// The pane header's path line (M11g/T2): a plain path display at rest,
/// with three interactive layers on top — a click copies the path, a
/// double-click turns it into an editable field, Tab completes shell-style.
///
/// Resting-state visuals (font, color, truncation, alignment) are UNCHANGED
/// from the plain `Text(viewModel.currentPath)` this replaces — those
/// numbers were matched against the M5g mockup and must not drift.
///
/// `fileSystem` is injected rather than reached through `viewModel`:
/// `RemoteBrowserViewModel.fs` is deliberately private (the view model's
/// public surface is `load`/`open`/`goUp`/`navigate`, never a raw arbitrary
/// listing), so Tab-completion's directory listing comes from the pane's
/// own file system instead — `session.localFS` for the local side or
/// `session.remoteFS` for the remote side, passed straight through (M11g/T2
/// review, finding M6: `BrowserPane` used to take a bespoke `listDirectory`
/// closure built at each `ContentView` call site, a second, independent
/// fact about which side a pane is that could silently disagree with
/// `side`; passing the file system value itself removes the closure
/// indirection). Wired at the `BrowserPane` call site in `ContentView`.
struct PathBar: View {
    let viewModel: RemoteBrowserViewModel
    /// `true` for the remote pane, `false` for local. A fixed value would
    /// complete wrongly on one of the two sides — see `PathCompletion`'s doc
    /// comment on the same parameter for why there is no default.
    let caseSensitive: Bool
    /// Lists an arbitrary absolute directory for Tab-completion — see the
    /// type's doc comment above for why this is injected rather than pulled
    /// off `viewModel`.
    let fileSystem: any RemoteFileSystem
    /// External trigger for a `navigate(to:)` attempt that did NOT originate
    /// from this field (M11h/T1): a symlink double-click in the file list
    /// follows the same route the field's Enter key uses, and on failure
    /// reuses this exact inline overlay to show the message rather than
    /// inventing a second error surface. `BrowserPane` sets `wrappedValue` to
    /// the symlink's own path (never a resolved target); this view opens
    /// itself in the edit state to run it and consumes the value (resets it
    /// to `nil`) as soon as it's seen, so a repeat double-click on the same
    /// path still re-triggers. Defaults to a no-op binding, so the existing
    /// call site (both panes go through the same `PathBar`) keeps compiling
    /// unchanged unless `BrowserPane` explicitly wires it.
    var externalNavigationRequest: Binding<String?> = .constant(nil)

    /// What is shown in the inline overlay anchored under the field:
    /// nothing, the Tab-completion candidates (second consecutive Tab), or
    /// the message from a failed `navigate(to:)`/listing. Mutually
    /// exclusive by construction — only one of the two ever applies at a
    /// time. Not `Equatable` (M11g/T2 review, finding M9): nothing compares
    /// two instances, only `nil`-checks it.
    private enum FieldOverlayContent {
        case candidates([String])
        case error(String)
    }

    @State private var isEditing = false
    @State private var draft = ""
    @State private var overlayContent: FieldOverlayContent?
    /// The candidates from the most recently finished completion, kept
    /// around independently of whether the overlay is currently showing —
    /// a second Tab reveals THESE without recomputing anything.
    @State private var lastCandidates: [String] = []
    /// The directory `lastCandidates` was listed against (M11g/T2 review,
    /// finding I1). Stored alongside the candidates rather than re-derived
    /// from `draft` when a candidate is clicked: by the time a candidate is
    /// clickable, `draft` already ends in the completed segment (plus a
    /// trailing `/` after a single-match Tab), so re-running
    /// `PathCompletion.directoryToList(for: draft)` at click time strips a
    /// real path segment instead of reproducing the directory that was
    /// actually listed.
    @State private var lastCandidatesDirectory = ""
    /// The draft `lastCandidates` was computed for — set to
    /// `result.completedInput` when a completion applies, since that is
    /// what `draft` reads as immediately afterward. A second Tab may only
    /// redisplay `lastCandidates` when this still equals the current
    /// `draft`; otherwise the candidates belong to an earlier, superseded
    /// completion and must not be shown as if they were current.
    @State private var lastCandidatesDraft = ""
    /// `true` when a second Tab arrived while `completionTask` was still
    /// in flight (so `lastCandidatesDraft` didn't yet match `draft` and
    /// nothing could be shown). The completion task's success path checks
    /// this once it finishes and, if set, opens the candidates overlay
    /// then instead of leaving the request silently dropped.
    @State private var candidatesRequestedWhileInFlight = false
    /// `true` right after a Tab keypress is accepted; any other input
    /// (typed character, arrow key, delete, ...) resets it. A Tab that
    /// lands while this is still `true` is the "second, immediately
    /// following" Tab the spec calls for, and opens the candidates overlay
    /// instead of completing again.
    ///
    /// Set SYNCHRONOUSLY when the Tab is accepted (M11g/T2 review, finding
    /// I6) rather than after the listing finishes: the async result only
    /// fills in `draft` and `lastCandidates`. Setting it after the await
    /// meant a second Tab arriving while a slow remote listing was still in
    /// flight saw `false`, cancelled the in-flight completion, and
    /// restarted it — so hammering Tab on a slow connection never showed
    /// candidates, the exact case the flag exists for.
    @State private var justCompletedWithTab = false
    /// `nil` while not cycling; otherwise the index of the highlighted
    /// candidate in `lastCandidates` (M11i). Set by `handleTab`/`handleBacktab`
    /// once the candidates list is showing, and reset to `nil` — never left
    /// pointing at a list that may no longer apply — in `beginEditing()`, at
    /// the start of every fresh Tab-completion listing, and by
    /// `resetTabTracking()` (any keystroke that isn't itself a Tab leaves
    /// cycling mode, same as it already resets `justCompletedWithTab`). That
    /// last reset is not just hygiene: `cancel()`'s first-Esc-stage below
    /// only restores `cycleBaseDraft` while `cycleIndex != nil` AND the
    /// candidates list is still open (`isCandidatesListOpen`), so leaving a
    /// stale index set after the user has typed something new would make
    /// Esc discard text they just typed instead of the one-step-back the
    /// design calls for.
    @State private var cycleIndex: Int?
    /// The field text as it stood right before the first cycle step
    /// (`cycleIndex == nil` becoming non-`nil`) — what the first Esc while
    /// cycling restores `draft` to. Only meaningful while `cycleIndex != nil`.
    @State private var cycleBaseDraft = ""
    @State private var completionTask: Task<Void, Never>?
    @State private var copyConfirmationTask: Task<Void, Never>?
    @State private var showCopyConfirmation = false
    /// Identifies one double-click-to-edit session (M11g/T2 review, finding
    /// I4). A `navigate(to:)`/listing `Task` captures this before its
    /// `await` and re-checks it afterwards, alongside `isEditing`: without
    /// it, closing the field (Esc, blur) and then IMMEDIATELY double-clicking
    /// again to start a fresh edit before the old task resolves would let
    /// the old task's stale result (an error message, or overwritten
    /// `draft`) land on the new session — `isEditing` alone can't tell the
    /// two sessions apart since it would already be back to `true`.
    ///
    /// This does not itself cancel the in-flight `navigate(to:)` call (Esc
    /// does NOT abort an in-flight navigation — Core's `navigate(to:)`
    /// isn't cancellation-aware, per Task 1's frozen contract); it only
    /// guards against applying a stale result to the wrong session.
    @State private var editSessionID = UUID()

    var body: some View {
        Group {
            if isEditing {
                PathTextField(
                    text: $draft,
                    font: .monospacedSystemFont(ofSize: 11.5, weight: .regular),
                    textColor: DesignTokens.inkTertiaryNS,
                    onNavigate: commit,
                    onCancel: cancel,
                    onTab: handleTab,
                    onBacktab: handleBacktab,
                    onOtherInput: resetTabTracking,
                    // Deliberately calls `closeField()`, not `cancel()`: by
                    // the time blur fires, first responder is already gone,
                    // so this must always fully close, even mid-cycle, when
                    // `cancel()` itself would still take its first stage
                    // (`isCandidatesListOpen` is still `true` here — nothing
                    // clears the overlay before `onBlur` runs) — see
                    // `closeField()`'s doc comment for why the two share one
                    // function instead of a second, divergent close path.
                    onBlur: { if isEditing { closeField() } },
                    isCandidatesListOpen: isCandidatesListOpen
                )
            } else {
                Text(showCopyConfirmation
                    ? L10n.string("browser.pathBar.copied", "Copied!")
                    : viewModel.currentPath)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(DesignTokens.inkTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        if hovering {
                            NSCursor.pointingHand.set()
                        } else {
                            NSCursor.arrow.set()
                        }
                    }
                    .onDisappear {
                        // A double-click swaps this `Text` for the editable
                        // field while the mouse may still be hovering it, so
                        // no balancing `onHover(false)` arrives. `.set()`
                        // (M11g/T2 review, finding I3) has no stack to leak,
                        // unlike the `push()`/`pop()` pair this replaced, but
                        // restoring the arrow here still avoids the cursor
                        // visibly staying a pointing hand over the field
                        // until the next real mouse-moved event.
                        NSCursor.arrow.set()
                    }
                    .onTapGesture(count: 2, perform: beginEditing)
                    .onTapGesture(count: 1, perform: copyPath)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .topLeading) {
            if overlayContent != nil {
                overlayBody
                    .offset(y: 24)
            }
        }
        // Raises this view (and its overlay) above LATER siblings in the
        // enclosing `HStack` (the up/refresh buttons) — see the matching
        // `.zIndex(1)` on the header `HStack` in `BrowserPane` for the
        // outer half of this fix (M11g/T2 review, finding C1).
        .zIndex(1)
        .onDisappear {
            // M11g/T2 review, finding M4: this pane's tasks must not outlive
            // it — tab switch or pane teardown must not leave a listing or
            // the "Copied!" revert running against a view that's gone.
            completionTask?.cancel()
            copyConfirmationTask?.cancel()
        }
        .onChange(of: externalNavigationRequest.wrappedValue) { _, newValue in
            guard let target = newValue else { return }
            // Consume immediately (M11h/T1): a second double-click on the
            // same still-failing symlink must re-trigger even though the
            // binding's value wouldn't otherwise change.
            externalNavigationRequest.wrappedValue = nil
            completionTask?.cancel()
            overlayContent = nil
            justCompletedWithTab = false
            cycleIndex = nil
            draft = target
            editSessionID = UUID()
            isEditing = true
            runNavigation(to: target)
        }
    }

    /// Whether Shift+Tab should cycle backward instead of falling through to
    /// AppKit's default focus traversal (M11i) — `PathTextField` cannot tell
    /// this on its own (per that type's doc comment), so it asks the view.
    /// Also used by `cancel()`'s first-Esc-stage gate below (M11i review):
    /// the candidates list being visibly open, not just `cycleIndex != nil`,
    /// is what distinguishes a genuine mid-cycle Esc from cycling being
    /// effectively over already (a completed or failed `commit()`).
    private var isCandidatesListOpen: Bool {
        if case .candidates = overlayContent { return true }
        return false
    }

    @ViewBuilder
    private var overlayBody: some View {
        switch overlayContent {
        case .candidates(let names):
            CandidatesList(names: names, selectedIndex: cycleIndex, onSelect: selectCandidate)
                .overlayCardStyle()
        case .error(let message):
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.red)
                .padding(10)
                .frame(maxWidth: 320, alignment: .leading)
                .overlayCardStyle()
        case nil:
            EmptyView()
        }
    }

    // MARK: - Click to copy

    private func copyPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(viewModel.currentPath, forType: .string)
        showCopyConfirmation = true
        copyConfirmationTask?.cancel()
        copyConfirmationTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            showCopyConfirmation = false
        }
    }

    // MARK: - Double-click to edit

    private func beginEditing() {
        completionTask?.cancel()
        overlayContent = nil
        justCompletedWithTab = false
        lastCandidates = []
        lastCandidatesDirectory = ""
        lastCandidatesDraft = ""
        candidatesRequestedWhileInFlight = false
        cycleIndex = nil
        cycleBaseDraft = ""
        editSessionID = UUID()
        draft = viewModel.currentPath
        isEditing = true
        // Caret placement at the end is handled by `PathTextField` itself,
        // directly on the `NSTextField` instance it owns — no reaching
        // through `NSApp.keyWindow`'s first responder (see that type's doc
        // comment for the review finding this replaced).
    }

    private func commit() {
        guard isEditing else { return }
        completionTask?.cancel()
        overlayContent = nil
        // Enter is not itself a Tab, so it must reset the "second
        // consecutive Tab" tracking the same as any other keystroke would
        // (`resetTabTracking`/`onOtherInput`) — otherwise a failed
        // `navigate(to:)` below leaves the field open with the flag still
        // `true`, and the next Tab reuses stale cached candidates instead
        // of completing against the (possibly now-corrected) typed path.
        justCompletedWithTab = false
        // Same reasoning for `cycleIndex` (M11i review, belt and suspenders):
        // the gating fix in `cancel()` below already stops a FAILED commit's
        // Esc from misfiring, since the overlay by then is `.error`, not
        // `.candidates`, so `isCandidatesListOpen` is `false` regardless of
        // this reset — but leaving a stale index around once cycling is over
        // is exactly the kind of dangling state that misled an earlier
        // milestone, so it is cleared here too, same as `resetTabTracking`
        // already clears it for any non-Tab keystroke.
        cycleIndex = nil
        runNavigation(to: draft)
    }

    /// Shared by `commit()` (the field's own Enter key) and
    /// `externalNavigationRequest`'s handler (M11h/T1, a symlink
    /// double-click elsewhere in the pane): calls `navigate(to:)` and, on
    /// failure, leaves the field open showing the message inline — the one
    /// error surface, used both ways instead of a second one for the
    /// double-click path. On success it simply closes the field.
    private func runNavigation(to target: String) {
        let session = editSessionID
        Task {
            let message = await viewModel.navigate(to: target)
            // Re-check before touching UI state (finding I4): the field may
            // have been dismissed (Esc, blur) — or dismissed and reopened as
            // a new session — while this awaited.
            guard isEditing, session == editSessionID else { return }
            if let message {
                // Honest failure (spec §4): field stays open, keeps the
                // typed text, shows the message. Only success below closes it.
                overlayContent = .error(message)
            } else {
                isEditing = false
            }
        }
    }

    private func cancel() {
        // Esc's first stage (M11i): while the candidates list is visibly
        // open AND cycling (`cycleIndex != nil` AND `isCandidatesListOpen`),
        // one Esc steps back to the text that stood in the field before
        // cycling started, closes the list, and leaves the field open — it
        // does NOT yet discard the whole edit. Only a SECOND Esc (the list
        // is closed by then, so `isCandidatesListOpen` is `false`) falls
        // through to the unconditional close below, exactly as Esc always
        // behaved before cycling existed. Both callers of `cancel()` that
        // mean "the user pressed Esc" — the AppKit `cancelOperation`
        // override and this function's own `onCancel` closure wiring —
        // share this one function, so there is only one rule to keep in
        // sync, not two.
        //
        // Gating on `isCandidatesListOpen` in addition to `cycleIndex !=
        // nil` (M11i review, fix for two misfires) matters because
        // `cycleIndex` alone can stay non-`nil` after cycling is effectively
        // over: a FAILED `commit()` leaves the field open with the error
        // overlay shown instead of the candidates list, so an Esc there must
        // plain-close rather than replay a cycling step against a list that
        // is no longer on screen. (`commit()` also resets `cycleIndex`
        // itself now, belt and suspenders — see its own comment — but this
        // gate is what actually stops the misfire.)
        if cycleIndex != nil && isCandidatesListOpen {
            draft = cycleBaseDraft
            cycleIndex = nil
            overlayContent = nil
            return
        }
        closeField()
    }

    /// The unconditional close: cancels any in-flight completion, drops the
    /// overlay and cycle state, and ends the edit outright — everything
    /// `cancel()`'s first-Esc-stage above deliberately does NOT yet do.
    /// Shared by `cancel()`'s own second stage and by `onBlur` below (M11i
    /// review) rather than duplicated: `onBlur` cannot route through
    /// `cancel()` itself, because by the time blur fires, first responder
    /// has already moved elsewhere, so taking the first stage there would
    /// restore the pre-cycle text and leave the field open-but-unfocused —
    /// contradicting the M11g blur-discard invariant that every way of
    /// leaving the field closes it. `onBlur` calling this same function
    /// directly, instead of introducing its own separate close logic, keeps
    /// there being exactly one definition of "fully close the field".
    private func closeField() {
        completionTask?.cancel()
        cycleIndex = nil
        overlayContent = nil
        isEditing = false
    }

    // MARK: - Tab completion

    /// Resets the "second consecutive Tab" tracking on any input that isn't
    /// itself a Tab (typed characters, arrow keys, delete, ...) — the
    /// `PathTextField` equivalent of the old `onKeyPress`'s catch-all branch.
    private func resetTabTracking() {
        justCompletedWithTab = false
        overlayContent = nil
        // Any keystroke that isn't itself a Tab leaves cycling mode (M11i
        // design, "Ein anderer Tastendruck ... verlässt den Blätter-Modus"):
        // the text stays exactly as the field now shows it, and the next Tab
        // starts a fresh completion round instead of resuming a cycle bound
        // to candidates the user has since typed past.
        cycleIndex = nil
    }

    private func handleTab() {
        if justCompletedWithTab {
            // The cached list may belong to an OLDER, superseded completion:
            // if a listing is still in flight for the current draft (see
            // below), `lastCandidatesDraft` hasn't been updated to match it
            // yet. The list counts as available once it demonstrably belongs
            // to the draft on screen right now (fresh from `handleTab`'s own
            // first-Tab branch, below) — OR we are already mid-cycle, where
            // `draft` no longer equals `lastCandidatesDraft` because cycling
            // itself keeps overwriting `draft` with each candidate (M11i).
            // Either way, this Tab advances the cycle by one. Otherwise
            // remember that candidates were asked for so the in-flight task
            // can show them itself once it resolves, instead of silently
            // keeping the stale list (or nothing) on screen until yet
            // another Tab press.
            let candidatesAvailable = !lastCandidates.isEmpty && lastCandidatesDraft == draft
            if candidatesAvailable || cycleIndex != nil {
                cycleThroughCandidates(using: CandidateCycle.next)
            } else {
                candidatesRequestedWhileInFlight = true
            }
            return
        }
        overlayContent = nil
        completionTask?.cancel()
        justCompletedWithTab = true
        candidatesRequestedWhileInFlight = false
        // A fresh Tab-completion round starts here: any cycle bound to the
        // OLD `lastCandidates` must not survive into whatever this new
        // listing turns up (M11i, same late-listing carefulness as findings
        // I2/I6) — otherwise a slow listing could resolve into a candidate
        // list where a stale `cycleIndex` points at the wrong entry, or past
        // its end.
        cycleIndex = nil
        let input = draft
        let session = editSessionID
        completionTask = Task {
            let directory = PathCompletion.directoryToList(for: input)
            let entries: [RemoteFileItem]
            do {
                entries = try await fileSystem.list(path: directory)
            } catch {
                // Finding I5: a failed listing must not be silently
                // indistinguishable from an empty directory. The underlying
                // reason still goes through the same public error-message
                // mapping the App layer already reuses for editor-open
                // failures (Core's own `RemoteBrowserViewModel.message(for:
                // path:)` isn't public) — but the wrapping text is now a
                // dedicated "directory could not be listed" string instead
                // of the generic transfer-failure wording, since listing a
                // directory for Tab completion is not a transfer.
                guard !Task.isCancelled, isEditing, session == editSessionID,
                    draft == input
                else { return }
                lastCandidates = []
                overlayContent = .error(
                    String(
                        format: L10n.string(
                            "browser.pathBar.listingFailed %@",
                            "Couldn't list the directory: %@"),
                        TransferQueueViewModel.message(for: error)))
                return
            }
            // Finding I2: a late listing must not overwrite text typed in
            // the meantime — re-check `draft` is still what this task
            // started from (typing never cancels `completionTask` itself,
            // so this guard is the only thing that catches it) alongside
            // the session/editing guards from finding I4.
            guard !Task.isCancelled, isEditing, session == editSessionID,
                draft == input
            else { return }
            let result = PathCompletion.complete(
                input: input, entries: entries, caseSensitive: caseSensitive)
            draft = result.completedInput
            lastCandidates = result.candidates
            lastCandidatesDirectory = directory
            // The draft these candidates belong to, for the second-Tab
            // staleness check above — `result.completedInput` is exactly
            // what `draft` now reads as.
            lastCandidatesDraft = result.completedInput
            // A second Tab arrived while this listing was still in flight
            // and found nothing safe to show (see above); honor it now that
            // the result — for the SAME draft it was requested against — is
            // finally in.
            if candidatesRequestedWhileInFlight {
                candidatesRequestedWhileInFlight = false
                if !lastCandidates.isEmpty {
                    overlayContent = .candidates(lastCandidates)
                }
            }
        }
    }

    /// Shift+Tab (M11i) — `PathTextField` only calls this while
    /// `isCandidatesListOpen` is `true` (its own doc comment explains why
    /// that check lives there, not here), so the candidates list is always
    /// available whenever this runs; cycling backward is otherwise exactly
    /// like a Tab press with `CandidateCycle.previous` instead of `.next`.
    private func handleBacktab() {
        cycleThroughCandidates(using: CandidateCycle.previous)
    }

    /// Shared by `handleTab`'s cycling branch and `handleBacktab`: advances
    /// `cycleIndex` via `step` (`CandidateCycle.next` or `.previous`),
    /// remembers the pre-cycle text in `cycleBaseDraft` on the very first
    /// step (`cycleIndex == nil` becoming non-`nil` — that is what Esc's
    /// first stage restores `draft` to), and puts the newly selected
    /// candidate into the field using the exact same construction
    /// `selectCandidate` uses — `RemotePath.join(lastCandidatesDirectory,
    /// name) + "/"` — never re-derived from `draft`, for the same reason
    /// documented on `lastCandidatesDirectory` above.
    private func cycleThroughCandidates(using step: (Int?, Int) -> Int?) {
        if cycleIndex == nil {
            cycleBaseDraft = draft
        }
        cycleIndex = step(cycleIndex, lastCandidates.count)
        guard let index = cycleIndex else { return }
        draft = RemotePath.join(lastCandidatesDirectory, lastCandidates[index]) + "/"
        overlayContent = .candidates(lastCandidates)
    }

    private func selectCandidate(_ name: String) {
        // Finding I1: use the directory the candidates were actually listed
        // against, not `PathCompletion.directoryToList(for: draft)` —
        // `draft` already ends in the completed (and, after a single-match
        // Tab, slash-terminated) segment by the time a candidate is
        // clickable, so re-deriving from it strips a real path segment.
        draft = RemotePath.join(lastCandidatesDirectory, name) + "/"
        overlayContent = nil
        justCompletedWithTab = false
        // A click adopts one candidate outright — it is not a cycling step,
        // so nothing about it should look like mid-cycle to `cancel()`'s
        // first-Esc-stage check afterward (M11i).
        cycleIndex = nil
    }
}

/// Shared chrome for the inline overlay's two bodies (candidates, error) —
/// factored out so both cases in `PathBar.overlayBody` apply the identical
/// card treatment.
private extension View {
    func overlayCardStyle() -> some View {
        self
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(DesignTokens.hairline, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
    }
}

/// AppKit-backed replacement for SwiftUI's `TextField` (M11g/T2 review,
/// finding C2). Two problems drove this:
///
/// - Tab is genuinely ambiguous under SwiftUI's own focus/key-handling
///   stack: the field editor can consume it as focus traversal before
///   SwiftUI's `onKeyPress` ever sees it, silently moving focus out of the
///   field — which fires the blur-discard rule and throws away the typed
///   path. Overriding `control(_:textView:doCommandBy:)` on a plain
///   `NSTextField` intercepts these commands deterministically, before
///   AppKit's default command implementation (including tab traversal) runs
///   at all — there is no race to lose.
/// - Placing the caret at the end on double-click no longer needs to reach
///   through `NSApp.keyWindow?.firstResponder as? NSTextView` one run-loop
///   tick after focus (timing-sensitive, and not necessarily even THIS
///   field if something else briefly holds focus) or mix a `Character`
///   count with a UTF-16 `NSRange` (misplacing the caret on any path with a
///   multi-UTF-16-unit character, e.g. an emoji folder name). Owning the
///   `NSTextField` instance directly means the selection is set on exactly
///   the field being edited, using `NSString.length` (UTF-16, matching
///   `NSRange`'s own units) for the end offset.
private struct PathTextField: NSViewRepresentable {
    @Binding var text: String
    let font: NSFont
    let textColor: NSColor
    let onNavigate: () -> Void
    let onCancel: () -> Void
    let onTab: () -> Void
    /// Shift+Tab, called only while `isCandidatesListOpen` is `true` (M11i)
    /// — see that property's doc comment for why the Coordinator asks the
    /// view instead of guessing.
    let onBacktab: () -> Void
    let onOtherInput: () -> Void
    let onBlur: () -> Void
    /// Whether the candidates overlay is currently showing. `PathTextField`
    /// has no notion of "candidates" itself — the overlay, `lastCandidates`,
    /// and cycling all live in `PathBar`'s `@State` — so this is computed
    /// there (`PathBar.isCandidatesListOpen`) and simply handed down here,
    /// per the M11i brief's instruction not to have this view guess at state
    /// it cannot see.
    let isCandidatesListOpen: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = font
        field.textColor = textColor
        field.stringValue = text
        field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // Deferred one tick so the view is actually installed in a window
        // (it never is yet at this point) — but, unlike the code this
        // replaces, what runs afterward reaches `field` directly instead of
        // groping through `NSApp.keyWindow`, so there's no question of
        // WHICH text view this is.
        Self.becomeFirstResponderAndPlaceCaretAtEnd(field, retriesLeft: 1)
        return field
    }

    /// Tries to make `field` first responder and place the caret at the end
    /// of its text; if the window still isn't installed one tick after
    /// `makeNSView`, retries exactly once on the following tick. If it still
    /// fails after that, this deliberately gives up rather than looping or
    /// logging: the field is still visible and usable, just not yet
    /// focused, and the user can click into it to gain focus. This is a
    /// floor, not an oversight.
    private static func becomeFirstResponderAndPlaceCaretAtEnd(
        _ field: NSTextField, retriesLeft: Int
    ) {
        DispatchQueue.main.async {
            guard field.window?.makeFirstResponder(field) == true else {
                if retriesLeft > 0 {
                    becomeFirstResponderAndPlaceCaretAtEnd(field, retriesLeft: retriesLeft - 1)
                }
                return
            }
            let end = (field.stringValue as NSString).length
            field.currentEditor()?.selectedRange = NSRange(location: end, length: 0)
        }
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.parent = self
        guard nsView.stringValue != text else { return }
        context.coordinator.isProgrammaticUpdate = true
        nsView.stringValue = text
        context.coordinator.isProgrammaticUpdate = false
        if nsView.currentEditor() != nil {
            let end = (text as NSString).length
            nsView.currentEditor()?.selectedRange = NSRange(location: end, length: 0)
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PathTextField
        /// Set around `updateNSView`'s own `stringValue` writes (Tab
        /// completion, candidate selection) so they can't be mistaken for
        /// user input and reset `justCompletedWithTab` themselves.
        var isProgrammaticUpdate = false

        init(_ parent: PathTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard !isProgrammaticUpdate, let field = notification.object as? NSTextField
            else { return }
            parent.text = field.stringValue
            parent.onOtherInput()
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            parent.onBlur()
        }

        func control(
            _ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector
        ) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onNavigate()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            case #selector(NSResponder.insertTab(_:)):
                // Returning `true` tells AppKit this was handled — it does
                // NOT move focus, unlike the default tab-traversal command.
                parent.onTab()
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                // M11i: while the candidates list is open, Shift+Tab cycles
                // BACKWARD through it instead of traversing focus — this is
                // the one case finding M7 (below) deliberately carves an
                // exception for, since here there IS something for Shift+Tab
                // to do besides discard the field.
                guard parent.isCandidatesListOpen else {
                    // Finding M7: outside the candidates list, Shift+Tab must
                    // still NOT complete. Returning `false` lets AppKit's
                    // default backtab (focus traversal backward) proceed
                    // untouched — which then blurs the field, discarding the
                    // draft via the normal blur rule, same as any other way
                    // of leaving the field.
                    return false
                }
                parent.onBacktab()
                return true
            default:
                parent.onOtherInput()
                return false
            }
        }
    }
}

/// The clickable candidates overlay body (M11g/T2 step 4) — a plain
/// vertical list, one row per name, click adopts it into the field.
///
/// (M11g final review, Important): a directory like `/System/Library/
/// Frameworks` has hundreds of entries, and a plain `VStack` with no height
/// limit used to lay out a card thousands of points tall — clipped by the
/// window, with everything past the edge permanently unreachable. Rows now
/// scroll inside a region of DEFINITE height (see `listHeight` for why a
/// maximum is not enough), and a footer names the total count whenever that
/// region actually hides some of them, the way a shell asks before dumping
/// hundreds of completions instead of silently truncating.
private struct CandidatesList: View {
    let names: [String]
    /// The Tab-cycling highlight (M11i) — `nil` in the plain "list just
    /// showed, nothing chosen yet" state, matching the pre-M11i look exactly
    /// (see `PathBar.cycleIndex`'s doc comment for when this is non-`nil`).
    let selectedIndex: Int?
    let onSelect: (String) -> Void

    /// `CandidateRow`'s rendered height (11.5pt monospaced text plus 4pt of
    /// vertical padding on each side), MEASURED at 22pt rather than
    /// estimated: this constant drives the scroller's layout, not just the
    /// footer decision, so an approximation would leave slack per row and
    /// misjudge where the cap bites.
    private static let rowHeight: CGFloat = 22
    private static let maxListHeight: CGFloat = 240

    /// A DEFINITE height, never `maxHeight` (M11g final review, C1): a
    /// `ScrollView` is vertically flexible and accepts whatever height it is
    /// proposed, and `.overlay` proposes the PARENT's size — here the 14pt
    /// path line. `maxHeight` only clamps from above, so the scroller
    /// collapsed to a ~14pt sliver showing a fraction of one row, scrollable
    /// inside a viewport shorter than a single row. The plain `VStack` this
    /// replaced only worked because it was inflexible and returned its own
    /// ideal height (which is what let it grow to thousands of points).
    private var listHeight: CGFloat {
        min(CGFloat(names.count) * Self.rowHeight, Self.maxListHeight)
    }

    private var isTruncated: Bool {
        CGFloat(names.count) * Self.rowHeight > Self.maxListHeight
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(names.enumerated()), id: \.offset) { index, name in
                            CandidateRow(
                                name: name,
                                isSelected: index == selectedIndex,
                                onSelect: { onSelect(name) }
                            )
                            .id(index)
                        }
                    }
                }
                .frame(height: listHeight)
                .onChange(of: selectedIndex) { _, newIndex in
                    // Keeps the highlighted candidate visible while cycling
                    // through a list capped at `maxListHeight` (M11i) — a
                    // long directory listing can hold far more entries than
                    // fit on screen at once.
                    guard let newIndex else { return }
                    withAnimation {
                        proxy.scrollTo(newIndex, anchor: .center)
                    }
                }
            }

            if isTruncated {
                Divider()
                Text(
                    String(
                        format: L10n.string(
                            "browser.pathBar.candidateCount %lld", "%lld matches"),
                        names.count)
                )
                .font(.system(size: 10))
                .foregroundStyle(DesignTokens.inkTertiary)
                .padding(.horizontal, 10)
                .padding(.top, 4)
                .padding(.bottom, 4)
            }
        }
        .padding(.vertical, 4)
        .frame(minWidth: 160, alignment: .leading)
    }
}

private struct CandidateRow: View {
    let name: String
    /// Highlighted as the Tab-cycling selection (M11i) — the same
    /// `remoteSoft` fill the M5g table selection uses, so the two selection
    /// affordances in the app read as one system rather than two different
    /// looks for "this is the selected thing".
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovering = false

    private var background: Color {
        if isSelected { return DesignTokens.remoteSoft }
        return isHovering ? Color.secondary.opacity(0.12) : Color.clear
    }

    var body: some View {
        Text(name)
            .font(.system(size: 11.5, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(background)
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelect)
            .onHover { isHovering = $0 }
    }
}
