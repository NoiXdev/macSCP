import AppKit
import Foundation
import ObjectiveC
import SwiftTerm
import Testing

@testable import MacSCPAppKit

/// Drives a real `MacSCPTerminalView` with real mouse events (next build of
/// 2026-09-17, Task 6; the hooks moved on 2026-09-18, review follow-ups
/// Task 8): what a right click and a control-click do under each setting,
/// and what the end of a selection gesture puts on the pasteboard.
///
/// No event loop: `rightMouseDown(with:)`, `menu(for:)`, `mouseDown(with:)`,
/// `mouseDragged(with:)` and `mouseUp(with:)` are called directly, in the
/// order `NSWindow` calls them. That order was measured on 2026-09-18 by
/// sending synthetic events through `NSWindow.sendEvent(_:)` to an
/// invisible, off-screen window that was not key, its view accepting the
/// first mouse (Task 8's report): a right click reaches
/// `rightMouseDown(with:)`, and `NSView`'s implementation of it asks
/// `menu(for:)`; a control-click asks `menu(for:)` FIRST and reaches
/// `mouseDown(with:)` only when that answered `nil`. The last hop — a real
/// key window and a menu popping up on screen — is a sight check.
///
/// The pasteboard is a private, uniquely named one per test, never
/// `NSPasteboard.general`: a test must not overwrite the clipboard of the
/// person running it, and `withTerminal` releases it on every exit. Paste
/// is recorded by overriding `paste(_:)` rather than performed, for the
/// same reason — a real paste reads the general pasteboard.
@Suite("Terminal mouse behaviour", .serialized)
@MainActor
struct TerminalMouseBehaviourTests {

    final class PasteRecordingTerminal: MacSCPTerminalView {
        var pastes = 0
        /// Every answer `MacSCPTerminalView.menu(for:)` gave, in order.
        var menuAnswers: [NSMenu?] = []
        override func paste(_ sender: Any) { pastes += 1 }
        /// Records what the production class answers, then gives `NSView`
        /// nothing to show: a menu popping up needs a window and a modal
        /// tracking loop, neither of which a test may start.
        override func menu(for event: NSEvent) -> NSMenu? {
            menuAnswers.append(super.menu(for: event))
            return nil
        }
    }

    /// Records every byte the view sends toward the host.
    final class SentBytes: NSObject, TerminalViewDelegate {
        var bytes: [UInt8] = []
        func send(source: TerminalView, data: ArraySlice<UInt8>) { bytes.append(contentsOf: data) }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }

    /// A terminal writing to a private pasteboard, released on every exit
    /// of `body` — a thrown `#require` included.
    private func withTerminal(
        _ body: (PasteRecordingTerminal, NSPasteboard) throws -> Void
    ) rethrows {
        let terminal = PasteRecordingTerminal(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("macSCP.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        terminal.copyPasteboard = pasteboard
        try body(terminal, pasteboard)
    }

    private func snippetMenu() -> NSMenu {
        let menu = NSMenu(title: "snippets")
        menu.addItem(NSMenuItem(title: "Entry", action: nil, keyEquivalent: ""))
        return menu
    }

    private func mouse(
        _ type: NSEvent.EventType, x: CGFloat, y: CGFloat, clickCount: Int = 1,
        modifiers: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type,
            location: NSPoint(x: x, y: y),
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: 1))
    }

    /// A point inside the first cell of the top row. The view is not
    /// flipped: SwiftTerm counts rows from `frame.height - y`.
    private func topRow(_ terminal: TerminalView, x: CGFloat = 1) -> (x: CGFloat, y: CGFloat) {
        (x, terminal.frame.height - 1)
    }

    private func doubleClick(_ terminal: TerminalView, x: CGFloat = 1) throws {
        let p = topRow(terminal, x: x)
        terminal.mouseDown(with: try mouse(.leftMouseDown, x: p.x, y: p.y, clickCount: 1))
        terminal.mouseUp(with: try mouse(.leftMouseUp, x: p.x, y: p.y, clickCount: 1))
        terminal.mouseDown(with: try mouse(.leftMouseDown, x: p.x, y: p.y, clickCount: 2))
        terminal.mouseUp(with: try mouse(.leftMouseUp, x: p.x, y: p.y, clickCount: 2))
    }

    private func click(_ terminal: TerminalView, x: CGFloat = 1) throws {
        let p = topRow(terminal, x: x)
        terminal.mouseDown(with: try mouse(.leftMouseDown, x: p.x, y: p.y, clickCount: 1))
        terminal.mouseUp(with: try mouse(.leftMouseUp, x: p.x, y: p.y, clickCount: 1))
    }

