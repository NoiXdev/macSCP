import Foundation

public struct SSHConnectionConfig: Equatable, Sendable {
    /// M1: nur Passwort. Key- und Agent-Auth kommen in M3 (Session-Manager).
    public enum AuthMethod: Equatable, Sendable {
        /// Achtung: Klartext-Passwort — niemals loggen/interpolieren. Keychain kommt in M3.
        case password(String)
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
