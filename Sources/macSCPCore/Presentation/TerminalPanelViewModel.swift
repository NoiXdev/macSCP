import Foundation
import Observation

/// Zustand und Lebenszyklus des einblendbaren Terminal-Panels.
/// Besitzt den Lese-Loop der Shell; die View liefert nur Darstellung/Eingabe.
@Observable @MainActor
public final class TerminalPanelViewModel {
    public enum PanelState: Equatable {
        /// Keine Shell (initial oder nach shutdown).
        case closed
        case opening
        case running
        /// Shell beendet; Meldung nur bei Fehler (nil = normales Ende).
        case ended(String?)
    }

    public typealias ShellOpener = @Sendable (
        _ terminal: String, _ cols: Int, _ rows: Int
    ) async throws -> any RemoteShell

    public private(set) var state: PanelState = .closed
    public var isVisible = false
    /// Von der View gesetzt; empfängt Ausgabe-Bytes auf dem MainActor.
    public var onOutput: (([UInt8]) -> Void)?

    private let openShell: ShellOpener
    private var shell: (any RemoteShell)?
    private var readTask: Task<Void, Never>?

    public init(openShell: @escaping ShellOpener) {
        self.openShell = openShell
    }

    /// Panel ein-/ausblenden; beim Einblenden Shell öffnen, falls keine läuft.
    public func toggle() {
        isVisible.toggle()
        if isVisible { openIfNeeded() }
    }

    /// Öffnet die Shell, wenn keine läuft (auch fürs "Neu öffnen" nach `.ended`).
    public func openIfNeeded() {
        switch state {
        case .opening, .running: return
        case .closed, .ended: break
        }
        state = .opening
        Task {
            do {
                let shell = try await openShell("xterm-256color", 80, 24)
                self.shell = shell
                state = .running
                readTask = Task { [weak self] in
                    do {
                        for try await chunk in shell.output {
                            self?.onOutput?(chunk)
                        }
                        self?.finishShell(message: nil)
                    } catch {
                        self?.finishShell(message: "Shell beendet: \(error.localizedDescription)")
                    }
                }
            } catch {
                shell = nil
                state = .ended("Shell konnte nicht geöffnet werden: \(error.localizedDescription)")
            }
        }
    }

    private func finishShell(message: String?) {
        shell = nil
        readTask = nil
        state = .ended(message)
    }

    /// Tastatur-Bytes an die Shell (fire-and-forget; Fehler beendet ohnehin den Stream).
    public func send(_ bytes: [UInt8]) {
        guard let shell else { return }
        Task { try? await shell.send(bytes) }
    }

    /// Neue Terminalgröße melden (SSH window-change).
    public func resize(cols: Int, rows: Int) {
        guard let shell else { return }
        Task { try? await shell.resize(cols: cols, rows: rows) }
    }

    /// Shell schließen und Panel zurücksetzen (Disconnect/Session-Wechsel).
    /// Idempotent; kehrt erst zurück, wenn der Kanal zu ist.
    public func shutdown() async {
        readTask?.cancel()
        readTask = nil
        if let shell {
            await shell.close()
        }
        shell = nil
        state = .closed
        isVisible = false
    }
}
