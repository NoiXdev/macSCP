import Foundation
import Security

/// Abstraction over the secret store. Production: macOS keychain.
/// Secrets are addressed via the session id and NEVER appear in the
/// session JSON.
/// The secret is either a password (authKind .password) or the passphrase
/// of a private key (authKind .privateKey; empty = unencrypted key).
public protocol SecretStore: Sendable {
    func savePassword(_ password: String, for sessionID: UUID) throws
    func password(for sessionID: UUID) throws -> String?
    func deletePassword(for sessionID: UUID) throws
}

public struct KeychainError: Error, Equatable, Sendable {
    public let status: OSStatus
}

public struct KeychainSecretStore: SecretStore {
    private let service: String

    public init(service: String = "dev.noidee.macSCP") {
        self.service = service
    }

    private func baseQuery(for sessionID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: sessionID.uuidString,
        ]
    }

    public func savePassword(_ password: String, for sessionID: UUID) throws {
        let data = Data(password.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery(for: sessionID) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var query = baseQuery(for: sessionID)
            query[kSecValueData as String] = data
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        } else {
            guard status == errSecSuccess else { throw KeychainError(status: status) }
        }
    }

    public func password(for sessionID: UUID) throws -> String? {
        var query = baseQuery(for: sessionID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError(status: status)
        }
        return String(data: data, encoding: .utf8)
    }

    public func deletePassword(for sessionID: UUID) throws {
        let status = SecItemDelete(baseQuery(for: sessionID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }
}
