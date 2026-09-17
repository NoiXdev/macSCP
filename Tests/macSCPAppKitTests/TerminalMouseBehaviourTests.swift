import AppKit
import Foundation
import ObjectiveC
import SwiftTerm
import Testing

@testable import MacSCPAppKit

/// Drives a real `MacSCPTerminalView` with real mouse events (next build of
/// 2026-09-17, Task 6): what a right click does under each setting, and
/// what the end of a selection gesture puts on the pasteboard.
///
/// No window, no event loop: `menu(for:)`, `mouseDown(with:)`,
/// `mouseDragged(with:)` and `mouseUp(with:)` are called directly, the way
/// `TerminalContextMenuTests` asks for the menu of a right-mouse-down. The
/// last hop — AppKit delivering a click and popping a menu up — is not
/// covered here and is a sight check.
///
/// The pasteboard is a private, uniquely named one per test, never
/// `NSPasteboard.general`: a test must not overwrite the clipboard of the
/// person running it. Paste is recorded by overriding `paste(_:)` rather
/// than performed, for the same reason — a real paste reads the general
/// pasteboard.
@Suite("Terminal mouse behaviour", .serialized)
@MainActor
struct TerminalMouseBehaviourTests {

    final class PasteRecordingTerminal: MacSCPTerminalView {
        var pastes = 0
        override func paste(_ sender: Any) { pastes += 1 }
    }

