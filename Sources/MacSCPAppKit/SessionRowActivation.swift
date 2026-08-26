import SwiftUI
import macSCPCore

// The session sidebar's decidable parts: what an input on a row does, what
// the row draws, and when activating a row has to end someone else's
// rename. Split out of `SessionSidebar.swift` in fix round 2, and the split
// is load-bearing rather than tidiness — see `SessionRowConnectEffect`.

/// One input a session row can receive, at the coarseness
/// `SessionRowActivation` reads it — the row's modifiers and menu entry
/// forward these and decide nothing themselves.
/// `CaseIterable` on purpose: the tests that state "only these inputs ever
/// connect" iterate the whole enum, so a fifth input has to be classified
/// deliberately instead of slipping in unexamined behind a hand-written list.
enum SessionRowInput: Equatable, CaseIterable {
    case singleClick
    case doubleClick
    /// Return on the row that currently holds the sidebar's selection.
    case returnKey
    /// The row's own "Connect" context-menu entry — the one input that is
    /// not a gesture but a thing the user picked by name.
    case contextMenuEntry
}

/// The effect that moves the sidebar's selection onto a row.
///
/// A type of its own, holding the same closure shape its sibling holds,
/// for one reason: `SessionRowActivation.apply` takes both, and two
/// parameters of the same function type are interchangeable by a
/// one-token edit. Review round 2 planted exactly that — `onSelect:
/// onConnect` — and the whole suite stayed green while every single click
/// dialled a host. With distinct types that edit does not compile, which is
/// a class of mistake removed rather than a mistake watched for.
struct SessionRowSelectEffect<Value> {
    fileprivate let run: (Value) -> Void

    init(_ run: @escaping (Value) -> Void) {
        self.run = run
    }
}

/// The effect that opens a connection — the sidebar's whole ability to
/// obtain one, reduced to a value it can hold and hand over but not fire.
///
/// `run` is `fileprivate`, and that is why these types live in this file
/// rather than beside the view: nothing in `SessionSidebar.swift` can call
/// it. A connection can be obtained there in exactly one way — by handing
/// this effect to `apply`, which fires it only for `.selectAndConnect`.
/// Every other route is a compile error, including the three the reviewers
/// found by mutation and no test caught: putting this value in the select
/// slot, calling it from the function that moves the selection, and calling
/// it from the imported-hosts row.
///
/// This is the shape `ReconnectWiringGuardTests`' own header names as the
/// only real answer to a spelling that keeps escaping detection — "unable
/// to obtain a connection except through one type it must hold, which no
/// spelling can work around because there is nothing to spell" — applied
/// here to one view instead of the whole App layer.
///
/// What it does NOT cover, stated rather than implied: the sidebar's two
/// terminal callbacks, which connect as well and remain plain closures
/// (`SessionRowActivationWiringTests` covers the gesture side of that
/// instead), and any connect path in a different file — `ContentView`
/// constructs this effect and could dial without it.
struct SessionRowConnectEffect<Value> {
    fileprivate let run: (Value) -> Void

    init(_ run: @escaping (Value) -> Void) {
        self.run = run
    }
}

/// What a session row does with a `SessionRowInput`.
///
/// The rule this type exists for: a single click used to open a connection.
/// A sidebar row is the first thing a pointer lands on in this window, and
/// dialling a host — with its keychain read, its TOFU prompt and its new tab
/// — was one stray click away, with no way to merely point at a session
/// first. The rule is now Finder's: pointing and opening are two different
/// gestures.
///
/// A type rather than an `if` inside a gesture modifier, for the reason this
/// project has paid for repeatedly (see `SessionRowTerminalMenuPlan`): a
/// decision that only exists inside a SwiftUI body is a decision no test can
/// reach, and this one is about NOT doing something, which is the shape that
/// silently comes back.
///
/// `.doNothing` while a row is being renamed covers every gesture: the
/// inline rename field owns both the pointer and the keyboard while it is
/// up, and a click that re-selected the row underneath it would pull focus
/// out of the field and cancel the edit. The menu entry is deliberately not
/// subject to that — see `build`.
///
/// Untested claim, stated rather than implied: that macOS delivers a second
/// click as a `count: 2` tap and Return to the focused row at all. This type
/// only proves which activation each input maps to — the delivery is
/// AppKit's, and this project has no way to inject either (see
/// `SessionRowActivationWiringTests`' header).
enum SessionRowActivation: Equatable {
    /// The input is swallowed: nothing selected, nothing connected.
    case doNothing
    /// The row becomes the sidebar's selection, nothing more.
    case select
    /// The row becomes the selection AND a connection is opened — the
    /// selection first, so the connection always names the row the user can
    /// see is meant.
    case selectAndConnect

    /// Whether this activation changes anything at all.
    var acts: Bool { self != .doNothing }
    /// Whether this activation opens a connection.
    var connects: Bool { self == .selectAndConnect }