    /// A right click the way `NSWindow` delivers it.
    private func rightClick(_ terminal: TerminalView, modifiers: NSEvent.ModifierFlags = []) throws {
        terminal.rightMouseDown(with: try mouse(.rightMouseDown, x: 10, y: 10, modifiers: modifiers))
        terminal.rightMouseUp(with: try mouse(.rightMouseUp, x: 10, y: 10, modifiers: modifiers))
    }

    /// A control-click the way `NSWindow` delivers it (measured, see the
    /// suite comment): the menu lookup first, and the click itself only
    /// when the lookup came back empty. Returns whether the click reached
    /// `mouseDown(with:)`.
    @discardableResult
    ///
    /// `dragToX`, when given, moves the pointer to another cell while the
    /// button is down — a trackpad control-click routinely moves a pixel —
    /// and `afterPress` runs between the press and that movement.
    private func controlClick(
        _ terminal: PasteRecordingTerminal, modifiers: NSEvent.ModifierFlags = [], x: CGFloat = 10,
        dragToX: CGFloat? = nil, afterPress: () -> Void = {}
    ) throws -> Bool {
        let p = topRow(terminal, x: x)
        let down = try mouse(.leftMouseDown, x: p.x, y: p.y, modifiers: modifiers.union(.control))
        _ = terminal.menu(for: down)
        guard terminal.menuAnswers.last == .some(nil) else { return false }
        terminal.mouseDown(with: down)
        afterPress()
        var upX = p.x
        if let dragToX {
            terminal.mouseDragged(with: try mouse(
                .leftMouseDragged, x: dragToX, y: p.y, modifiers: modifiers.union(.control)))
            upX = dragToX
        }
        terminal.mouseUp(with: try mouse(.leftMouseUp, x: upX, y: p.y, modifiers: modifiers.union(.control)))
        return true
    }

    private static let sentinel = "clipboard before the gesture"

    // MARK: - Right click

    @Test("Paste on right click on: a right click pastes and asks for no menu")
    func rightClickPastesWhenTheSettingIsOn() throws {
        try withTerminal { terminal, _ in
            terminal.menu = snippetMenu()
            terminal.pasteOnRightClick = true
            try rightClick(terminal)
            #expect(terminal.pastes == 1)
            #expect(terminal.menuAnswers.isEmpty, "the paste must not go through the menu lookup")
        }
    }

    @Test("Paste on right click on, no snippets: a right click still pastes")
    func rightClickPastesWithoutSnippets() throws {
        try withTerminal { terminal, _ in
            terminal.pasteOnRightClick = true
            try rightClick(terminal)
            #expect(terminal.pastes == 1)
            #expect(terminal.menuAnswers.isEmpty)
        }
    }

    @Test("Paste on right click on: Option-right-click opens the snippet menu")
    func optionRightClickOpensTheSnippetMenu() throws {
        try withTerminal { terminal, _ in
            let menu = snippetMenu()
            terminal.menu = menu
            terminal.pasteOnRightClick = true
            try rightClick(terminal, modifiers: .option)
            #expect(terminal.menuAnswers == [menu])
            #expect(terminal.pastes == 0)
        }
    }

    @Test("Paste on right click on, no snippets: Option-right-click does nothing")
    func optionRightClickWithoutSnippetsDoesNothing() throws {
        try withTerminal { terminal, _ in
            terminal.pasteOnRightClick = true
            try rightClick(terminal, modifiers: .option)
            #expect(terminal.menuAnswers == [nil])
            #expect(terminal.pastes == 0)
        }
    }

    @Test("Paste on right click off: right click and Option-right-click open the snippet menu")
    func settingOffKeepsTheSnippetMenu() throws {
        try withTerminal { terminal, _ in
            let menu = snippetMenu()
            terminal.menu = menu
            #expect(terminal.pasteOnRightClick == false, "the view starts with the setting off")
            try rightClick(terminal)
            try rightClick(terminal, modifiers: .option)
            #expect(terminal.menuAnswers == [menu, menu])
            #expect(terminal.pastes == 0)
        }
    }

