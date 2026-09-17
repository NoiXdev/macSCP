/// What a right click on the terminal surface does, decided from the
/// "Paste on right click" setting, whether Option is held, and whether
/// there are snippets to offer (maintainer decision, 2026-09-16: two
/// separate switches, both default off; while paste on right click is on,
/// the snippet menu moves to Option-right-click).
///
/// With the setting off, Option changes nothing: the right click does what
/// it did before the setting existed.
enum TerminalRightClickPlan: Equatable, Sendable {
    /// Paste the clipboard, the way ⌘V does.
    case paste
    /// Open the snippet menu attached to the view.
    case snippetMenu
    /// Nothing of ours: whatever `NSView` resolves, which with no menu
    /// attached is no menu at all.
    case systemDefault

    static func action(
        pasteOnRightClick: Bool, optionPressed: Bool, snippetsExist: Bool
    ) -> TerminalRightClickPlan {
        if pasteOnRightClick && !optionPressed { return .paste }
        return snippetsExist ? .snippetMenu : .systemDefault
    }
}

/// Whether the end of a mouse gesture in the terminal copies the selection,
/// and which text.
///
/// Two conditions beyond the setting itself:
///
/// - The selection must be non-empty. A drag that has not left its first
///   cell leaves an active selection with empty text (measured in
///   `TerminalMouseBehaviourTests`); copying it would wipe the clipboard.
/// - The gesture must have changed the selection: its text differs from
///   the start of the gesture, or the selection went away and came back
///   during it. A click that a remote application takes for mouse
///   reporting leaves an older selection on screen untouched; copying that
///   again at mouse-up would put stale text over whatever the user copied
///   since.
enum TerminalCopyOnSelectPlan {
    static func textToCopy(
        enabled: Bool,
        selectionAtGestureStart: String?,
        selectionAtGestureEnd: String?,
        selectionToggledDuringGesture: Bool
    ) -> String? {
        guard enabled, let text = selectionAtGestureEnd, !text.isEmpty else { return nil }
        guard selectionToggledDuringGesture || selectionAtGestureStart != text else { return nil }
        return text
    }
}
