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
                    onOtherInput: resetTabTracking,
                    onBlur: { if isEditing { cancel() } }
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
    }

    @ViewBuilder
    private var overlayBody: some View {
        switch overlayContent {
        case .candidates(let names):
            CandidatesList(names: names, onSelect: selectCandidate)
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
        let target = draft
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
        completionTask?.cancel()
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
    }

    private func handleTab() {
        if justCompletedWithTab {
            if !lastCandidates.isEmpty {
                overlayContent = .candidates(lastCandidates)
            }
            return
        }
        overlayContent = nil
        completionTask?.cancel()
        justCompletedWithTab = true
        let input = draft
        let session = editSessionID
        completionTask = Task {
            let directory = PathCompletion.directoryToList(for: input)
            let entries: [RemoteFileItem]
            do {
                entries = try await fileSystem.list(path: directory)
            } catch {
                // Finding I5: a failed listing must not be silently
                // indistinguishable from an empty directory — map it
                // through the same public error-message mapping the App
                // layer already reuses for editor-open failures (Core's own
                // `RemoteBrowserViewModel.message(for:path:)` isn't public).
                guard !Task.isCancelled, isEditing, session == editSessionID,
                    draft == input
                else { return }
                lastCandidates = []
                overlayContent = .error(TransferQueueViewModel.message(for: error))
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
        }
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
    let onOtherInput: () -> Void
    let onBlur: () -> Void

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
        DispatchQueue.main.async {
            guard field.window?.makeFirstResponder(field) == true else { return }
            let end = (field.stringValue as NSString).length
            field.currentEditor()?.selectedRange = NSRange(location: end, length: 0)
        }
        return field
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
                // Finding M7: Shift+Tab must NOT complete. Returning `false`
                // lets AppKit's default backtab (focus traversal backward)
                // proceed untouched — which then blurs the field, discarding
                // the draft via the normal blur rule, same as any other way
                // of leaving the field.
                return false
            default:
                parent.onOtherInput()
                return false
            }
        }
    }
}

/// The clickable candidates overlay body (M11g/T2 step 4) — a plain
/// vertical list, one row per name, click adopts it into the field.
private struct CandidatesList: View {
    let names: [String]
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(names, id: \.self) { name in
                CandidateRow(name: name, onSelect: { onSelect(name) })
            }
        }
        .padding(.vertical, 4)
        .frame(minWidth: 160, alignment: .leading)
    }
}

private struct CandidateRow: View {
    let name: String
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        Text(name)
            .font(.system(size: 11.5, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(isHovering ? Color.secondary.opacity(0.12) : Color.clear)
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelect)
            .onHover { isHovering = $0 }
    }
}
