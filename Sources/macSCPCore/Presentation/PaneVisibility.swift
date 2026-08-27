import Foundation

/// Which of the window's two halves — the file panes and the terminal — are
/// currently shown (P2, terminal-chrome milestone).
///
/// A bare terminal is a STATE either tab can be in, not a separate tab kind:
/// this type is the single source of truth for "which halves are visible",
/// and everything the toolbar and the layout do is read out of it.
///
/// **The invariant this type exists to hold:** a window with neither half
/// visible is empty and offers no way back, so that combination cannot be
/// represented as a live value. Both the memberwise initializer and
/// `init(from:)` funnel through the same repair (files wins) instead of each
/// guarding it separately, so a hand-edited `sessions.json` cannot smuggle
/// "nothing visible" past the rule the way a second, unchecked write path
/// would let it.
///
/// This type only decides WHICH halves are visible; it never reads
/// `TerminalPanelViewModel.isVisible`, the terminal-only toggle that owns
/// the shell's lifecycle. The two are already reconciled, and in exactly
/// one place: `SessionTab.effectivePaneVisibility(terminalIsVisible:
/// hasShell:)` is where that toggle's value becomes a `PaneVisibility`, and
/// its own doc comment is what says there must be only one such place —
/// the toolbar's `paneToggleState`, the render conditions, the restore and
/// the persist all read it rather than pairing the two booleans again.
public struct PaneVisibility: Equatable, Sendable, Codable {
    public let showsFiles: Bool
    public let showsTerminal: Bool

    /// Repairs "neither half visible" by forcing `showsFiles` back on. This
    /// is the type's only entry point for its stored properties — `init(from:)`
    /// below constructs through it too — so the repair cannot be bypassed by
    /// constructing a value directly. `let` above is load-bearing: it is what
    /// makes this the ONLY entry point. A `var` would let a caller mutate a
    /// valid value in place — `v.showsFiles = false; v.showsTerminal = false`
    /// — landing directly on "neither visible" without ever going through
    /// the repair, the same way `Snippet.command`/`Snippet.tags` are `let`
    /// so an in-place mutation cannot break their invariants either. Every
    /// change to a `PaneVisibility` therefore produces a NEW value through
    /// this initializer (see `applyingClick(on:hasShell:)`).
    public init(showsFiles: Bool, showsTerminal: Bool) {
        if !showsFiles && !showsTerminal {
            self.showsFiles = true
            self.showsTerminal = false
        } else {
            self.showsFiles = showsFiles
            self.showsTerminal = showsTerminal
        }
    }

    /// Both halves shown. A legal, storable state a session reaches by
    /// having both panes open when it was last used — NOT the value a
    /// session with no recorded preference resolves to; that is
    /// `filesOnly` below.
    public static let bothVisible = PaneVisibility(showsFiles: true, showsTerminal: true)

    /// What a session with NO recorded preference gets: files only, no
    /// terminal (maintainer ruling, whole-phase re-review, item 1).
    ///
    /// The ruling exists because the first spelling of this default
    /// (`bothVisible`) was wrong in a way no test observed, and its doc
    /// comment asserted the opposite of what it did: restoring a saved
    /// "terminal visible" OPENS the terminal and starts a shell, so a
    /// `sessions.json` written before this field existed — every session in
    /// every existing installation — would have opened a terminal on its
    /// next connect. "Files only" is what those sessions actually did
    /// before this field existed.
    ///
    /// The one spelling of that default, so its consumers cannot drift on
    /// what "nothing recorded" means: `StoredSession`'s `paneVisibility`
    /// property default and its `init(from:)` (`?? .filesOnly` on a missing
    /// key, coded like `kind`'s own `?? .ssh`), `SessionImportPlanner.
    /// makePlanned` for a file that carries no value, and `init(from:)`
    /// below for a value too broken to read. `ExportedSession`'s own
    /// decoder deliberately still decodes a missing key as `nil` — like
    /// `kind` there — and lets the planner resolve it.
    ///
    /// The asymmetry this creates is deliberate: an ABSENT field and an
    /// explicitly saved `{showsFiles: true, showsTerminal: false}` mean the
    /// same thing at connect time. What it must not collapse into is "a
    /// terminal is never restored" — an explicitly saved `showsTerminal:
    /// true` still opens one, which is what `SessionTabTests.
    /// aSessionThatSavedAVisibleTerminalGetsItBack` pins next to its
    /// legacy counterpart.
    public static let filesOnly = PaneVisibility(showsFiles: true, showsTerminal: false)

