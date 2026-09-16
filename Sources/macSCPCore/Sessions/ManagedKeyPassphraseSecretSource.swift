import Foundation

/// A managed key's own passphrase slot, as a `SecretSource`.
///
/// The Keychain item is keyed by the KEY's id, not by the session's — see
/// `ManagedKeyPassphrase.resolve(keyPath:typed:store:secrets:)`, whose lookup
/// this repeats with throwing reads — so a session using a managed private key has its
/// passphrase in a slot no session-keyed lookup can reach. That is the whole
/// reason this type exists: `KeychainSecretSource` asks for
/// `sessionID.uuidString` and comes back empty for exactly those sessions.
///
/// `sessionID` is ignored, deliberately: what identifies the secret here is
/// the key path the session points at.
///
/// READ-ONLY: it reads the key store's record and the key's Keychain slot,
/// and writes neither. Three chains end in it, each after the session's own
/// Keychain slot: the App's forwarding chain
/// (`TunnelSecretSources.chain(for:keys:secrets:)`), the App's diagnosis
/// chain (`DiagnosticsSecretSources.chain(kind:values:keys:secrets:)`, added
/// in the final fix of the 2026-09-16 plan) and the command line's
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

    /// The key's stored passphrase, or nil when no managed key matches the
    /// path, the key is not encrypted, or its slot is absent or empty. Nobody
    /// typed anything: a forwarding and the command line both dial without a
    /// form, so the stored passphrase is the only one there is.
    ///
    /// The Keychain read THROWS (Task 2 fix round 3), exactly as
    /// `KeychainSecretSource`'s does: a denied or locked Keychain item stops
    /// `SecretResolver` with that error instead of reading as "no secret" and
    /// failing later at authentication with nothing pointing at the Keychain.
    /// The key store's read does NOT (Task 2 fix round 4): an unreadable
    /// `managed_keys.json` answers nil, "no managed key is known", because
    /// the store is decoded whole before the path can be matched, and a throw
    /// there stopped sessions whose key it does not manage.
    ///
    /// `hasPassphrase` is a fast path, as in `ManagedKeyPassphrase.resolve`:
    /// an unencrypted key's slot is never read, so no consent prompt is
    /// raised for a passphrase that does not exist.
    public func secret(for sessionID: UUID) throws -> String? {
        // Not `ManagedKeyPassphrase.resolve`: its `try?` is what the App's
        // form path relies on, and this source must not swallow the error.
        let key: ManagedKey?
        // An unreadable key store must not stop sessions whose key it does not
        // manage; the Keychain read below still throws.
        do { key = try keys.key(forPath: keyPath) } catch { return nil }
        guard let key, key.hasPassphrase else { return nil }
        guard let stored = try secrets.password(for: key.id), !stored.isEmpty else { return nil }
        return stored
    }
}
