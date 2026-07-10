import AppKit
import SwiftTerm
import SwiftUI
import macSCPCore

/// SwiftTerms AppKit-TerminalView als SwiftUI-View, verdrahtet mit dem
/// TerminalPanelViewModel: Ausgabe-Bytes -> feed, Tastatur -> vm.send,
/// Resize -> vm.resize (SSH window-change).
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
        // setupOptions legt die Layer-Farbe nur einmal — nach Farbwechsel nachziehen:
        terminal.layer?.backgroundColor = DesignTokens.terminalBackground.cgColor

        viewModel.onOutput = { [weak terminal] bytes in
            terminal?.feed(byteArray: bytes[...])
        }
        // Beim (Wieder-)Einblenden gepufferte Ausgabe nachliefern, damit ein
        // Remount (⌘T aus/ein) den bisherigen Screen nicht verwirft.
        for chunk in viewModel.replayBuffer {
            terminal.feed(byteArray: chunk[...])
        }
        // SwiftTerm macht sich nicht selbst zum First Responder:
        DispatchQueue.main.async { [weak terminal] in
            guard let terminal else { return }
            terminal.window?.makeFirstResponder(terminal)
        }
        return terminal
    }

    func updateNSView(_ terminal: TerminalView, context: Context) {}

    /// TerminalViewDelegate-Aufrufe kommen auf dem Main-Thread (AppKit),
    /// das ViewModel ist @MainActor — assumeIsolated schlägt die Brücke.
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