    private func makeTerminal() -> (PasteRecordingTerminal, NSPasteboard) {
        let terminal = PasteRecordingTerminal(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("macSCP.tests.\(UUID().uuidString)"))
        terminal.copyPasteboard = pasteboard
        return (terminal, pasteboard)
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

    private static let sentinel = "clipboard before the gesture"

    // MARK: - Right click

    @Test("Paste on right click on: a right click pastes and opens no menu")
    func rightClickPastesWhenTheSettingIsOn() throws {
        let (terminal, _) = makeTerminal()
        terminal.menu = snippetMenu()
        terminal.pasteOnRightClick = true
        let resolved = terminal.menu(for: try mouse(.rightMouseDown, x: 10, y: 10))
        #expect(resolved == nil)
        #expect(terminal.pastes == 1)
    }

    @Test("Paste on right click on, no snippets: a right click still pastes")
    func rightClickPastesWithoutSnippets() throws {
        let (terminal, _) = makeTerminal()
        terminal.pasteOnRightClick = true
        #expect(terminal.menu(for: try mouse(.rightMouseDown, x: 10, y: 10)) == nil)
        #expect(terminal.pastes == 1)
    }

    @Test("Paste on right click on: Option-right-click opens the snippet menu")
    func optionRightClickOpensTheSnippetMenu() throws {
        let (terminal, _) = makeTerminal()
        let menu = snippetMenu()
        terminal.menu = menu
        terminal.pasteOnRightClick = true
        let resolved = terminal.menu(for: try mouse(.rightMouseDown, x: 10, y: 10, modifiers: .option))
        #expect(resolved === menu)
        #expect(terminal.pastes == 0)
    }

    @Test("Paste on right click on, no snippets: Option-right-click does nothing")
    func optionRightClickWithoutSnippetsDoesNothing() throws {
        let (terminal, _) = makeTerminal()
        terminal.pasteOnRightClick = true
        #expect(terminal.menu(for: try mouse(.rightMouseDown, x: 10, y: 10, modifiers: .option)) == nil)
        #expect(terminal.pastes == 0)
    }

    @Test("Paste on right click off: right click and Option-right-click open the snippet menu")
    func settingOffKeepsTheSnippetMenu() throws {
        let (terminal, _) = makeTerminal()
        let menu = snippetMenu()
        terminal.menu = menu
        #expect(terminal.pasteOnRightClick == false, "the view starts with the setting off")
        #expect(terminal.menu(for: try mouse(.rightMouseDown, x: 10, y: 10)) === menu)
        #expect(terminal.menu(for: try mouse(.rightMouseDown, x: 10, y: 10, modifiers: .option)) === menu)
        #expect(terminal.pastes == 0)
    }

    /// Control-click is the right click of a one-button mouse. If AppKit
    /// asks for its menu, the event is a left-mouse-down carrying
    /// `.control`; whether it asks at all on this view — SwiftTerm's own
    /// `mouseDown(with:)` does not call `super` — is not measured here and
    /// is a sight check.
    @Test("Paste on right click on: a control-click pastes too")
    func controlClickPastes() throws {
        let (terminal, _) = makeTerminal()
        terminal.menu = snippetMenu()
        terminal.pasteOnRightClick = true
        #expect(terminal.menu(for: try mouse(.leftMouseDown, x: 10, y: 10, modifiers: .control)) == nil)
        #expect(terminal.pastes == 1)
    }

    /// `menu(for:)` takes any event. Only a mouse click pastes; a menu
    /// request carrying anything else gets the menu as before, so no
    /// caller other than a click can trigger a paste through this hook.
    @Test("Paste on right click on: a menu request that is not a click does not paste")
    func aMenuRequestThatIsNotAClickDoesNotPaste() throws {
        let (terminal, _) = makeTerminal()
        let menu = snippetMenu()
        terminal.menu = menu
        terminal.pasteOnRightClick = true
        let key = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false,
            keyCode: 0))
        #expect(terminal.menu(for: key) === menu)
        #expect(terminal.pastes == 0)
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
        let (terminal, pasteboard) = makeTerminal()
        defer { pasteboard.releaseGlobally() }
        terminal.feed(text: "hello world")
        terminal.copyOnSelect = true
        try doubleClick(terminal)
        #expect(terminal.getSelection() == "hello")
        #expect(pasteboard.string(forType: .string) == "hello")
    }

    @Test("Copy on select on: a drag copies what it selected")
    func dragCopiesTheSelection() throws {
        let (terminal, pasteboard) = makeTerminal()
        defer { pasteboard.releaseGlobally() }
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

    /// Measured while writing this suite: a drag that has not left its
    /// first cell leaves an ACTIVE selection whose text is empty. Copying it
    /// would wipe the clipboard with nothing.
    @Test("Copy on select on: a drag that selected nothing leaves the clipboard alone")
    func anEmptyDragCopiesNothing() throws {
        let (terminal, pasteboard) = makeTerminal()
        defer { pasteboard.releaseGlobally() }
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

    @Test("Copy on select off: a double click selects but copies nothing")
    func settingOffCopiesNothing() throws {
        let (terminal, pasteboard) = makeTerminal()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString(Self.sentinel, forType: .string)
        terminal.feed(text: "hello world")
        try doubleClick(terminal)
        #expect(terminal.getSelection() == "hello")
        #expect(pasteboard.string(forType: .string) == Self.sentinel)
    }

    @Test("Copy on select on: a plain click that clears the selection copies nothing")
    func aPlainClickCopiesNothing() throws {
        let (terminal, pasteboard) = makeTerminal()
        defer { pasteboard.releaseGlobally() }
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

    /// A remote application that asked for mouse reports takes the click;
    /// the old selection stays on screen untouched. Copying it again at
    /// mouse-up would put stale text over whatever the user copied since.
    @Test("Copy on select on: a click taken by mouse reporting does not re-copy an old selection")
    func aReportedClickDoesNotRecopyAStaleSelection() throws {
        let (terminal, pasteboard) = makeTerminal()
        defer { pasteboard.releaseGlobally() }
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

    private func drag(_ terminal: TerminalView, toX endX: CGFloat) throws {
        let start = topRow(terminal)
        let end = topRow(terminal, x: endX)
        terminal.mouseDown(with: try mouse(.leftMouseDown, x: start.x, y: start.y))
        terminal.mouseDragged(with: try mouse(.leftMouseDragged, x: start.x, y: start.y))
        terminal.mouseDragged(with: try mouse(.leftMouseDragged, x: end.x, y: end.y))
        terminal.mouseUp(with: try mouse(.leftMouseUp, x: end.x, y: end.y))
    }

    /// A new drag over exactly the text already selected starts and ends
    /// with the same text; only the selection turning off and on again in
    /// between tells it apart from a click that selected nothing.
    @Test("Copy on select on: dragging over the same text again copies it again")
    func redraggingTheSameTextCopiesAgain() throws {
        let (terminal, pasteboard) = makeTerminal()
        defer { pasteboard.releaseGlobally() }
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

    @Test("Copy on select on: double-clicking the same word again copies it again")
    func reselectingTheSameWordCopiesAgain() throws {
        let (terminal, pasteboard) = makeTerminal()
        defer { pasteboard.releaseGlobally() }
        terminal.feed(text: "hello world")
        terminal.copyOnSelect = true
        try doubleClick(terminal)
        pasteboard.clearContents()
        pasteboard.setString(Self.sentinel, forType: .string)
        try doubleClick(terminal)
        #expect(pasteboard.string(forType: .string) == "hello")
    }
}
