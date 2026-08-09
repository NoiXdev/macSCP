import AppKit
import SwiftTerm
import SwiftUI
import macSCPCore

/// SwiftTerm's AppKit `TerminalView` wrapped as a SwiftUI view, wired to the
/// `TerminalPanelViewModel`: output bytes -> feed, keyboard -> vm.send,
/// resize -> vm.resize (SSH window-change).
struct SSHTerminalView: NSViewRepresentable {
    let viewModel: TerminalPanelViewModel
    /// Terminal appearance settings (M9d): font family/size and cursor
    /// style/blink, applied in `makeNSView` and kept live in `updateNSView`.
    let settingsStore: SettingsStore

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    func makeNSView(context: Context) -> TerminalView {
        let terminal = TerminalView(frame: .zero)
        terminal.terminalDelegate = context.coordinator
        terminal.font = resolvedFont()
        terminal.nativeBackgroundColor = DesignTokens.terminalBackground
        terminal.nativeForegroundColor = DesignTokens.terminalText
        terminal.caretColor = DesignTokens.terminalText
        // setupOptions sets the layer color only once — re-apply it after a color change:
        terminal.layer?.backgroundColor = DesignTokens.terminalBackground.cgColor

        let cursorStyle = Self.cursorStyle(
            for: settingsStore.terminalCursorStyle, blink: settingsStore.terminalCursorBlink)
        // `TerminalView` registers itself as its own `Terminal`'s delegate
        // (see SwiftTerm's `AppleTerminalView.setup`), so `setCursorStyle`
        // on the underlying `Terminal` routes back into the caret view via
        // `cursorStyleChanged(source:newStyle:)` — no separate AppKit call
        // needed.
        terminal.getTerminal().setCursorStyle(cursorStyle)
        context.coordinator.appliedCursorStyle = cursorStyle

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

    /// SwiftUI calls `updateNSView` on EVERY re-render of this view's
    /// SwiftUI parent (tab switches, sibling state changes, etc.), not just
    /// when appearance settings changed. Re-applying font/cursor
    /// unconditionally would fight the user's live session — resetting the
    /// font recomputes cell metrics (and can nudge the PTY size), and
    /// reissuing `setCursorStyle` restarts the blink animation — so both are
    /// applied ONLY when the resolved value actually differs from what's
    /// currently active.
    func updateNSView(_ terminal: TerminalView, context: Context) {
        let desiredFont = resolvedFont()
        if terminal.font.fontName != desiredFont.fontName
            || terminal.font.pointSize != desiredFont.pointSize
        {
            terminal.font = desiredFont
        }

        let desiredCursorStyle = Self.cursorStyle(
            for: settingsStore.terminalCursorStyle, blink: settingsStore.terminalCursorBlink)
        if context.coordinator.appliedCursorStyle != desiredCursorStyle {
            terminal.getTerminal().setCursorStyle(desiredCursorStyle)
            context.coordinator.appliedCursorStyle = desiredCursorStyle
        }
    }

    /// Resolves the configured terminal font: a custom font by its
    /// PostScript name at the configured size, falling back to the system
    /// monospaced font both when no custom font is configured AND when a
    /// previously configured one no longer resolves (e.g. it was
    /// uninstalled since).
    private func resolvedFont() -> NSFont {
        let size = CGFloat(settingsStore.terminalFontSize)
        if let name = settingsStore.terminalFontName, let font = NSFont(name: name, size: size) {
            return font
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Maps the settings' (shape, blink) pair to SwiftTerm's six-case
    /// `CursorStyle` (steady/blink crossed with block/bar/underline).
    private static func cursorStyle(for shape: TerminalCursorStyle, blink: Bool) -> CursorStyle {
        switch (shape, blink) {
        case (.block, true): return .blinkBlock
        case (.block, false): return .steadyBlock
        case (.bar, true): return .blinkBar
        case (.bar, false): return .steadyBar
        case (.underline, true): return .blinkUnderline
        case (.underline, false): return .steadyUnderline
        }
    }

    /// `TerminalViewDelegate` calls arrive on the main thread (AppKit);
    /// the view model is `@MainActor` — `assumeIsolated` bridges the gap.
    final class Coordinator: NSObject, TerminalViewDelegate {
        private let viewModel: TerminalPanelViewModel
        /// Last cursor style applied to the terminal (M9d) — compared
        /// against the current settings in `updateNSView` so a routine
        /// SwiftUI re-render doesn't reissue `setCursorStyle` (and restart
        /// the blink animation) when nothing actually changed.
        var appliedCursorStyle: CursorStyle?

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
