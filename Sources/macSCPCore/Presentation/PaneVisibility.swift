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
    public var showsFiles: Bool
    public var showsTerminal: Bool

    /// Repairs "neither half visible" by forcing `showsFiles` back on. This
    /// is the type's only entry point for its stored properties — `init(from:)`
    /// below constructs through it too — so the repair cannot be bypassed by
    /// constructing a value directly.
    public init(showsFiles: Bool, showsTerminal: Bool) {
        if !showsFiles && !showsTerminal {
            self.showsFiles = true
            self.showsTerminal = false
        } else {
            self.showsFiles = showsFiles
            self.showsTerminal = showsTerminal
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let showsFiles = try container.decode(Bool.self, forKey: .showsFiles)
        let showsTerminal = try container.decode(Bool.self, forKey: .showsTerminal)
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
    /// Safe to call on the toggle for the currently only visible half even
    /// though `toggleState(for:hasShell:)` reports it disabled: flipping it
    /// off lands on "neither visible", which the memberwise initializer
    /// repairs back to files-only, so the click is a no-op rather than a way
    /// around that lock. But this function takes no `hasShell`, so it does
    /// NOT defend the other reason a toggle can be disabled — a click on a
    /// shell-less backend's terminal toggle still flips `showsTerminal` on
    /// here, same as if a shell existed. Refusing that click belongs to the
    /// caller, which must not act on `applyingClick(on: .terminal)` when
    /// `toggleState(for: .terminal, hasShell: false)` reported the toggle
    /// disabled for lack of a shell — nothing in this file pins that the
    /// caller actually does.
    public func applyingClick(on toggle: PaneToggle) -> PaneVisibility {
        switch toggle {
        case .files:
            return PaneVisibility(showsFiles: !showsFiles, showsTerminal: showsTerminal)
        case .terminal:
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
