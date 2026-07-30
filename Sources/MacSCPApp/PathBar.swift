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
/// `listDirectory` is injected rather than reached through `viewModel`:
/// `RemoteBrowserViewModel.fs` is deliberately private (the view model's
/// public surface is `load`/`open`/`goUp`/`navigate`, never a raw arbitrary
/// listing), so Tab-completion's directory listing comes from the pane's
/// own file system instead — a fresh `LocalFileSystem()` for the local side
/// (stateless, so a new instance is equivalent to any other) or the
/// session's live connected `RemoteFileSystem` for the remote side. Wired at
/// the `BrowserPane` call site in `ContentView`, mirroring the existing
/// `onDropURLs`/`onOpenFile` callback-injection pattern.
struct PathBar: View {
    let viewModel: RemoteBrowserViewModel
    /// `true` for the remote pane, `false` for local. A fixed value would
    /// complete wrongly on one of the two sides — see `PathCompletion`'s doc
    /// comment on the same parameter for why there is no default.
    let caseSensitive: Bool
    /// Lists an arbitrary absolute directory for Tab-completion — see the
    /// type's doc comment above for why this is injected rather than pulled
    /// off `viewModel`.
    let listDirectory: (String) async throws -> [RemoteFileItem]

    /// What is shown in the popover anchored under the field: nothing, the
    /// Tab-completion candidates (second consecutive Tab), or the message
    /// from a failed `navigate(to:)`. Mutually exclusive by construction —
    /// only one of the two ever applies at a time.
    private enum PopoverContent: Equatable {
        case candidates([String])
        case error(String)
    }

    @State private var isEditing = false
    @State private var draft = ""
    @FocusState private var isFocused: Bool
    @State private var popoverContent: PopoverContent?
    /// The candidates from the most recently finished completion, kept
    /// around independently of whether the popover is currently showing —
    /// a second Tab reveals THESE without recomputing anything.
    @State private var lastCandidates: [String] = []
    /// `true` right after a Tab keypress finishes its completion; any other
    /// keypress resets it. A Tab that lands while this is still `true` is
    /// the "second, immediately following" Tab the spec calls for, and
    /// opens the candidates popover instead of completing again.
    @State private var justCompletedWithTab = false
    @State private var completionTask: Task<Void, Never>?
    @State private var copyConfirmationTask: Task<Void, Never>?
    @State private var showCopyConfirmation = false
    /// Tracks whether `NSCursor.pointingHand` is currently pushed onto the
    /// cursor stack, so it can be popped exactly once. A plain `onHover`
    /// push/pop pair is not enough here: a double-click swaps this `Text`
    /// for the `TextField` while the mouse is still over it, so the
    /// balancing `onHover(false)` never arrives — without this flag the
    /// pointing-hand cursor would stay stuck on the stack.
    @State private var isCursorPushed = false

    var body: some View {
        Group {
            if isEditing {
                TextField("", text: $draft, prompt: Text(verbatim: ""))
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5, design: .monospaced))
                    .focused($isFocused)
                    .onSubmit(commit)
                    .onExitCommand(perform: cancel)
                    .onKeyPress { press in
                        guard press.key == .tab else {
                            justCompletedWithTab = false
                            popoverContent = nil
                            return .ignored
                        }
                        handleTab()
                        return .handled
                    }
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
                            NSCursor.pointingHand.push()
                            isCursorPushed = true
                        } else if isCursorPushed {
                            NSCursor.pop()
                            isCursorPushed = false
                        }
                    }
                    .onDisappear {
                        if isCursorPushed {
                            NSCursor.pop()
                            isCursorPushed = false
                        }
                    }
                    .onTapGesture(count: 2, perform: beginEditing)
                    .onTapGesture(count: 1, perform: copyPath)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: isFocused) { _, focused in
            // Focus lost without an explicit commit (which clears `isEditing`
            // itself already) — discard silently, never commit on blur. Same
            // rule, same guard shape, as `SessionSidebar`'s inline rename.
            if !focused, isEditing {
                cancel()
            }
        }
        .popover(isPresented: Binding(
            get: { popoverContent != nil },
            set: { presented in if !presented { popoverContent = nil } }
        ), arrowEdge: .bottom) {
            popoverBody
        }
    }

    @ViewBuilder
    private var popoverBody: some View {
        switch popoverContent {
        case .candidates(let names):
            CandidatesList(names: names, onSelect: selectCandidate)
        case .error(let message):
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.red)
                .padding(10)
                .frame(maxWidth: 320, alignment: .leading)
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
        popoverContent = nil
        justCompletedWithTab = false
        draft = viewModel.currentPath
        isEditing = true
        isFocused = true
        // Cursor at the end, not the whole text selected (SwiftUI's default
        // for a field focused via `@FocusState`): no SwiftUI API exposes
        // this, so the window's field editor — always an `NSTextView` for a
        // focused `TextField` — is reached directly, one run-loop tick
        // after focus so it has actually been installed as first responder.
        DispatchQueue.main.async {
            guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
            editor.setSelectedRange(NSRange(location: editor.string.count, length: 0))
        }
    }

    private func commit() {
        guard isEditing else { return }
        completionTask?.cancel()
        popoverContent = nil
        let target = draft
        Task {
            if let message = await viewModel.navigate(to: target) {
                // Honest failure (spec §4): field stays open, keeps the
                // typed text, shows the message. Only success below closes it.
                popoverContent = .error(message)
            } else {
                isEditing = false
                isFocused = false
            }
        }
    }

    private func cancel() {
        completionTask?.cancel()
        popoverContent = nil
        isEditing = false
        isFocused = false
    }

    // MARK: - Tab completion

    private func handleTab() {
        if justCompletedWithTab {
            if !lastCandidates.isEmpty {
                popoverContent = .candidates(lastCandidates)
            }
            return
        }
        popoverContent = nil
        completionTask?.cancel()
        let input = draft
        completionTask = Task {
            let directory = PathCompletion.directoryToList(for: input)
            let entries = (try? await listDirectory(directory)) ?? []
            guard !Task.isCancelled else { return }
            let result = PathCompletion.complete(
                input: input, entries: entries, caseSensitive: caseSensitive)
            draft = result.completedInput
            lastCandidates = result.candidates
            justCompletedWithTab = true
        }
    }

    private func selectCandidate(_ name: String) {
        let directory = PathCompletion.directoryToList(for: draft)
        draft = RemotePath.join(directory, name) + "/"
        popoverContent = nil
        justCompletedWithTab = false
        isFocused = true
    }
}

/// The clickable candidates popover body (M11g/T2 step 4) — a plain
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
