import AppKit
import SwiftTerm
import SwiftUI
import macSCPCore

/// SwiftTerm's AppKit `TerminalView` wrapped as a SwiftUI view, wired to the
/// `TerminalPanelViewModel`: output bytes -> feed, keyboard -> vm.send,
/// resize -> vm.resize (SSH window-change).
struct SSHTerminalView: NSViewRepresentable {
    let viewModel: TerminalPanelViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    func makeNSView(context: Context) -> TerminalView {
        let terminal = TerminalView(frame: .zero)
        terminal.terminalDelegate = context.coordinator
        terminal.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        terminal.nativeBackgroundColor = DesignTokens.terminalBackground
        terminal.nativeForegroundColor = DesignTokens.terminalText
        terminal.caretColor = DesignTokens.terminalText
        // setupOptions sets the layer color only once — re-apply it after a color change:
        terminal.layer?.backgroundColor = DesignTokens.terminalBackground.cgColor

        viewModel.onOutput = { [weak terminal] bytes in
            terminal?.feed(byteArray: bytes[...])
        }
        // Replay buffered output on (re-)show, so a remount (⌘T off/on)
        // doesn't discard the existing screen.
        for chunk in viewModel.replayBuffer {
            terminal.feed(byteArray: chunk[...])
        }
        // SwiftTerm doesn't make itself the first responder:
        DispatchQueue.main.async { [weak terminal] in
            guard let terminal else { return }
            terminal.window?.makeFirstResponder(terminal)
        }
        return terminal
    }

    func updateNSView(_ terminal: TerminalView, context: Context) {}

    /// `TerminalViewDelegate` calls arrive on the main thread (AppKit);
    /// the view model is `@MainActor` — `assumeIsolated` bridges the gap.
    final class Coordinator: NSObject, TerminalViewDelegate {
        private let viewModel: TerminalPanelViewModel

        init(viewModel: TerminalPanelViewModel) {
            self.viewModel = viewModel
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            let bytes = Array(data)
            MainActor.assumeIsolated { viewModel.send(bytes) }
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            MainActor.assumeIsolated { viewModel.resize(cols: newCols, rows: newRows) }
        }

        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
