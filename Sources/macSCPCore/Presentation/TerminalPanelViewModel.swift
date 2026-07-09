// PLATZHALTER für Task-2-Merge — wird durch die echte Implementierung ersetzt.

import Foundation
import Observation

/// Platzhalter-ViewModel für das Terminal-Panel. Existiert nur, damit
/// Task 3 (SSHTerminalView) isoliert gegen die im Plan festgelegte API
/// bauen und verifizieren kann. Wird beim Merge durch die echte
/// Implementierung aus Task 2 ersetzt.
@Observable
@MainActor
public final class TerminalPanelViewModel {
    public enum PanelState: Equatable {
        case closed
        case opening
        case running
        case ended(String?)
    }

    public typealias ShellOpener = @Sendable (String, Int, Int) async throws -> any RemoteShell

    public private(set) var state: PanelState = .closed
    public var isVisible: Bool = false
    public var onOutput: (([UInt8]) -> Void)?

    private let openShell: ShellOpener

    public init(openShell: @escaping ShellOpener) {
        self.openShell = openShell
    }

    public func toggle() {
        isVisible.toggle()
    }

    public func openIfNeeded() {
        state = .opening
    }

    public func send(_ bytes: [UInt8]) {
        // Platzhalter: keine Funktion.
    }

    public func resize(cols: Int, rows: Int) {
        // Platzhalter: keine Funktion.
    }

    public func shutdown() async {
        // Platzhalter: keine Funktion.
    }
}
