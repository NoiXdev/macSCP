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
    /// Set when a control-click pasted, so its drags and its mouse-up are
    /// consumed too.
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
    /// **What the accessibility fallback actually sends is measured**
    /// (2026-09-27, the deferred minor of 2026-09-19 that asked for it).
    /// `NSView.accessibilityPerformShowMenu()` — the method behind
    /// `NSAccessibilityShowMenuAction`, and one that neither SwiftTerm's
    /// `TerminalView` nor this class overrides — synthesises a
    /// `.rightMouseDown` event carrying NO modifier flags and asks
    /// `menu(for:)` with it. `isControlClick` requires a `.leftMouseDown`
    /// carrying `.control`, so it cannot match that event at all: the
    /// fallback always gets the real menu, never the withheld answer, and
    /// never a paste. Measured 3 of 3 in a scratch AppKit binary on macOS
    /// 26.6.2 (build 25G83), both for an ordered-in window of an inactive
    /// app and for the key window of an active one — and in both the call
    /// arrived only after the window was ordered in, never for a window
    /// that had not been. The event shape it produces is exactly the one
    /// `TerminalMouseBehaviourTests.aMenuRequestNeverPastes` drives, and
    /// `TerminalMouseWiringGuardTests.thePlanIsAskedInOnePlace` is what
    /// holds `isControlClick` to naming `.leftMouseDown`. The one hop still
    /// unmeasured is VoiceOver itself reaching that action on this view,
    /// which needs VoiceOver and a running app: a sight check.
    ///
    /// The one answer it withholds is for a control-click that is to paste.
    /// `NSWindow` asks this BEFORE it delivers a control-click, and shows
    /// whatever comes back INSTEAD of calling `mouseDown(with:)` (measured
    /// 2026-09-18 with synthetic events through `NSWindow.sendEvent(_:)` on
    /// an invisible window that was not key, the view accepting the first
    /// mouse). **A key window routes it the same way**, measured 2026-09-27
    /// in the same scratch binary: with the app active and the window key,
    /// a `.leftMouseDown` carrying `.control` sent through
    /// `NSWindow.sendEvent(_:)` reached the lookup first and the press only
    /// after the lookup answered nothing, 3 of 3. Only the FIRST half of
    /// that sentence is measured on either window — what a non-nil answer
    /// does instead of the press stays a sight check, because a real answer
    /// opens a modal menu tracking loop: the probe that tried to measure it
    /// blocked there and had to be killed, 3 of 3.
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

    /// The movement of a control-click that pasted goes no further either.
    /// Under button-event tracking (`?1002h`, `?1003h`) SwiftTerm reports a
    /// drag as button 1 held and moving; with the press and the release
    /// both consumed, the application would see a button that never comes
    /// up. With mouse reporting off, it would start a selection under the
    /// paste.
    override func mouseDragged(with event: NSEvent) {
        if controlClickPasted { return }
        super.mouseDragged(with: event)
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
