import AppKit
import ObjectiveC
import SwiftTerm
import SwiftUI
import Testing
import macSCPCore

@testable import MacSCPAppKit

/// Measures — rather than infers — whether the terminal surface can carry a
/// right-click menu at all, and what that menu then contains
/// (Terminal-Snippets milestone, Task 9).
///
/// The question this suite exists to answer could not be settled by reading
/// SwiftTerm's source. That `MacTerminalView` overrides neither
/// `rightMouseDown(with:)` nor `menu(for:)` says what SwiftTerm does NOT do;
/// it does not say that a menu set on the view arrives. So the first half of
/// this suite asks the runtime instead: which class each of the three
/// relevant method implementations actually comes from, and what a real
/// `TerminalView` returns when it is asked for the menu of a real
/// right-mouse-down event.
///
/// Not covered here, and not coverable in a `swift test` process: the last
/// hop, AppKit popping the resolved menu up on screen. Driving that needs a
/// window, a live event loop and a modal menu-tracking session; `NSView`'s
/// own `rightMouseDown(with:)` — measured below to exist and to be what
/// `TerminalView` inherits — is the documented place that display happens.
/// It is recorded as an open visual check in this task's report.
///
/// The second half is a first for this project: `NSHostingMenu` turns a
/// SwiftUI menu body into a real `NSMenu` in-process, so `SnippetMenuItems`'
/// rendered structure — which every earlier task in this milestone had to
/// declare untestable — can be asserted here.
@Suite("Terminal right-click menu", .serialized)
@MainActor
struct TerminalContextMenuTests {

    // MARK: - Helpers

    private func snippet(_ name: String, tags: [String] = []) -> Snippet {
        Snippet(name: name, command: "echo \(name)", tags: tags)
    }

    private func model(_ snippets: [Snippet]) -> SnippetMenuModel {
        SnippetMenuModel.build(snippets: snippets, isConnected: true, supportsShell: true)
    }