    /// A menu request that is not a real right mouse button — VoiceOver's
    /// "show menu", or anything else asking `menu(for:)` directly — opens
    /// the menu. Only the mouse button pastes.
    @Test("Paste on right click on: a menu request for a right click opens the menu and never pastes")
    func aMenuRequestNeverPastes() throws {
        try withTerminal { terminal, _ in
            let menu = snippetMenu()
            terminal.menu = menu
            terminal.pasteOnRightClick = true
            _ = terminal.menu(for: try mouse(.rightMouseDown, x: 10, y: 10))
            let key = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false,
                keyCode: 0))
            _ = terminal.menu(for: key)
            #expect(terminal.menuAnswers == [menu, menu])
            #expect(terminal.pastes == 0)
        }
    }

    /// Control-click is the right click of a one-button mouse. AppKit asks
    /// `menu(for:)` before it delivers the click, and shows whatever comes
    /// back INSTEAD of calling `mouseDown(with:)` (measured). So the lookup
    /// declines, and the click pastes where it lands.
    @Test("Paste on right click on: a control-click pastes from the click, not from the menu lookup")
    func controlClickPastes() throws {
        try withTerminal { terminal, _ in
            terminal.menu = snippetMenu()
            terminal.pasteOnRightClick = true
            let p = topRow(terminal)
            let down = try mouse(.leftMouseDown, x: p.x, y: p.y, modifiers: .control)
            _ = terminal.menu(for: down)
            // Read before the click: the lookup alone neither pastes nor
            // offers a menu that AppKit would show in the click's place.
            #expect(terminal.menuAnswers == [nil])
            #expect(terminal.pastes == 0)
            terminal.mouseDown(with: down)
            terminal.mouseUp(with: try mouse(.leftMouseUp, x: p.x, y: p.y, modifiers: .control))
            #expect(terminal.pastes == 1)
        }
    }

    @Test("Paste on right click on: Option-control-click opens the snippet menu")
    func optionControlClickOpensTheSnippetMenu() throws {
        try withTerminal { terminal, _ in
            let menu = snippetMenu()
            terminal.menu = menu
            terminal.pasteOnRightClick = true
            let reachedTheClick = try controlClick(terminal, modifiers: .option)
            #expect(reachedTheClick == false, "AppKit shows the menu instead")
            #expect(terminal.menuAnswers == [menu])
            #expect(terminal.pastes == 0)
        }
    }

    @Test("Paste on right click off: a control-click opens the snippet menu")
    func controlClickWithTheSettingOffOpensTheSnippetMenu() throws {
        try withTerminal { terminal, _ in
            let menu = snippetMenu()
            terminal.menu = menu
            let reachedTheClick = try controlClick(terminal)
            #expect(reachedTheClick == false, "AppKit shows the menu instead")
            #expect(terminal.menuAnswers == [menu])
            #expect(terminal.pastes == 0)
        }
    }

    /// The control-click that pastes is consumed whole: a remote
    /// application that asked for mouse reports sees neither its press nor
    /// its release, and the click does not end a copy-on-select gesture.
    @Test("Paste on right click on: a control-click paste is neither reported nor copied")
    func aControlClickPasteIsConsumedWhole() throws {
        try withTerminal { terminal, pasteboard in
            let sent = SentBytes()
            terminal.terminalDelegate = sent
            terminal.feed(text: "hello world")
            terminal.copyOnSelect = true
            terminal.pasteOnRightClick = true
            // A selection made just before, so a stale "changed" mark would
            // have something to copy again.
            try doubleClick(terminal)
            #expect(pasteboard.string(forType: .string) == "hello")
            pasteboard.clearContents()
            pasteboard.setString(Self.sentinel, forType: .string)
            terminal.feed(text: "\u{1b}[?1000h")
            sent.bytes = []
            // Positive first: a plain click IS reported once mouse
            // reporting is on, so the empty report below means something.
            try click(terminal)
            #expect(!sent.bytes.isEmpty)
            sent.bytes = []
            let reachedTheClick = try controlClick(terminal)
            #expect(reachedTheClick)
            #expect(terminal.pastes == 1)
            #expect(sent.bytes.isEmpty, "the control-click was reported to the host: \(sent.bytes)")
            #expect(pasteboard.string(forType: .string) == Self.sentinel)
        }
    }

    /// Button-event tracking (`?1002h`, tmux's mode) reports movement while
    /// a button is down. A control-click that pastes must not leak a drag
    /// report either: the application would see button 1 held, and the
    /// release that ends it is consumed (review of `7152f620`, Important 1).
    @Test("Paste on right click on: a control-click paste that moves sends no mouse report at all")
    func aControlClickPasteThatMovesIsNotReported() throws {
        try withTerminal { terminal, _ in
            let sent = SentBytes()
            terminal.terminalDelegate = sent
            terminal.feed(text: "hello world\u{1b}[?1002h")
            let far = topRow(terminal, x: 60).x

            // Positive controls first: the same movement IS reported when
            // nothing pastes — a plain press with the switch on…
            terminal.pasteOnRightClick = true
            let p = topRow(terminal)
            terminal.mouseDown(with: try mouse(.leftMouseDown, x: p.x, y: p.y))
            sent.bytes = []
            terminal.mouseDragged(with: try mouse(.leftMouseDragged, x: far, y: p.y))
            #expect(!sent.bytes.isEmpty, "a plain drag under ?1002h is reported")
            terminal.mouseUp(with: try mouse(.leftMouseUp, x: far, y: p.y))

            // …and a control-click with the switch off, which reaches
            // SwiftTerm as a plain click (no snippets, so no menu).
            terminal.pasteOnRightClick = false
            let reachedOff = try controlClick(terminal, dragToX: far, afterPress: { sent.bytes = [] })
            let movedWhileHeld = sent.bytes
            #expect(reachedOff)
            #expect(terminal.pastes == 0)
            #expect(!movedWhileHeld.isEmpty, "a control-click drag with the switch off is reported")

            // The paste: nothing at all reaches the host.
            terminal.pasteOnRightClick = true
            sent.bytes = []
            let reachedOn = try controlClick(terminal, dragToX: far)
            #expect(reachedOn)
            #expect(terminal.pastes == 1)
            #expect(sent.bytes.isEmpty, "the pasting control-click was reported to the host: \(sent.bytes)")
        }
    }

    /// Both switches off and no snippets: exactly the surface before the
    /// settings existed. A right click answers no menu and pastes nothing;
    /// a control-click is SwiftTerm's plain click (it clears a selection).
    @Test("Both switches off, no snippets: a right click does nothing and a control-click is a plain click")
    func bothSwitchesOffWithoutSnippets() throws {
        try withTerminal { terminal, pasteboard in
            #expect(terminal.pasteOnRightClick == false)
            #expect(terminal.copyOnSelect == false)
            #expect(terminal.menu == nil)
            terminal.feed(text: "hello world")
            try rightClick(terminal)
            #expect(terminal.menuAnswers == [nil])
            #expect(terminal.pastes == 0)

            try doubleClick(terminal)
            #expect(terminal.selectionActive, "there is a selection for the click to clear")
            pasteboard.clearContents()
            pasteboard.setString(Self.sentinel, forType: .string)
            let reached = try controlClick(terminal)
            #expect(reached, "no menu, so AppKit delivers the click")
            #expect(terminal.menuAnswers == [nil, nil])
            #expect(terminal.selectionActive == false, "SwiftTerm's mouseDown took it as a plain click")
            #expect(terminal.pastes == 0)
            #expect(pasteboard.string(forType: .string) == Self.sentinel)
        }
    }

    /// The right-click paste is SwiftTerm's own `paste(_:)` — the action ⌘V
    /// sends — so bracketed paste applies to it exactly as it does to ⌘V.
    /// The production class must not replace that implementation.
    @Test("The production terminal pastes through SwiftTerm's own paste(_:)")
    func theProductionTerminalKeepsSwiftTermsPaste() {
        let selector = #selector(TerminalView.paste(_:))
        #expect(class_getMethodImplementation(MacSCPTerminalView.self, selector)
            == class_getMethodImplementation(TerminalView.self, selector))
        // Positive beside it: the recording subclass DOES differ, so the
        // comparison above can tell an override from none.
        #expect(class_getMethodImplementation(PasteRecordingTerminal.self, selector)
            != class_getMethodImplementation(TerminalView.self, selector))
    }

    // MARK: - Copy on select

    @Test("The production terminal copies to the general pasteboard")
    func theDefaultPasteboardIsTheGeneralOne() {
        let terminal = MacSCPTerminalView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        #expect(terminal.copyPasteboard === NSPasteboard.general)
        #expect(terminal.copyOnSelect == false)
    }

    @Test("Copy on select on: a double click copies the word")
    func doubleClickCopiesTheWord() throws {
        try withTerminal { terminal, pasteboard in
            terminal.feed(text: "hello world")
            terminal.copyOnSelect = true
            try doubleClick(terminal)
            #expect(terminal.getSelection() == "hello")
            #expect(pasteboard.string(forType: .string) == "hello")
        }
    }

    @Test("Copy on select on: a drag copies what it selected")
    func dragCopiesTheSelection() throws {
        try withTerminal { terminal, pasteboard in
            terminal.feed(text: "hello world")
            terminal.copyOnSelect = true
            let start = topRow(terminal)
            let end = topRow(terminal, x: terminal.frame.width - 1)
            // A drag's first event only anchors the selection where it lands
            // (SwiftTerm starts it there), so the gesture is two drag events:
            // one on the start cell, one on the end.
            terminal.mouseDown(with: try mouse(.leftMouseDown, x: start.x, y: start.y))
            terminal.mouseDragged(with: try mouse(.leftMouseDragged, x: start.x, y: start.y))
            terminal.mouseDragged(with: try mouse(.leftMouseDragged, x: end.x, y: end.y))
            terminal.mouseUp(with: try mouse(.leftMouseUp, x: end.x, y: end.y))
            let selected = try #require(terminal.getSelection())
            #expect(selected.hasPrefix("hello world"))
            #expect(pasteboard.string(forType: .string) == selected)
        }
    }

    /// Measured while writing this suite: a drag that has not left its
    /// first cell leaves an ACTIVE selection whose text is empty. Copying it
    /// would wipe the clipboard with nothing.
    @Test("Copy on select on: a drag that selected nothing leaves the clipboard alone")
    func anEmptyDragCopiesNothing() throws {
        try withTerminal { terminal, pasteboard in
            terminal.feed(text: "hello world")
            terminal.copyOnSelect = true
            pasteboard.clearContents()
            pasteboard.setString(Self.sentinel, forType: .string)
            let start = topRow(terminal)
            terminal.mouseDown(with: try mouse(.leftMouseDown, x: start.x, y: start.y))
            terminal.mouseDragged(with: try mouse(.leftMouseDragged, x: start.x, y: start.y))
            terminal.mouseUp(with: try mouse(.leftMouseUp, x: start.x, y: start.y))
            // Positive first: there IS a selection, and it is empty.
            #expect(terminal.getSelection() == "")
            #expect(pasteboard.string(forType: .string) == Self.sentinel)
        }
    }

    @Test("Copy on select off: a double click selects but copies nothing")
    func settingOffCopiesNothing() throws {
        try withTerminal { terminal, pasteboard in
            pasteboard.clearContents()
            pasteboard.setString(Self.sentinel, forType: .string)
            terminal.feed(text: "hello world")
            try doubleClick(terminal)
            #expect(terminal.getSelection() == "hello")
            #expect(pasteboard.string(forType: .string) == Self.sentinel)
        }
    }

    @Test("Copy on select on: a plain click that clears the selection copies nothing")
    func aPlainClickCopiesNothing() throws {
        try withTerminal { terminal, pasteboard in
            terminal.feed(text: "hello world")
            try doubleClick(terminal)
            #expect(terminal.selectionActive, "there is a selection for the click to clear")
            terminal.copyOnSelect = true
            pasteboard.clearContents()
            pasteboard.setString(Self.sentinel, forType: .string)
            try click(terminal)
            #expect(terminal.selectionActive == false)
            #expect(pasteboard.string(forType: .string) == Self.sentinel)
        }
    }

    /// A remote application that asked for mouse reports takes the click;
    /// the old selection stays on screen untouched. Copying it again at
    /// mouse-up would put stale text over whatever the user copied since.
    @Test("Copy on select on: a click taken by mouse reporting does not re-copy an old selection")
    func aReportedClickDoesNotRecopyAStaleSelection() throws {
        try withTerminal { terminal, pasteboard in
            // Mouse reporting on first: output clears a selection, so the escape
            // sequence cannot come after the double click. Shift bypasses mouse
            // reporting, which is how a user selects under it at all.
            terminal.feed(text: "hello world\u{1b}[?1000h")
            let p = topRow(terminal)
            terminal.mouseDown(with: try mouse(
                .leftMouseDown, x: p.x, y: p.y, clickCount: 2, modifiers: .shift))
            terminal.mouseUp(with: try mouse(
                .leftMouseUp, x: p.x, y: p.y, clickCount: 2, modifiers: .shift))
            terminal.copyOnSelect = true
            pasteboard.clearContents()
            pasteboard.setString(Self.sentinel, forType: .string)
            try click(terminal)
            // Positive first: the old selection is still there to be copied.
            #expect(terminal.getSelection() == "hello")
            #expect(pasteboard.string(forType: .string) == Self.sentinel)
        }
    }

    private func drag(_ terminal: TerminalView, toX endX: CGFloat) throws {
        let start = topRow(terminal)
        let end = topRow(terminal, x: endX)
        terminal.mouseDown(with: try mouse(.leftMouseDown, x: start.x, y: start.y))
        terminal.mouseDragged(with: try mouse(.leftMouseDragged, x: start.x, y: start.y))
        terminal.mouseDragged(with: try mouse(.leftMouseDragged, x: end.x, y: end.y))
        terminal.mouseUp(with: try mouse(.leftMouseUp, x: end.x, y: end.y))
    }

    /// A new drag over exactly the text already selected starts and ends
    /// with the same text; only SwiftTerm reporting the selection changed
    /// in between tells it apart from a click that selected nothing.
    @Test("Copy on select on: dragging over the same text again copies it again")
    func redraggingTheSameTextCopiesAgain() throws {
        try withTerminal { terminal, pasteboard in
            terminal.feed(text: "hello world")
            terminal.copyOnSelect = true
            try drag(terminal, toX: terminal.frame.width - 1)
            let first = try #require(terminal.getSelection())
            pasteboard.clearContents()
            pasteboard.setString(Self.sentinel, forType: .string)
            try drag(terminal, toX: terminal.frame.width - 1)
            // Positive first: the second drag selected the same, non-empty text.
            #expect(!first.isEmpty)
            #expect(terminal.getSelection() == first)
            #expect(pasteboard.string(forType: .string) == first)
        }
    }

    @Test("Copy on select on: double-clicking the same word again copies it again")
    func reselectingTheSameWordCopiesAgain() throws {
        try withTerminal { terminal, pasteboard in
            terminal.feed(text: "hello world")
            terminal.copyOnSelect = true
            try doubleClick(terminal)
            pasteboard.clearContents()
            pasteboard.setString(Self.sentinel, forType: .string)
            try doubleClick(terminal)
            #expect(pasteboard.string(forType: .string) == "hello")
        }
    }

    /// A shift-click extends an active selection without turning it off or
    /// on. It still counts as a change: SwiftTerm reports every mutation of
    /// the selection, not only a toggle (pinned by the next test).
    @Test("Copy on select on: a shift-click that extends the selection copies the extended text")
    func aShiftClickExtensionCopies() throws {
        try withTerminal { terminal, pasteboard in
            terminal.feed(text: "hello world")
            try doubleClick(terminal)
            terminal.copyOnSelect = true
            pasteboard.clearContents()
            pasteboard.setString(Self.sentinel, forType: .string)
            let p = topRow(terminal, x: terminal.frame.width - 1)
            terminal.mouseDown(with: try mouse(.leftMouseDown, x: p.x, y: p.y, modifiers: .shift))
            terminal.mouseUp(with: try mouse(.leftMouseUp, x: p.x, y: p.y, modifiers: .shift))
            let extended = try #require(terminal.getSelection())
            // Positive first: the shift-click really did extend the word.
            #expect(extended.hasPrefix("hello world"))
            #expect(pasteboard.string(forType: .string) == extended)
        }
    }

    final class ChangeCountingTerminal: MacSCPTerminalView {
        var changes = 0
        override func selectionChanged(source: Terminal) {
            changes += 1
            super.selectionChanged(source: source)
        }
    }

    /// What copy on select counts on: SwiftTerm calls
    /// `selectionChanged(source:)` when an ACTIVE selection is extended,
    /// not only when it turns on or off. A SwiftTerm bump that stops doing
    /// so turns this red before it silently stops copying extensions.
    @Test("SwiftTerm reports an extension of an active selection, not only a toggle")
    func swiftTermReportsAnExtension() throws {
        let terminal = ChangeCountingTerminal(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        terminal.feed(text: "hello world")
        let start = topRow(terminal)
        let end = topRow(terminal, x: terminal.frame.width - 1)
        terminal.mouseDown(with: try mouse(.leftMouseDown, x: start.x, y: start.y))
        terminal.mouseDragged(with: try mouse(.leftMouseDragged, x: start.x, y: start.y))
        #expect(terminal.selectionActive, "the first drag event starts the selection")
        let before = terminal.changes
        terminal.mouseDragged(with: try mouse(.leftMouseDragged, x: end.x, y: end.y))
        #expect(terminal.selectionActive)
        #expect(terminal.changes > before)
    }
}
