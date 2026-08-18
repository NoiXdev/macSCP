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
/// guarding it separately — the same shape as `Snippet`'s single-line rule,
/// which lives in one initializer that both the public API and `Decodable`
/// call through, so a hand-edited `sessions.json` cannot smuggle "nothing
/// visible" past the rule the way a second, unchecked write path would let
/// it.
///
/// This type only decides WHICH halves are visible. It says nothing about
/// `TerminalPanelViewModel.isVisible`, the existing terminal-only toggle —
/// reconciling the two is a later task's decision.
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

    /// The default a session with no recorded preference gets (P2
    /// terminal-chrome milestone, Task 4) — both halves shown, matching what
    /// every session did before this type's persistence existed. The one
    /// spelling of that default, so its two actual consumers cannot drift
    /// apart on what "no preference recorded" means: `StoredSession`'s
    /// `paneVisibility` property default and its `init(from:)` (`?? .bothVisible`
    /// on a missing key, coded like `kind`'s own `?? .ssh`), and
    /// `SessionImportPlanner.makePlanned` (`fileSession.paneVisibility ??
    /// .bothVisible`, same shape as its `kind ?? .ssh` a few lines above).
    /// `ExportedSession`'s own decoder does NOT use this constant — it
    /// deliberately decodes a missing key as `nil`, exactly like `kind`
    /// stays `nil` there rather than being defaulted at decode time; only
    /// the planner resolves it. `ContentView.restorePaneVisibility` does not
    /// reference this constant either — it reads `StoredSession.
    /// paneVisibility` after that property has already resolved to a
    /// concrete value, so there is nothing left for it to default.
    public static let bothVisible = PaneVisibility(showsFiles: true, showsTerminal: true)

    /// Decodes leniently: a value that is BROKEN rather than merely absent
    /// falls back to `bothVisible`'s halves instead of throwing.
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
    /// Referring to `bothVisible` here is not recursive: that constant is
    /// built by the memberwise initializer above, never by this one.
    public init(from decoder: Decoder) throws {
        // A `paneVisibility` that is not even an object (a string, a number,
        // an array) leaves nothing to read per key — the whole value falls
        // back at once.
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            self.init(
                showsFiles: PaneVisibility.bothVisible.showsFiles,
                showsTerminal: PaneVisibility.bothVisible.showsTerminal)
            return
        }
        let showsFiles = (try? container.decode(Bool.self, forKey: .showsFiles))
            ?? PaneVisibility.bothVisible.showsFiles
        let showsTerminal = (try? container.decode(Bool.self, forKey: .showsTerminal))
            ?? PaneVisibility.bothVisible.showsTerminal
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
