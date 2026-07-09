import Foundation
import Observation

/// Zustand und Logik des Verbindungsformulars.
/// Der Connector ist injizierbar: Produktion nutzt CitadelFileSystem.connect,
/// Tests einen Mock — das ViewModel bleibt ohne Netz testbar.
@Observable
@MainActor
public final class ConnectionViewModel {
    /// Formularfeld, dessen Validierung fehlschlug — die UI hebt es rot hervor.
    public enum Field: Equatable, Sendable {
        case host
        case port
        case username
        case password
        case saveName
    }

    public enum State: Equatable {
        case idle
        case connecting
        case failed(message: String, field: Field?)
    }

    public typealias Connector = @Sendable (SSHConnectionConfig) async throws -> any RemoteFileSystem

    public var host: String = ""
    public var port: String = "22"
    public var username: String = ""
    public var password: String = ""
    /// Session nach erfolgreichem Verbinden speichern (Store + Schlüsselbund)?
    public var shouldSaveSession: Bool = false
    public var saveName: String = ""
    public private(set) var state: State = .idle

    private let connector: Connector

    public init(connector: @escaping Connector) {
        self.connector = connector
    }

    /// Liefert das verbundene Dateisystem oder nil; Fehler landen in `state`.
    /// Re-entrancy-sicher: Aufrufe während `.connecting` werden verworfen,
    /// damit ein Doppelklick keine zweite (verwaiste) Verbindung aufbaut.
    public func connect() async -> (any RemoteFileSystem)? {
        guard state != .connecting else { return nil }
        guard let portNumber = Int(port.trimmingCharacters(in: .whitespaces)) else {
            state = .failed(message: "Port muss eine Zahl sein.", field: .port)
            return nil
        }
        guard !password.isEmpty else {
            state = .failed(message: "Passwort darf nicht leer sein.", field: .password)
            return nil
        }
        if shouldSaveSession,
           saveName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            state = .failed(
                message: "Name für die gespeicherte Session angeben.", field: .saveName)
            return nil
        }
        do {
            let config = try SSHConnectionConfig(
                host: host.trimmingCharacters(in: .whitespacesAndNewlines),
                port: portNumber,
                username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                auth: .password(password)
            )
            state = .connecting
            let fs = try await connector(config)
            state = .idle
            return fs
        } catch {
            state = Self.failedState(for: error)
            return nil
        }
    }

    /// Entfernt das Klartext-Passwort aus dem State (z.B. nach dem Trennen).
    public func clearPassword() {
        password = ""
    }

    static func failedState(for error: Error) -> State {
        switch error {
        case SSHConnectionConfig.ConfigError.emptyHost:
            return .failed(message: "Host darf nicht leer sein.", field: .host)
        case SSHConnectionConfig.ConfigError.emptyUsername:
            return .failed(message: "Benutzername darf nicht leer sein.", field: .username)
        case SSHConnectionConfig.ConfigError.invalidPort(let port):
            return .failed(message: "Ungültiger Port: \(port).", field: .port)
        case RemoteFSError.authenticationFailed:
            return .failed(
                message: "Anmeldung fehlgeschlagen — Benutzername oder Passwort prüfen.",
                field: nil)
        case RemoteFSError.connectionFailed(let reason):
            return .failed(message: "Verbindung fehlgeschlagen: \(reason)", field: nil)
        default:
            return .failed(message: "Unerwarteter Fehler: \(String(describing: error))", field: nil)
        }
    }
}
