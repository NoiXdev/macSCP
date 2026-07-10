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
    /// Zuletzt empfangene Output-Chunks (max. 256 KiB) — Replay beim Wieder-
    /// einblenden des Panels, damit ⌘T den sichtbaren Screen nicht verwirft.
    public private(set) var replayBuffer: [[UInt8]] = []

    private static let maxReplayBytes = 256 * 1024
    private var replayBytes = 0

    private let openShell: ShellOpener
    private var shell: (any RemoteShell)?
    private var readTask: Task<Void, Never>?
    private var openTask: Task<Void, Never>?
    /// Verkettet alle `send()`-Aufrufe zu einer FIFO-Warteschlange (siehe
    /// `send(_:)`).
    private var sendTask: Task<Void, Never>?
    /// Zählt jeden `openIfNeeded()`/`shutdown()`-Zyklus hoch. Ein in-flight
    /// `openShell(...)` oder ein spät endender Lese-Loop darf `state`/`shell`
    /// nur schreiben, wenn seine erfasste Generation noch aktuell ist — sonst
    /// würde er einen neueren Zustand (insb. ein `shutdown()`) überschreiben.
    private var generation = 0

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
        replayBuffer = []
        replayBytes = 0
        generation += 1
        let myGeneration = generation
        openTask = Task {
            do {
                let shell = try await openShell("xterm-256color", 80, 24)
                // `shutdown()` kann während des `await` oben gelaufen sein.
                // In dem Fall gehört diese Shell niemandem mehr — schließen,
                // statt sie als Orphan laufen zu lassen oder `state` zu
                // überschreiben.
                guard self.generation == myGeneration else {
                    await shell.close()
                    return
                }
                self.shell = shell
                state = .running
                let readGeneration = myGeneration
                readTask = Task { [weak self] in
                    do {
                        for try await chunk in shell.output {
                            self?.bufferForReplay(chunk)
                            self?.onOutput?(chunk)
                        }
                        self?.finishShell(message: nil, generation: readGeneration)
                    } catch {
                        self?.finishShell(
                            message: "Shell beendet: \(error.localizedDescription)",
                            generation: readGeneration
                        )
                    }
                }
            } catch {
                guard self.generation == myGeneration else { return }
                shell = nil
                state = .ended("Shell konnte nicht geöffnet werden: \(error.localizedDescription)")
            }
        }
    }

    /// Hängt `chunk` an den Replay-Puffer und wirft älteste Chunks raus, bis
    /// `maxReplayBytes` wieder unterschritten ist.
    private func bufferForReplay(_ chunk: [UInt8]) {
        replayBuffer.append(chunk)
        replayBytes += chunk.count
        while replayBytes > Self.maxReplayBytes, !replayBuffer.isEmpty {
            replayBytes -= replayBuffer.removeFirst().count
        }
    }

    private func finishShell(message: String?, generation readGeneration: Int) {
        // Ein Lese-Loop aus einer älteren Generation (z.B. nach `shutdown()`)
        // darf den inzwischen gesetzten Zustand nicht überschreiben.
        guard generation == readGeneration else { return }
        shell = nil
        readTask = nil
        state = .ended(message)
    }

    /// Tastatur-Bytes an die Shell. Aufrufe werden in FIFO-Reihenfolge
    /// verkettet — unabhängige Tasks pro Aufruf garantieren das nicht
    /// (schnelle Tastenanschläge oder Paste könnten sonst außer der Reihe
    /// ankommen). Fehler beim Senden beenden ohnehin den Lese-Loop.
    public func send(_ bytes: [UInt8]) {
        guard let shell else { return }
        let previous = sendTask
        sendTask = Task {
            await previous?.value
            try? await shell.send(bytes)
        }
    }

    /// Neue Terminalgröße melden (SSH window-change).
    public func resize(cols: Int, rows: Int) {
        guard let shell else { return }
        Task { try? await shell.resize(cols: cols, rows: rows) }
    }

    /// Shell schließen und Panel zurücksetzen (Disconnect/Session-Wechsel).
    /// Idempotent; kehrt erst zurück, wenn der Kanal zu ist — inklusive eines
    /// noch laufenden `openIfNeeded()`, damit kein in-flight Öffnen danach
    /// noch `state`/`shell` schreiben oder eine Shell resurrektieren kann.
    public func shutdown() async {
        // Zuerst hochzählen: jede noch laufende openIfNeeded()/finishShell()
        // Fortsetzung erkennt anhand ihrer erfassten (jetzt veralteten)
        // Generation, dass sie nichts mehr schreiben darf.
        generation += 1

        openTask?.cancel()
        await openTask?.value
        openTask = nil

        readTask?.cancel()
        readTask = nil

        if let shell {
            await shell.close()
        }
        shell = nil
        // Nicht auf `sendTask` warten: die darin verketteten `send()`-Aufrufe
        // zielen auf die soeben geschlossene Shell und dürfen einfach
        // auslaufen bzw. no-op werden — sonst könnte `shutdown()` auf einem
        // hängenden `send()` blockieren.
        sendTask?.cancel()
        sendTask = nil
        replayBuffer = []
        replayBytes = 0
        state = .closed
        isVisible = false
    }
}
