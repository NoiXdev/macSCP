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

    /// The selection when the current mouse gesture began, read only while
    /// copy on select is on.
    private var selectionAtGestureStart: String?
    /// Whether SwiftTerm reported the selection turning on or off since the
    /// current mouse gesture began.
    private var selectionToggledDuringGesture = false

    // MARK: - Right click

    /// The right-click decision lives in the hook the snippet menu already
    /// uses: `NSView` asks `menu(for:)` what a right click opens, and
    /// SwiftTerm overrides neither that nor `rightMouseDown(with:)`
    /// (`TerminalContextMenuTests`). The attached menu is the snippet menu,
    /// and it is `nil` exactly when there are no snippets.
    ///
    /// The paste is SwiftTerm's own `paste(_:)`, the action ⌘V sends, so
    /// bracketed paste applies exactly as it does there. It happens only
    /// for a mouse click — a right-mouse-down, or a control-click — never
    /// for a menu request carrying another kind of event.
    override func menu(for event: NSEvent) -> NSMenu? {
        let isClick = event.type == .rightMouseDown
            || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
        guard isClick else { return super.menu(for: event) }
        switch TerminalRightClickPlan.action(
            pasteOnRightClick: pasteOnRightClick,
            optionPressed: event.modifierFlags.contains(.option),
            snippetsExist: self.menu != nil)
        {
        case .paste:
            paste(self)
            return nil
        case .snippetMenu, .systemDefault:
            return super.menu(for: event)
        }
    }

    // MARK: - Copy on select

    /// A selection is made by SwiftTerm inside `mouseDown(with:)` (double
    /// and triple click, shift-click) and `mouseDragged(with:)`, and a
    /// gesture ends in `mouseUp(with:)`. The start of the gesture is noted
    /// here, before SwiftTerm acts on the click.
    override func mouseDown(with event: NSEvent) {
        selectionAtGestureStart = copyOnSelect ? getSelection() : nil
        selectionToggledDuringGesture = false
        super.mouseDown(with: event)
    }

    /// SwiftTerm calls this whenever the selection turns on or off — not
    /// when an active selection is extended, which the text comparison in
    /// `TerminalCopyOnSelectPlan` covers.
    override func selectionChanged(source: Terminal) {
        selectionToggledDuringGesture = true
        super.selectionChanged(source: source)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        guard let text = TerminalCopyOnSelectPlan.textToCopy(
            enabled: copyOnSelect,
            selectionAtGestureStart: selectionAtGestureStart,
            selectionAtGestureEnd: copyOnSelect ? getSelection() : nil,
            selectionToggledDuringGesture: selectionToggledDuringGesture)
        else { return }
        copyPasteboard.clearContents()
        copyPasteboard.setString(text, forType: .string)
    }
}
