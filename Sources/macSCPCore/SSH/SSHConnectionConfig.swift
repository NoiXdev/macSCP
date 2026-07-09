import Foundation

public struct SSHConnectionConfig: Equatable, Sendable {
    /// Verbindungsparameter inkl. Auth (Passwort oder OpenSSH-Key).
    public enum AuthMethod: Equatable, Sendable {
        /// Achtung: Klartext-Passwort — niemals loggen/interpolieren.
        case password(String)
        /// OpenSSH-Key (M3b: ed25519). Passphrase nil/leer = unverschlüsselter Key.
        /// Achtung: Klartext-Passphrase — niemals loggen/interpolieren.
        case privateKey(keyPath: String, passphrase: String?)
    }

    public enum ConfigError: Error, Equatable, Sendable {
        case emptyHost
        case emptyUsername
        case invalidPort(Int)
    }

    public let host: String
    public let port: Int
    public let username: String
    public let auth: AuthMethod

    public init(host: String, port: Int = 22, username: String, auth: AuthMethod) throws {
        guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ConfigError.emptyHost }
        guard (1...65535).contains(port) else { throw ConfigError.invalidPort(port) }
        guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ConfigError.emptyUsername }
        self.host = host
        self.port = port
        self.username = username
        self.auth = auth
    }
}
