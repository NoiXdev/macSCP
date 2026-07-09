import Foundation
import Observation

/// Zustand und Logik des Verbindungsformulars.
/// Der Connector ist injizierbar: Produktion nutzt CitadelFileSystem.connect,
/// Tests einen Mock — das ViewModel bleibt ohne Netz testbar.
@Observable
@MainActor
public final class ConnectionViewModel {
    public enum State: Equatable {
        case idle
        case connecting
        case failed(message: String)
    }

    public typealias Connector = @Sendable (SSHConnectionConfig) async throws -> any RemoteFileSystem

    public var host: String = ""
    public var port: String = "22"
    public var username: String = ""
    public var password: String = ""
    public private(set) var state: State = .idle

    private let connector: Connector

    public init(connector: @escaping Connector) {
        self.connector = connector
    }

    /// Liefert das verbundene Dateisystem oder nil; Fehler landen in `state`.
    public func connect() async -> (any RemoteFileSystem)? {
        guard let portNumber = Int(port.trimmingCharacters(in: .whitespaces)) else {
            state = .failed(message: "Port muss eine Zahl sein.")
            return nil
        }
        guard !password.isEmpty else {
            state = .failed(message: "Passwort darf nicht leer sein.")
            return nil
        }
        do {
            let config = try SSHConnectionConfig(
                host: host, port: portNumber, username: username, auth: .password(password)
            )
            state = .connecting
            let fs = try await connector(config)
            state = .idle
            return fs
        } catch {
            state = .failed(message: Self.message(for: error))
            return nil
        }
    }

    static func message(for error: Error) -> String {
        switch error {
        case SSHConnectionConfig.ConfigError.emptyHost:
            return "Host darf nicht leer sein."
        case SSHConnectionConfig.ConfigError.emptyUsername:
            return "Benutzername darf nicht leer sein."
        case SSHConnectionConfig.ConfigError.invalidPort(let port):
            return "Ungültiger Port: \(port)."
        case RemoteFSError.authenticationFailed:
            return "Anmeldung fehlgeschlagen — Benutzername oder Passwort prüfen."
        case RemoteFSError.connectionFailed(let reason):
            return "Verbindung fehlgeschlagen: \(reason)"
        default:
            return "Unerwarteter Fehler: \(String(describing: error))"
        }
    }
}