    /// A right-mouse-down event, the input `menu(for:)` takes.
    private func rightMouseDown() throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: NSPoint(x: 10, y: 10),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1))
    }

    /// Which class an instance method's implementation comes from, expressed
    /// as "is it the very same function pointer this other class has". Two
    /// classes share an `IMP` for a selector exactly when the subclass does
    /// not override it, so this is a direct reading of who handles the
    /// message — and unlike reading source, it also sees an override added
    /// by a future SwiftTerm bump.
    private func sharesImplementation(_ subclass: AnyClass, _ superclass: AnyClass, _ selector: Selector) -> Bool {
        class_getMethodImplementation(subclass, selector)
            == class_getMethodImplementation(superclass, selector)
    }

    // MARK: - Is the right-click available at all?

    @Test("SwiftTerm claims neither the right-click nor the menu lookup")
    func swiftTermDoesNotClaimTheRightClick() {
        #expect(sharesImplementation(
            TerminalView.self, NSView.self, #selector(NSResponder.rightMouseDown(with:))))
        #expect(sharesImplementation(
            TerminalView.self, NSView.self, #selector(NSView.menu(for:))))
        #expect(sharesImplementation(
            TerminalView.self, NSView.self, #selector(getter: NSView.menu)))
    }

    /// The other side of the same coin: `NSView` DOES override both, so the
    /// implementation `TerminalView` inherits is a real one and not
    /// `NSResponder`'s pass-it-along default.
    @Test("NSView itself implements the right-click and the menu lookup")
    func nsViewImplementsTheRightClickAndTheMenuLookup() {
        #expect(!sharesImplementation(
            NSView.self, NSResponder.self, #selector(NSResponder.rightMouseDown(with:))))
        #expect(!sharesImplementation(
            NSView.self, NSResponder.self, #selector(NSView.menu(for:))))
    }

    @Test("A right-mouse-down on a terminal resolves to the menu set on it")
    func theMenuSetOnTheTerminalIsWhatARightClickResolves() throws {
        let terminal = TerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let event = try rightMouseDown()
        #expect(terminal.menu == nil, "a fresh TerminalView carries no menu of its own")
        #expect(terminal.menu(for: event) == nil)

        let menu = NSMenu(title: "snippets")
        menu.addItem(NSMenuItem(title: "Entry", action: nil, keyEquivalent: ""))
        terminal.menu = menu
        #expect(terminal.menu(for: event) === menu)
    }

    /// A right-click has to land on the view the menu is set on. SwiftTerm
    /// puts three subviews inside the terminal; none of them takes the hit,
    /// and none carries a menu that could answer instead of ours.
    @Test("No terminal subview intercepts the click or the menu")
    func noSubviewInterceptsTheClickOrTheMenu() throws {
        let terminal = TerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let event = try rightMouseDown()
        #expect(terminal.hitTest(NSPoint(x: 10, y: 10)) === terminal)
        #expect(terminal.hitTest(NSPoint(x: 397, y: 100)) === terminal)
        for subview in terminal.subviews {
            #expect(
                subview.menu(for: event) == nil,
                "\(type(of: subview)) would answer the right-click with a menu of its own")
        }
    }

    // MARK: - What the menu contains

    @Test("The menu carries a submenu per tag and Insert/Execute per snippet")
    func theMenuCarriesInsertAndExecutePerSnippet() throws {
        let built = try #require(SSHTerminalView.snippetContextMenu(
            model: model([snippet("Tail log", tags: ["Docker"])]), action: { _, _ in }))
        built.update()

        #expect(built.items.map(\.title) == ["Docker"])
        let tagMenu = try #require(built.items.first?.submenu)
        tagMenu.update()
        #expect(tagMenu.items.map(\.title) == ["Tail log"])
        let snippetMenu = try #require(tagMenu.items.first?.submenu)
        snippetMenu.update()
        #expect(snippetMenu.items.map(\.title) == [
            L10n.string("menu.snippets.insert", "Insert"),
            L10n.string("menu.snippets.execute", "Execute"),
        ])
    }

    /// Untagged snippets render without a wrapping tag submenu — the same
    /// rule `SnippetMenuModel` states, here read off the built `NSMenu`.
    @Test("Untagged snippets sit at the top level of the menu")
    func untaggedSnippetsSitAtTheTopLevel() throws {
        let built = try #require(SSHTerminalView.snippetContextMenu(
            model: model([snippet("Disk free")]), action: { _, _ in }))
        built.update()
        #expect(built.items.map(\.title) == ["Disk free"])
    }

    /// Firing the two entries proves the wiring reaches the action closure
    /// AND which flag each one passes — the difference between inserting a
    /// command and running it on a remote host.
    @Test("Insert and Execute reach the action with the right flag")
    func insertAndExecuteReachTheActionWithTheRightFlag() throws {
        final class Recorder { var fired: [(String, Bool)] = [] }
        let recorder = Recorder()
        let built = try #require(SSHTerminalView.snippetContextMenu(
            model: model([snippet("Disk free")]),
            action: { snippet, execute in recorder.fired.append((snippet.name, execute)) }))
        built.update()

        let snippetMenu = try #require(built.items.first?.submenu)
        snippetMenu.update()
        for item in snippetMenu.items {
            let action = try #require(item.action)
            let target = try #require(item.target)
            _ = target.perform(action, with: item)
        }

        #expect(recorder.fired.map(\.0) == ["Disk free", "Disk free"])
        #expect(recorder.fired.map(\.1) == [false, true], "Insert passes false, Execute true")
    }

    /// The right-click menu is nothing BUT these entries, so the separator
    /// `SnippetMenuItems` draws for the surfaces that put something above it
    /// would be a stray leading line here. Measured as a real separator
    /// item, which is why `leadingDivider: false` exists.
    @Test("The right-click menu has no leading separator")
    func theMenuHasNoLeadingSeparator() throws {
        let entries = model([snippet("Disk free")])
        let built = try #require(SSHTerminalView.snippetContextMenu(
            model: entries, action: { _, _ in }))
        built.update()
        #expect(built.items.allSatisfy { !$0.isSeparatorItem })

        // Control: the same content WITH the divider does carry one, so the
        // expectation above is about the flag and not about a menu that
        // never had a separator to begin with.
        let withDivider = NSHostingMenu(rootView: SnippetMenuItems(model: entries) { _, _ in })
        withDivider.update()
        #expect(withDivider.items.first?.isSeparatorItem == true)
    }

    /// No snippets means no menu at all rather than an empty popup — the
    /// right mouse button then does exactly what it did before this feature
    /// existed, which is nothing.
    @Test("An empty snippet list attaches no menu")
    func anEmptySnippetListAttachesNoMenu() {
        #expect(SSHTerminalView.snippetContextMenu(model: model([]), action: { _, _ in }) == nil)
    }

    // MARK: - The flat list's per-row context menu (P3d, Task 3)

    /// The flat-list popover's per-row `.contextMenu` is not an `NSMenu`
    /// handed to AppKit directly the way `snippetContextMenu` is — it is
    /// SwiftUI's `.contextMenu` view modifier. `SnippetRowContextMenu`
    /// (`Sources/MacSCPAppKit/ContentView+Detail.swift`) is the extracted,
    /// standalone content of that closure, pulled out for exactly this: it
    /// can be handed to `NSHostingMenu` on its own, the same technique
    /// `theMenuCarriesInsertAndExecutePerSnippet()` above already uses for
    /// `SnippetMenuItems`, without needing to render the row's gestures or
    /// the popover around it.
    /// `SnippetListPlan.Row`'s own initializer is internal to `macSCPCore`
    /// (this test target imports it, but not `@testable`), so a row comes
    /// from `SnippetListPlan.build(model:)` — the real production path —
    /// rather than being constructed by hand. `isConnected: !disabled`
    /// is enough to drive `Row.isDisabled` either way; which of
    /// `SnippetMenuModel.DisabledReason`'s two cases produced it is
    /// `SnippetListPlanTests`' concern, not this suite's.
    private func rowContextMenu(
        disabled: Bool, onExecute: @escaping () -> Void = {}, onInsert: @escaping () -> Void = {},
        onPreview: @escaping () -> Void = {}
    ) throws -> NSMenu {
        let built = SnippetListPlan.build(model: SnippetMenuModel.build(
            snippets: [snippet("Tail log")], isConnected: !disabled, supportsShell: true))
        let row = try #require(built.first?.rows.first)
        #expect(row.isDisabled == disabled)
        let hosted = NSHostingMenu(rootView: SnippetRowContextMenu(
            row: row, onExecute: onExecute, onInsert: onInsert, onPreview: onPreview))
        hosted.update()
        return hosted
    }

    @Test("An enabled row's context menu offers Execute, Insert and Preview")
    func enabledRowOffersExecuteInsertAndPreview() throws {
        let menu = try rowContextMenu(disabled: false)
        #expect(menu.items.map(\.title) == [
            L10n.string("menu.snippets.execute", "Execute"),
            L10n.string("menu.snippets.insert", "Insert"),
            L10n.string("snippets.list.preview", "Preview"),
        ])
    }

    /// A disabled row (no connection, or a backend with no shell) still
    /// offers Preview — it only reveals command text, the same thing
    /// hovering already shows, so a disabled row needs no protection from
    /// it. Execute and Insert are withheld, matching the gate the menu
    /// surfaces already apply via `.disabled(entry.isDisabled)`.
    @Test("A disabled row's context menu withholds Execute and Insert but keeps Preview")
    func disabledRowWithholdsExecuteAndInsertButKeepsPreview() throws {
        let menu = try rowContextMenu(disabled: true)
        #expect(menu.items.map(\.title) == [L10n.string("snippets.list.preview", "Preview")])
    }

    /// Firing each item proves the wiring reaches the right closure, not
    /// just that the titles line up.
    @Test("Each row context-menu item reaches its own closure")
    func rowContextMenuItemsReachTheirOwnClosures() throws {
        final class Recorder { var fired: [String] = [] }
        let recorder = Recorder()
        let menu = try rowContextMenu(
            disabled: false,
            onExecute: { recorder.fired.append("execute") },
            onInsert: { recorder.fired.append("insert") },
            onPreview: { recorder.fired.append("preview") })
        for item in menu.items {
            let action = try #require(item.action)
            let target = try #require(item.target)
            _ = target.perform(action, with: item)
        }
        #expect(recorder.fired == ["execute", "insert", "preview"])
    }
}
