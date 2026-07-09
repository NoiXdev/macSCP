import Foundation
import Observation

/// Zustand des Remote-Browsers: aktueller Pfad, sortierte Einträge,
/// Lade-/Fehlerzustand. Arbeitet ausschließlich gegen das Protocol.
@Observable
@MainActor
public final class RemoteBrowserViewModel {
    public enum State: Equatable {
        case loading
        case loaded
        case failed(message: String)
    }

    public private(set) var currentPath: String
    public private(set) var items: [RemoteFileItem] = []
    public private(set) var state: State = .loading

    /// Aktuell in der Tabelle ausgewählter Eintrag (Einfach-Auswahl).
    public var selectedItem: RemoteFileItem?

    private let fs: any RemoteFileSystem

    public init(fs: any RemoteFileSystem, startPath: String = "/") {
        self.fs = fs
        self.currentPath = startPath
    }

    public var canGoUp: Bool { currentPath != "/" }

    public func load() async {
        state = .loading
        selectedItem = nil
        do {
            let listed = try await fs.list(path: currentPath)
            items = Self.sortedForDisplay(listed)
            state = .loaded
        } catch {
            items = []
            state = .failed(message: Self.message(for: error, path: currentPath))
        }
    }

    public func open(_ item: RemoteFileItem) async {
        guard item.isDirectory else { return }
        currentPath = item.path
        await load()
    }

    public func goUp() async {
        guard canGoUp else { return }
        currentPath = RemotePath.parent(of: currentPath)
        await load()
    }

    public func refresh() async {
        await load()
    }

    public func disconnect() async {
        await fs.disconnect()
    }

    /// Verzeichnisse zuerst, dann Name case-insensitiv —
    /// einheitlich für alle Backends (Mock sortiert nicht, Citadel schon).
    static func sortedForDisplay(_ items: [RemoteFileItem]) -> [RemoteFileItem] {
        items.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    static func message(for error: Error, path: String) -> String {
        switch error {
        case RemoteFSError.notFound:
            return "Pfad nicht gefunden: \(path)"
        case RemoteFSError.permissionDenied:
            return "Keine Berechtigung für: \(path)"
        case RemoteFSError.protocolError(let reason):
            return "Protokollfehler: \(reason)"
        case RemoteFSError.connectionFailed(let reason):
            return "Verbindung verloren: \(reason)"
        default:
            return "Unerwarteter Fehler: \(String(describing: error))"
        }
    }
}
