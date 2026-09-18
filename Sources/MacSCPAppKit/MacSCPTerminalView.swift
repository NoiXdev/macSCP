import AppKit
import SwiftTerm

/// SwiftTerm's `TerminalView` with the two mouse settings of the terminal
/// tab: copy on select and paste on right click (next build of 2026-09-17,
/// Task 6). Everything else is SwiftTerm's.
///
/// `SSHTerminalView` builds this class and hands it both settings on every
/// render.
class MacSCPTerminalView: TerminalView {
    /// `SettingsStore.terminalCopyOnSelect`.
    var copyOnSelect = false
    /// `SettingsStore.terminalPasteOnRightClick`.
    var pasteOnRightClick = false
    /// Where copy on select writes. The general pasteboard in the app; a
    /// test hands in a private one so it never overwrites the clipboard of
    /// whoever runs the suite.
    var copyPasteboard: NSPasteboard = NSPasteboard.general

    /// Whether SwiftTerm reported a selection change since the current
    /// mouse gesture began.
    private var selectionChangedDuringGesture = false
    /// Set when a control-click pasted, so its mouse-up is consumed too.
    private var controlClickPasted = false

    // MARK: - Right click

    /// What a right click with `event`'s modifiers does. The one place the
    /// plan is asked; the three hooks below act on its answer.
    private func rightClickAction(for event: NSEvent) -> TerminalRightClickPlan {
        TerminalRightClickPlan.action(
            pasteOnRightClick: pasteOnRightClick,
            optionPressed: event.modifierFlags.contains(.option),
            snippetsExist: self.menu != nil)
    }

    /// A left-mouse-down with Control held: the right click of a one-button
    /// mouse.
    private static func isControlClick(_ event: NSEvent) -> Bool {
        event.type == .leftMouseDown && event.modifierFlags.contains(.control)
    }

    /// The real right mouse button. SwiftTerm overrides neither this nor
    /// `menu(for:)` (`TerminalContextMenuTests`); `NSView`'s implementation
    /// asks `menu(for:)` and pops the answer up, which is what every answer
    /// but a paste still gets.
    ///
    /// The paste is SwiftTerm's own `paste(_:)`, the action ⌘V sends, so
    /// bracketed paste applies exactly as it does there.
    override func rightMouseDown(with event: NSEvent) {
        guard rightClickAction(for: event) == .paste else {
            super.rightMouseDown(with: event)
            return
        }
        paste(self)
    }

    /// The menu lookup never pastes: anything that asks for the menu
    /// without a mouse button behind it — VoiceOver's "show menu", for
    /// one — gets the snippet menu, as it did before the setting existed.
    ///
    /// The one answer it withholds is for a control-click that is to paste.
    /// `NSWindow` asks this BEFORE it delivers a control-click, and shows
    /// whatever comes back INSTEAD of calling `mouseDown(with:)` (measured
    /// 2026-09-18 with synthetic events through `NSWindow.sendEvent(_:)` on
    /// an invisible window that was not key, the view accepting the first
    /// mouse; a key window was not measured).
    /// Declining lets the click through to `mouseDown(with:)`, which pastes.
    override func menu(for event: NSEvent) -> NSMenu? {
        if Self.isControlClick(event) && rightClickAction(for: event) == .paste {
            return nil
        }
        return super.menu(for: event)
    }

    // MARK: - Left button: control-click and copy on select

    /// A control-click that is to paste pastes here and goes no further:
    /// SwiftTerm's own `mouseDown(with:)` would take it for a plain click
    /// (clearing the selection, or reporting it to a remote application
    /// that asked for mouse reports).
    ///
    /// Anything else starts a gesture. A selection is made by SwiftTerm
    /// inside `mouseDown(with:)` (double and triple click, shift-click) and
    /// `mouseDragged(with:)`, and a gesture ends in `mouseUp(with:)`.
    override func mouseDown(with event: NSEvent) {
        selectionChangedDuringGesture = false
        controlClickPasted = false
        if Self.isControlClick(event) && rightClickAction(for: event) == .paste {
            controlClickPasted = true
            paste(self)
            return
        }
        super.mouseDown(with: event)
    }

    /// SwiftTerm calls this for every change of the selection: turning it
    /// on or off, and extending an active one
    /// (`TerminalMouseBehaviourTests` pins the extension case).
    override func selectionChanged(source: Terminal) {
        selectionChangedDuringGesture = true
        super.selectionChanged(source: source)
    }

    /// The selection text is built only when the plan asks for it — the
    /// setting on and the gesture having changed the selection — not on
    /// every click.
    override func mouseUp(with event: NSEvent) {
        if controlClickPasted {
            controlClickPasted = false
            return
        }
        super.mouseUp(with: event)
        let changed = selectionChangedDuringGesture
        selectionChangedDuringGesture = false
        guard let text = TerminalCopyOnSelectPlan.textToCopy(
            enabled: copyOnSelect,
            selectionChangedDuringGesture: changed,
            selection: { getSelection() })
        else { return }
        copyPasteboard.clearContents()
        copyPasteboard.setString(text, forType: .string)
    }
}
