import AppKit
import Foundation
import Synchronization
import SwiftTerm
import SwiftUI
import Testing
import macSCPCore

@testable import MacSCPAppKit

/// Measures — hop by hop — why the embedded terminal keeps its size when the
/// window is resized (Polish milestone, Task 1). This suite writes no fix; it
/// exists to name which of three candidate causes is the real one:
///
/// - (a) SwiftUI never gives the hosted `TerminalView` a larger FRAME, so
///   SwiftTerm has nothing to recompute from.
/// - (b) The frame grows and SwiftTerm recomputes cols/rows, but the call is
///   swallowed on the way to the shell (`sizeChanged` -> `Coordinator` ->
///   `TerminalPanelViewModel.resize` -> `RemoteShell.resize`).
/// - (c) Everything local fires and the remote side ignores the
///   `WindowChangeRequest`.
///
/// The three tests below take the three hops apart, so a red run names the
/// hop rather than the symptom.
@Suite("Terminal resize measurement", .serialized)
@MainActor
struct SSHTerminalViewSizingTests {

    // MARK: - Doubles

    /// Records every `resize` the view model forwards. Nothing else about a
    /// shell matters here, so `output` stays open and `send` is a no-op.
    private final class RecordingShell: RemoteShell, Sendable {
        let output: AsyncThrowingStream<[UInt8], Error>
        private let continuation: AsyncThrowingStream<[UInt8], Error>.Continuation
        private let recorded = Mutex<[Size]>([])

        struct Size: Equatable, Sendable {
            let cols: Int
            let rows: Int
        }

        var resizes: [Size] { recorded.withLock { $0 } }

        init() {
            (output, continuation) = AsyncThrowingStream<[UInt8], Error>.makeStream()
        }

        func send(_ bytes: [UInt8]) async throws {}

        func resize(cols: Int, rows: Int) async throws {
            recorded.withLock { $0.append(Size(cols: cols, rows: rows)) }
        }

        func close() async { continuation.finish() }
    }

    /// Records what `TerminalView` reports upward, so hop 1 can be read
    /// without the view model behind it.
    private final class RecordingTerminalDelegate: NSObject, TerminalViewDelegate {
        struct Report: Equatable {
            let cols: Int
            let rows: Int
        }

        var reports: [Report] = []

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            reports.append(Report(cols: newCols, rows: newRows))
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }

    // MARK: - Helpers

    /// A settings store on a throwaway directory — never the app's own
    /// support directory.
    private func temporarySettingsStore() throws -> SettingsStore {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macSCPTerminalSizing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        return SettingsStore(directory: directory)
    }

