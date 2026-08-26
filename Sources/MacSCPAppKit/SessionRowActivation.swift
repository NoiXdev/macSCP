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
/// rather than in the one holding the view: no code in `SessionSidebar
/// .swift` can call it, unwrap it, reach it by key path, or pass it where
/// the selection effect belongs — each of those is a compile error, and
/// each was a green mutation before.
///
/// **What this is and is not.** It raises the cost of an accidental
/// connect from "write a plausible line" to "defeat the type system", and
/// that is the whole of the claim. It is not a capability boundary in the
/// sense `ReconnectWiringGuardTests`' header uses, and the difference is
/// worth stating because the last two rounds overstated it:
///
/// - `fileprivate` is a FILE boundary. An extension added to THIS file —
///   `var asClosure: (Value) -> Void { run }`, a `callAsFunction`,
///   `@dynamicMemberLookup` — hands the closure out in three lines, and no
///   guard in this project reads this file.
/// - `Mirror(reflecting:)` reads stored properties from anywhere,
///   visibility notwithstanding, and the cast succeeds at runtime.
///
/// Both are left open deliberately. The property worth having is that no
/// plausible future edit makes a single click connect by accident; nobody
/// writes reflection or a hand-out accessor by accident, and a guard
/// against either would be an anchor against a spelling — the exact move
/// three rounds have shown to lose.
///
/// Also outside it: the sidebar's two terminal callbacks, which connect as
/// well and remain plain closures (guarded, not typed — see
/// `SessionRowActivationWiringTests`), and any connect path in another file
/// — `ContentView` constructs this effect and can dial without it.
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
    /// interruption.
    ///
    /// What ends that rename is `SidebarRenameHandoff`, not this type and
    /// not SwiftUI: any activation that ACTS while a rename is open ends it
    /// first. An earlier version of this comment claimed instead that
    /// taking focus off the field would cancel the edit by itself — an
    /// untested runtime assertion, and the wrong one for a menu entry on
    /// the row being renamed, which left the draft neither committed nor
    /// discarded with a connection opening underneath it.
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
    /// `fileprivate`, because being internal made it the firing site: an
    /// activation is a value anyone can construct, so
    /// `SessionRowActivation.selectAndConnect.apply(to:…)` written into any
    /// function of the view dialled on every single click with the whole
    /// suite green. Round 2 turned an unguarded slot into an unguarded
    /// `self`. Callers now reach `perform`, which decides the activation
    /// itself and never hands one back.
    ///
    /// `onSelect` runs before `onConnect` for `.selectAndConnect`, so the
    /// highlight already names the row by the time the connection starts.
    ///
    /// Generic in the value it hands both effects, so this type stays free
    /// of any knowledge about what a session is.
    @discardableResult
    fileprivate func apply<Value>(
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

/// The one way to act on a session row: decide what an input means and run
/// the effects that follow, in a single call that never yields an
/// activation the caller could have chosen for itself.
///
/// Split from `build` (which stays reachable, and stays pure — it answers a
/// question and touches nothing) precisely so that holding an activation
/// and firing one are different capabilities. A view can ask what an input
/// would mean; it cannot pick the answer it would like to fire.
///
/// The two effects are separate types with `fileprivate` storage, so they
/// cannot be swapped for one another or unwrapped by a caller. What that
/// does NOT amount to is stated at `SessionRowConnectEffect`.
@discardableResult
func performSessionRowInput<Value>(
    _ input: SessionRowInput,
    on value: Value,
    isRenaming: Bool,
    isSelected: Bool,
    onSelect: SessionRowSelectEffect<Value>,
    onConnect: SessionRowConnectEffect<Value>
) -> Bool {
    SessionRowActivation.build(for: input, isRenaming: isRenaming, isSelected: isSelected)
        .apply(to: value, onSelect: onSelect, onConnect: onConnect)
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

/// Whether an input must first end an inline rename that is open.
///
/// The failure this answers: acting on a row moves the keyboard focus to
/// it, which takes the first responder out of whatever rename field held
/// it. Left to the focus-loss handler alone, that row can keep drawing an
/// editable field with an uncommitted draft in it that nothing reaches —
/// it is not focusable while it is being renamed, and a click on it is
/// swallowed by the rename guard, so the only way back in is a click
/// landing precisely inside the field. Ending the rename deliberately, in
/// the same step that moves the focus, is what keeps that state from
/// existing.
///
/// The rule is "any activation that ACTS ends any open rename", which is
/// both simpler and wider than the "a rename on a DIFFERENT row" it
/// replaced. That earlier rule was correct only while an activation on the
/// renamed row was always `.doNothing`; `.contextMenuEntry` broke that, and
/// the case fell through the gap — the entry connected while the field
/// stayed open with a draft that was neither committed nor discarded. The
/// `acts` half is inside this function rather than an `if` beside its call
/// for the reason this task has now paid for repeatedly: a condition in a
/// view is a condition no test reaches.
///
/// Cancels rather than commits, matching what this sidebar already does
/// whenever a rename loses focus: an edit is committed by Return or by the
/// menu, never by a click landing somewhere else.
enum SidebarRenameHandoff {
    static func endsOpenRename(
        renamingID: UUID?, input: SessionRowInput, isRenaming: Bool, isSelected: Bool
    ) -> Bool {
        guard renamingID != nil else { return false }
        return SessionRowActivation.build(
            for: input, isRenaming: isRenaming, isSelected: isSelected).acts
    }
}