    /// `.contextMenuEntry` answers `.selectAndConnect` unconditionally: it
    /// is not a gesture whose meaning has to be inferred but an entry the
    /// user read and chose, so neither the rename guard nor the selection
    /// rule applies to it. A menu item that silently did nothing because
    /// the row happened to be in rename mode would be worse than the
    /// interruption — and the interruption is handled, since selecting the
    /// row takes focus off the field and the focus-loss handler cancels the
    /// edit the way it does for every other way of leaving it.
    ///
    /// It also selects, rather than connecting without selecting: after any
    /// route to a connection the highlight must name the row that was
    /// connected.
    static func build(
        for input: SessionRowInput, isRenaming: Bool, isSelected: Bool
    ) -> SessionRowActivation {
        switch input {
        case .contextMenuEntry:
            return .selectAndConnect
        case .singleClick:
            return isRenaming ? .doNothing : .select
        case .doubleClick:
            return isRenaming ? .doNothing : .selectAndConnect
        // A key press reaching a row the selection is not on names no
        // session the user pointed at; it is left unhandled so whatever
        // else the window would do with Return still can.
        case .returnKey:
            return isRenaming || !isSelected ? .doNothing : .selectAndConnect
        }
    }

    /// Runs the two effects a session row has, as this activation dictates,
    /// and reports whether either ran.
    ///
    /// The effects are applied here rather than by an `if activation
    /// .connects` at the call site, and this is the only place either is
    /// ever fired: their `run` is `fileprivate`, so no caller can invoke one
    /// itself. A condition written in a SwiftUI view is a condition a later
    /// edit can drop, and dropping THAT one turns every single click into a
    /// dial with a keychain read and a possible TOFU prompt behind it.
    ///
    /// `onSelect` runs before `onConnect` for `.selectAndConnect`, so the
    /// highlight already names the row by the time the connection starts.
    ///
    /// Generic in the value it hands both effects, so this type stays free
    /// of any knowledge about what a session is.
    @discardableResult
    func apply<Value>(
        to value: Value,
        onSelect: SessionRowSelectEffect<Value>,
        onConnect: SessionRowConnectEffect<Value>
    ) -> Bool {
        switch self {
        case .doNothing:
            return false
        case .select:
            onSelect.run(value)
            return true
        case .selectAndConnect:
            onSelect.run(value)
            onConnect.run(value)
            return true
        }
    }
}

/// Which background a session row draws, and in what order the three
/// reasons to draw one win.
///
/// Selection beats the connected state deliberately: the selection is the
/// row the double click and the Return key act on, so it has to be readable
/// at all times, while "this session is the active tab" keeps two channels
/// of its own on the same row — the phosphor dot and the row name's blue,
/// semibold treatment — that no background can take away.
enum SessionRowHighlight: Equatable {
    case selected
    case connected
    case hovered
    case none

    static func build(
        isActive: Bool, isSelected: Bool, isHovering: Bool
    ) -> SessionRowHighlight {
        if isSelected { return .selected }
        if isActive { return .connected }
        return isHovering ? .hovered : .none
    }

    /// The colour each case draws. Here rather than in the row so that the
    /// one claim a test CAN make about a background it cannot see — that
    /// the four cases are four different colours, so the highlight is a
    /// distinction and not a repainted default — is reachable
    /// (`SessionRowHighlightTests`).
    ///
    /// The selection tint is the hover tint deepened rather than a colour of
    /// its own: pointing at a row and having selected it are the same kind
    /// of statement about where the user is, one of them stronger.
    var fill: Color {
        switch self {
        case .selected: return Color.secondary.opacity(0.20)
        case .connected: return DesignTokens.remoteSoft
        case .hovered: return Color.secondary.opacity(0.08)
        case .none: return Color.clear
        }
    }
}

/// Whether activating one session row must first end an inline rename that
/// is open on a DIFFERENT row.
///
/// The failure this answers: activating a row moves the keyboard focus to
/// it, which takes the first responder out of the other row's rename field.
/// Left to the focus-loss handler alone, that row can keep drawing an
/// editable field with an uncommitted draft in it that nothing reaches —
/// it is not focusable while it is being renamed, and a click on it is
/// swallowed by the rename guard, so the only way back in is a click landing
/// precisely inside the field. Ending the rename deliberately, in the same
/// step that moves the focus, is what keeps that state from existing.
///
/// Cancels rather than commits, matching what this sidebar already does
/// whenever a rename loses focus: an edit is committed by Return or by the
/// menu, never by a click landing somewhere else.
enum SidebarRenameHandoff {
    static func endsOpenRename(renamingID: UUID?, activating session: UUID) -> Bool {
        guard let renamingID else { return false }
        return renamingID != session
    }
}