    /// Holds an `openShell` call until it is opened, so a test can mount the
    /// panel while the view model is still `.opening` — the app's real
    /// order, in which the surface is on screen and laid out before any
    /// shell exists.
    private actor OpenGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var isOpen = false

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { self.continuation = $0 }
        }

        func open() {
            isOpen = true
            continuation?.resume()
            continuation = nil
        }
    }

    /// A view model whose shell is `shell`, already `.running`.
    private func runningViewModel(shell: RecordingShell) async throws -> TerminalPanelViewModel {
        let viewModel = TerminalPanelViewModel(openShell: { _, _, _ in shell })
        viewModel.openIfNeeded()
        for _ in 0..<200 where viewModel.state != .running {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(viewModel.state == .running)
        return viewModel
    }

    /// A window with the panel hosted in it at `size`, laid out.
    private func mountPanel(
        viewModel: TerminalPanelViewModel, settingsStore: SettingsStore, size: NSSize
    ) async throws -> (window: NSWindow, hosting: NSHostingView<HostedPanel>) {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false)
        let hosting = NSHostingView(
            rootView: HostedPanel(viewModel: viewModel, settingsStore: settingsStore))
        window.contentView = hosting
        try await setContentSize(size, window: window, hosting: hosting)
        return (window, hosting)
    }

    /// Resizes the window the way AppKit does on a user resize — the content
    /// view follows the content rect — and lets SwiftUI lay out.
    private func setContentSize(_ size: NSSize, window: NSWindow, hosting: NSView) async throws {
        window.setContentSize(size)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        hosting.layoutSubtreeIfNeeded()
    }

    private func firstTerminalView(in view: NSView) -> TerminalView? {
        if let terminal = view as? TerminalView { return terminal }
        for subview in view.subviews {
            if let found = firstTerminalView(in: subview) { return found }
        }
        return nil
    }

    /// The panel as `ContentView+Detail.terminalPanel(_:)` builds it: the
    /// representable inside a `ZStack`, carrying the shared inset. Measuring
    /// the bare representable instead would answer a question the app never
    /// asks.
    private struct HostedPanel: View {
        let viewModel: TerminalPanelViewModel
        let settingsStore: SettingsStore

        var body: some View {
            ZStack {
                Color(nsColor: DesignTokens.terminalBackground)
                SSHTerminalView(
                    viewModel: viewModel,
                    settingsStore: settingsStore,
                    snippetMenu: SnippetMenuModel.build(
                        snippets: [], isConnected: true, supportsShell: true),
                    onRunSnippet: { _, _ in })
                    .padding(.horizontal, DesignTokens.terminalPanelInsetHorizontal)
                    .padding(.vertical, DesignTokens.terminalPanelInsetVertical)
            }
        }
    }

    // MARK: - Hop 1: does SwiftUI resize the hosted terminal at all?

    /// Cause (a)'s measurement. A window is built at 800x600, the terminal is
    /// located inside the real SwiftUI hierarchy, and the window is then
    /// grown to 1200x900. Both the hosted view's FRAME and the emulator's
    /// cols/rows are read before and after.
    ///
    /// A frame that does not grow is cause (a): SwiftTerm's
    /// `setFrameSize` -> `processSizeChange` is the only thing that ever
    /// recomputes cols/rows, so nothing downstream can fire.
    @Test("A window resize reaches the hosted terminal's frame")
    func windowResizeReachesTheHostedTerminalFrame() async throws {
        let shell = RecordingShell()
        let viewModel = try await runningViewModel(shell: shell)
        let settingsStore = try temporarySettingsStore()
        let (window, hosting) = try await mountPanel(
            viewModel: viewModel, settingsStore: settingsStore,
            size: NSSize(width: 800, height: 600))

        let terminal = try #require(
            firstTerminalView(in: hosting),
            "no TerminalView in the hosted hierarchy — re-anchor this measurement")
        let frameBefore = terminal.frame
        let sizeBefore = (
            cols: terminal.getTerminal().cols, rows: terminal.getTerminal().rows)

        try await setContentSize(
            NSSize(width: 1200, height: 900), window: window, hosting: hosting)

        let frameAfter = terminal.frame
        let sizeAfter = (
            cols: terminal.getTerminal().cols, rows: terminal.getTerminal().rows)

        #expect(
            frameAfter.width > frameBefore.width && frameAfter.height > frameBefore.height,
            """
            The hosted terminal's frame did not grow with the window: \
            \(frameBefore.size) -> \(frameAfter.size). Cause (a).
            """)
        #expect(
            sizeAfter.cols > sizeBefore.cols && sizeAfter.rows > sizeBefore.rows,
            """
            The emulator kept its geometry: \(sizeBefore) -> \(sizeAfter) \
            (frame \(frameBefore.size) -> \(frameAfter.size)).
            """)
    }

    /// The same frame change with the view model taken out, so a red run
    /// above can be attributed: SwiftTerm's own `setFrameSize` ->
    /// `processSizeChange` -> `sizeChanged(source:newCols:newRows:)` is what
    /// every later hop hangs off, and this reads it directly.
    @Test("SwiftTerm reports a size change when its frame grows")
    func swiftTermReportsASizeChangeWhenItsFrameGrows() {
        let delegate = RecordingTerminalDelegate()
        let terminal = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        terminal.terminalDelegate = delegate
        delegate.reports.removeAll()

        terminal.frame = NSRect(x: 0, y: 0, width: 1200, height: 900)
        #expect(!delegate.reports.isEmpty, "no sizeChanged for a 800x600 -> 1200x900 frame")
        let last = delegate.reports.last
        #expect(last?.cols == terminal.getTerminal().cols)
        #expect(last?.rows == terminal.getTerminal().rows)
    }

    // MARK: - Hop 2: does a frame change reach the view model and the shell?

    /// Cause (b)'s measurement, with SwiftUI taken out of the picture: the
    /// frame is set by hand on a real `TerminalView` wired to the real
    /// `SSHTerminalView.Coordinator`, and the recording shell at the far end
    /// is read. Green here means the chain
    /// `setFrameSize` -> `sizeChanged` -> `Coordinator` ->
    /// `TerminalPanelViewModel.resize` -> `RemoteShell.resize` is intact and
    /// (b) is not the cause.
    @Test("A frame change travels from the terminal view to the shell")
    func frameChangeTravelsToTheShell() async throws {
        let shell = RecordingShell()
        let viewModel = try await runningViewModel(shell: shell)
        let coordinator = SSHTerminalView.Coordinator(viewModel: viewModel)

        let terminal = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        terminal.terminalDelegate = coordinator
        terminal.layoutSubtreeIfNeeded()
        let sizeBefore = (
            cols: terminal.getTerminal().cols, rows: terminal.getTerminal().rows)

        terminal.frame = NSRect(x: 0, y: 0, width: 1200, height: 900)
        terminal.layoutSubtreeIfNeeded()
        let sizeAfter = (
            cols: terminal.getTerminal().cols, rows: terminal.getTerminal().rows)
        #expect(
            sizeAfter.cols > sizeBefore.cols && sizeAfter.rows > sizeBefore.rows,
            "SwiftTerm did not recompute its geometry: \(sizeBefore) -> \(sizeAfter)")

        for _ in 0..<200 where shell.resizes.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(
            shell.resizes.last == RecordingShell.Size(cols: sizeAfter.cols, rows: sizeAfter.rows),
            """
            The shell saw \(shell.resizes) for an emulator geometry of \
            \(sizeAfter). Cause (b) if this is empty or stale.
            """)
    }

    /// The last local hop on its own, so a red run above cannot be blamed on
    /// it by elimination: `resize` forwards to the shell that is actually
    /// open, and is dropped (rather than queued) while none is.
    @Test("The view model forwards resize to the open shell")
    func viewModelForwardsResizeToTheShell() async throws {
        let shell = RecordingShell()
        let closedViewModel = TerminalPanelViewModel(openShell: { _, _, _ in shell })
        closedViewModel.resize(cols: 120, rows: 40)
        try await Task.sleep(for: .milliseconds(50))
        #expect(shell.resizes.isEmpty, "a resize without a shell must not reach one")

        let viewModel = try await runningViewModel(shell: shell)
        viewModel.resize(cols: 132, rows: 43)
        for _ in 0..<200 where shell.resizes.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(shell.resizes == [RecordingShell.Size(cols: 132, rows: 43)])
    }

    // MARK: - The app's own order: the surface is laid out before the shell exists

    /// The three tests above each open the shell FIRST and then move a
    /// frame. The app never does that. `TerminalPanelViewModel.toggle()`
    /// sets `isVisible` and calls `openIfNeeded()` in one synchronous step,
    /// so `state` is `.opening` by the time SwiftUI renders the panel — and
    /// `terminalPanel(_:)` draws `SSHTerminalView` for `.opening` as well as
    /// `.running`. The surface is therefore created, laid out, and reports
    /// its one and only `sizeChanged` for the mount while `shell` is still
    /// `nil`, and `resize(cols:rows:)`'s `guard let shell else { return }`
    /// drops it.
    ///
    /// Nothing sends it again: the shell is opened at the hardcoded 80x24 of
    /// `openIfNeeded()`, and `sizeChanged` only fires when the COMPUTED
    /// geometry changes, which it does not until the window moves. From
    /// there on the emulator draws at the window's geometry while the remote
    /// PTY keeps 80x24 — exactly the reported symptom.
    ///
    /// This is the measurement that names the cause, so it reads its
    /// postconditions BEFORE anything can heal them: the shell's record is
    /// snapshotted the moment the shell is running, not after a later
    /// resize.
    @Test(
        "The size the surface was laid out at reaches the shell that opens after it",
        .disabled("""
            measured 2026-09-03: cause (b) — the mount-time sizeChanged \
            (88x36) is dropped by TerminalPanelViewModel.resize's \
            `guard let shell` while the shell is still opening, and the shell \
            then opens at openIfNeeded()'s hardcoded 80x24; fixed in Task 2
            """))
    func theMountSizeReachesTheShellThatOpensAfterIt() async throws {
        let shell = RecordingShell()
        let gate = OpenGate()
        let requested = Mutex<[RecordingShell.Size]>([])
        let viewModel = TerminalPanelViewModel(openShell: { _, cols, rows in
            requested.withLock { $0.append(RecordingShell.Size(cols: cols, rows: rows)) }
            await gate.wait()
            return shell
        })
        let settingsStore = try temporarySettingsStore()

        // The app's order: open first, render second.
        viewModel.openIfNeeded()
        #expect(viewModel.state == .opening)
        let (_, hosting) = try await mountPanel(
            viewModel: viewModel, settingsStore: settingsStore,
            size: NSSize(width: 800, height: 600))
        let terminal = try #require(
            firstTerminalView(in: hosting),
            "no TerminalView in the hosted hierarchy — re-anchor this measurement")
        let laidOut = RecordingShell.Size(
            cols: terminal.getTerminal().cols, rows: terminal.getTerminal().rows)

        await gate.open()
        for _ in 0..<200 where viewModel.state != .running {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(viewModel.state == .running)
        // Give a forwarded resize the same room to arrive that the other
        // tests give it, then snapshot — nothing below may resize the window
        // first, or it would read the healed value.
        try await Task.sleep(for: .milliseconds(200))
        let seenByShell = shell.resizes

        #expect(
            requested.withLock { $0 } == [RecordingShell.Size(cols: 80, rows: 24)],
            "the shell is opened at openIfNeeded()'s hardcoded geometry")
        #expect(
            seenByShell.last == laidOut,
            """
            The surface was laid out at \(laidOut) while the shell was still \
            opening; the shell then opened at \(requested.withLock { $0 }) and \
            has seen \(seenByShell). The remote PTY therefore keeps the \
            initial 80x24 while the emulator draws \(laidOut).
            """)
    }

    /// The other half of the maintainer's report ("also in full screen"):
    /// once the shell IS running, does moving the window still reach it
    /// through the whole hosted path? Same mount order as the test above, so
    /// a green run here narrows the defect to the mount alone rather than to
    /// the resize path as a whole.
    @Test("A window resize after the shell is running reaches the shell")
    func aWindowResizeAfterTheShellIsRunningReachesTheShell() async throws {
        let shell = RecordingShell()
        let gate = OpenGate()
        let viewModel = TerminalPanelViewModel(openShell: { _, _, _ in
            await gate.wait()
            return shell
        })
        let settingsStore = try temporarySettingsStore()

        viewModel.openIfNeeded()
        let (window, hosting) = try await mountPanel(
            viewModel: viewModel, settingsStore: settingsStore,
            size: NSSize(width: 800, height: 600))
        await gate.open()
        for _ in 0..<200 where viewModel.state != .running {
            try await Task.sleep(for: .milliseconds(10))
        }

        try await setContentSize(
            NSSize(width: 1200, height: 900), window: window, hosting: hosting)
        let terminal = try #require(firstTerminalView(in: hosting))
        let grown = RecordingShell.Size(
            cols: terminal.getTerminal().cols, rows: terminal.getTerminal().rows)
        for _ in 0..<200 where shell.resizes.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(
            shell.resizes.last == grown,
            "the emulator grew to \(grown); the shell saw \(shell.resizes)")
    }
}
