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
        case keyPath
    }

    public enum State: Equatable {
        case idle
        case connecting
        case failed(message: String, field: Field?)
    }

    /// Auth-Auswahl im Formular. Im Key-Modus dient `password` als Passphrase.
    public enum AuthChoice: String, CaseIterable, Sendable {
        case password
        case privateKey
    }

    public typealias Connector = @Sendable (SSHConnectionConfig) async throws -> any RemoteFileSystem

    public var host: String = ""
    public var port: String = "22"
    public var username: String = ""
    public var password: String = ""
    public var authChoice: AuthChoice = .password
    public var keyPath: String = ""
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
        if authChoice == .password {
            guard !password.isEmpty else {
                state = .failed(message: "Passwort darf nicht leer sein.", field: .password)
                return nil
            }
        } else {
            guard !keyPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                state = .failed(message: "Pfad zum SSH-Key angeben.", field: .keyPath)
                return nil
            }
        }
        if shouldSaveSession,
           saveName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            state = .failed(
                message: "Name für die gespeicherte Session angeben.", field: .saveName)
            return nil
        }
        do {
            let auth: SSHConnectionConfig.AuthMethod
            switch authChoice {
            case .password:
                auth = .password(password)
            case .privateKey:
                auth = .privateKey(
                    keyPath: keyPath.trimmingCharacters(in: .whitespacesAndNewlines),
                    passphrase: password.isEmpty ? nil : password)
            }
            let config = try SSHConnectionConfig(
                host: host.trimmingCharacters(in: .whitespacesAndNewlines),
                port: portNumber,
                username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                auth: auth
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

    /// Nutzer-initiierter Moduswechsel (Picker): leert das Geheimnis, damit
    /// Passwort/Passphrase nicht in den anderen Modus verschleppt wird.
    /// Programmatischer Restore (connectStored) setzt authChoice direkt —
    /// ohne Löschung (Review-Fund M3c Task 0).
    public func selectAuthChoice(_ choice: AuthChoice) {
        guard choice != authChoice else { return }
        authChoice = choice
        clearPassword()
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
        case SSHKeyError.fileNotFound(let path):
            return .failed(message: "SSH-Key nicht gefunden: \(path)", field: .keyPath)
        case SSHKeyError.passphraseRequired:
            return .failed(
                message: "Der SSH-Key ist verschlüsselt — Passphrase angeben.",
                field: .password)
        case SSHKeyError.wrongPassphrase:
            return .failed(message: "Passphrase ist falsch.", field: .password)
        case SSHKeyError.unsupportedFormat:
            return .failed(
                message: "SSH-Key-Format wird nicht unterstützt (aktuell: OpenSSH ed25519).",
                field: .keyPath)
        default:
            return .failed(message: "Unerwarteter Fehler: \(String(describing: error))", field: nil)
        }
    }
}
