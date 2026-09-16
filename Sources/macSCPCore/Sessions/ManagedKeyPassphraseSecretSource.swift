import Foundation

/// A managed key's own passphrase slot, as a `SecretSource`.
///
/// The Keychain item is keyed by the KEY's id, not by the session's — see
/// `ManagedKeyPassphrase.resolve(keyPath:typed:store:secrets:)`, which is
/// what this wraps — so a session using a managed private key has its
/// passphrase in a slot no session-keyed lookup can reach. That is the whole
/// reason this type exists: `KeychainSecretSource` asks for
/// `sessionID.uuidString` and comes back empty for exactly those sessions.
///
/// `sessionID` is ignored, deliberately: what identifies the secret here is
/// the key path the session points at.
///
/// READ-ONLY: it reads the key store's record and the key's Keychain slot,
/// and writes neither. Two chains end in it, each after the session's own
/// Keychain slot: the App's forwarding chain
/// (`TunnelSecretSources.chain(for:keys:secrets:)`) and the command line's
/// (`secretSources(for:passwordCommand:keychainStore:keyStore:)`). It lived
/// in the App target until Task 2 fix round 2 of the 2026-09-16 plan moved it
/// here so the command line could share it.
public struct ManagedKeyPassphraseSecretSource: SecretSource {
    public let label = "managed key passphrase"

    private let keyPath: String
    private let keys: ManagedKeyStore
    private let secrets: any SecretStore

    public init(keyPath: String, keys: ManagedKeyStore, secrets: any SecretStore) {
        self.keyPath = keyPath
        self.keys = keys
        self.secrets = secrets
    }

    /// `typed: ""` because nobody typed anything: a forwarding and the command
    /// line both dial without a form, so the stored passphrase is the only
    /// one there is. An
    /// unencrypted or unmanaged key answers `""`, which `SecretResolver`
    /// treats as no answer and walks past.
    public func secret(for sessionID: UUID) throws -> String? {
        ManagedKeyPassphrase.resolve(
            keyPath: keyPath, typed: "", store: keys, secrets: secrets)
    }
}