    /// The terminal alone, no file panes: the layout a session comes up in
    /// when it was opened through the sidebar row's "Open Terminal" entry
    /// (P3c/T2).
    ///
    /// A named constant rather than a `PaneVisibility(showsFiles: false,
    /// showsTerminal: true)` spelled out at the one call site, for the same
    /// reason `filesOnly` above is one: this is what a feature MEANS, and a
    /// second call site that ever wants the same layout must not have to
    /// re-derive which two booleans express it.
    ///
    /// NOT a stored default and never written to `StoredSession`: the entry
    /// picks this layout for the connect it starts, and the session's own
    /// saved `paneVisibility` is left exactly as it was — only a later
    /// toggle click persists anything (see `ContentView.
    /// persistActivePaneVisibility`).
    ///
    /// Safe on a backend without a shell even though nothing here folds
    /// `hasShell` in: `SessionTab.applyRestoredPaneVisibility` runs the
    /// terminal half through `effectivePaneVisibility`, which forces
    /// `showsTerminal` off without a shell and lets the repairing
    /// initializer promote files back on. The entry that produces this value
    /// is hidden for such a backend anyway (`SessionRowTerminalMenuPlan`).
    public static let terminalOnly = PaneVisibility(showsFiles: false, showsTerminal: true)

    /// Decodes leniently: a value that is BROKEN rather than merely absent
    /// falls back to `filesOnly`'s halves instead of throwing — the same
    /// "nothing usable recorded" default a missing key gets.
    ///
    /// This is a deliberate exception, and a narrow one. `StoredSession`'s
    /// container is decoded as ONE document by `SessionStore.load()`, so a
    /// throwing decode here does not cost the user this cosmetic preference
    /// — it costs them every saved session in the file. A field that only
    /// decides which half of a window is showing must not be able to do
    /// that. Compare `showsFiles`/`showsTerminal` with anything the store
    /// holds that a user could not reconstruct by looking at the window:
    /// there is nothing to lose here worth failing a load over.
    ///
    /// What this explicitly does NOT license: the project rule that no
    /// `try?` read may decide a DELETION still stands, unqualified. This
    /// falls back to a default for a cosmetic value; it never reads
    /// "absent/unreadable" as "the user does not want this" and acts on it.
    ///
    /// Each half falls back on its own, so a file that can still say one of
    /// the two is believed on that one (`{"showsFiles":"yes",
    /// "showsTerminal":false}` keeps the terminal half's `false`). Both
    /// results still go through the repairing initializer above, so
    /// leniency cannot produce "neither visible" either.
    ///
    /// Referring to `filesOnly` here is not recursive: that constant is
    /// built by the memberwise initializer above, never by this one.
    public init(from decoder: Decoder) throws {
        // A `paneVisibility` that is not even an object (a string, a number,
        // an array) leaves nothing to read per key — the whole value falls
        // back at once.
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            self.init(
                showsFiles: PaneVisibility.filesOnly.showsFiles,
                showsTerminal: PaneVisibility.filesOnly.showsTerminal)
            return
        }
        let showsFiles = (try? container.decode(Bool.self, forKey: .showsFiles))
            ?? PaneVisibility.filesOnly.showsFiles
        let showsTerminal = (try? container.decode(Bool.self, forKey: .showsTerminal))
            ?? PaneVisibility.filesOnly.showsTerminal
        // Via the repairing initializer above — a hand-edited store file
        // that carries "both false" is repaired to "files only" rather than
        // decoded as-is, which would render an empty window with no way
        // back to either half.
        self.init(showsFiles: showsFiles, showsTerminal: showsTerminal)
    }

    private enum CodingKeys: String, CodingKey {
        case showsFiles, showsTerminal
    }

    /// The state a toggle should render: whether it currently shows its half,
    /// and whether it can be clicked at all.
    ///
    /// A backend without a shell folds into the same repair the decoder
    /// uses: `showsTerminal` is first forced off when `hasShell` is `false`
    /// (there is no shell to show), and only THEN is the "neither half
    /// visible" repair applied — so a shell-less backend that still carries
    /// a stored `showsTerminal: true` (say, from before the backend changed)
    /// ends up with files as the one visible, locked half, exactly like any
    /// other single-half state. `hasShell` never disables the files toggle
    /// directly; it only ever removes the terminal half from consideration,
    /// and the ordinary lock rule does the rest.
    ///
    /// The lock itself: a half that is currently the only one visible cannot
    /// be turned off (`isEnabled == false`) — turning it off would leave the
    /// window empty. A half that is currently hidden can always be turned
    /// on, UNLESS it is the terminal on a backend without a shell, which has
    /// nothing to turn on.
    public func toggleState(for toggle: PaneToggle, hasShell: Bool) -> PaneToggleState {
        // Folds `hasShell` into the visibility itself: if the backend has no
        // shell, `showsTerminal` reads as `false` no matter what is stored,
        // and the repairing initializer promotes `showsFiles` if that would
        // otherwise leave nothing visible.
        let effective = PaneVisibility(
            showsFiles: showsFiles,
            showsTerminal: showsTerminal && hasShell)

        switch toggle {
        case .files:
            let isOn = effective.showsFiles
            let isOnlyVisibleHalf = isOn && !effective.showsTerminal
            return PaneToggleState(isOn: isOn, isEnabled: !isOnlyVisibleHalf)
        case .terminal:
            guard hasShell else { return PaneToggleState(isOn: false, isEnabled: false) }
            let isOn = effective.showsTerminal
            let isOnlyVisibleHalf = isOn && !effective.showsFiles
            return PaneToggleState(isOn: isOn, isEnabled: !isOnlyVisibleHalf)
        }
    }

    /// Applies a click on `toggle`: flips that half's visibility.
    ///
    /// `hasShell` is folded in exactly like `toggleState(for:hasShell:)`
    /// does, so the two ask the same question in only one place rather than
    /// each answering it independently: a terminal click on a shell-less
    /// backend is unconditionally a no-op HERE, not merely something a
    /// caller is expected to withhold after consulting `toggleState`. Two
    /// consequences:
    /// - `.terminal` with `hasShell == false` returns `self` unchanged —
    ///   there is nothing to turn on, so the click does not land.
    /// - `.files` folds `showsTerminal && hasShell` into the flipped value,
    ///   so turning files off cannot leave a `showsTerminal: true` that
    ///   `hasShell` would make ineffective anyway from standing in for a
    ///   real second visible half; the repairing initializer sees the same
    ///   "effectively nothing visible" `toggleState` would compute, and
    ///   promotes files back on.
    ///
    /// Safe to call on the toggle for the currently only visible half even
    /// though `toggleState(for:hasShell:)` reports it disabled: flipping it
    /// off lands on "neither visible", which the memberwise initializer
    /// repairs back to files-only, so that click is also a no-op rather than
    /// a way around the lock.
    public func applyingClick(on toggle: PaneToggle, hasShell: Bool) -> PaneVisibility {
        switch toggle {
        case .files:
            return PaneVisibility(showsFiles: !showsFiles, showsTerminal: showsTerminal && hasShell)
        case .terminal:
            guard hasShell else { return self }
            return PaneVisibility(showsFiles: showsFiles, showsTerminal: !showsTerminal)
        }
    }
}

/// Which of the two switchable halves a toggle click names.
public enum PaneToggle: Equatable, Sendable {
    case files, terminal
}

/// How a single pane toggle should render: on/off, and whether it can be
/// clicked. Disabled rather than silently inert, so the user can see why a
/// click on the last visible half's toggle would not land.
public struct PaneToggleState: Equatable, Sendable {
    public let isOn: Bool
    public let isEnabled: Bool

    public init(isOn: Bool, isEnabled: Bool) {
        self.isOn = isOn
        self.isEnabled = isEnabled
    }
}
