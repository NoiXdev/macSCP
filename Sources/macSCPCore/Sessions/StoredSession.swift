import Foundation

/// Gespeicherte Verbindung — enthält KEINE Geheimnisse.
/// Passwörter liegen ausschließlich im SecretStore (Schlüsselbund),
/// adressiert über die Session-id.
public struct StoredSession: Codable, Equatable, Identifiable, Sendable {
    /// M3a: nur Passwort. privateKey/agent kommen in M3b.
    public enum AuthKind: String, Codable, Sendable {
        case password
    }

    public let id: UUID
    public var name: String
    public var host: String
    public var port: Int
    public var username: String
    public var authKind: AuthKind

    public init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: Int = 22,
        username: String,
        authKind: AuthKind = .password
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.authKind = authKind
    }
}
