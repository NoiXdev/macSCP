import Foundation
import Synchronization

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
    /// What the last read saw of the store; shared by every copy of this
    /// value, since `secret(for:)` is non-mutating.
    private let lastRead = LastStoreRead()

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
    /// That nil is not silent any more (review follow-ups of 2026-09-18,
    /// Task 6). Each read that finds the store unreadable writes one
    /// diagnostic-log line — the fact and the decode error's TYPE name,
    /// never the error's description, which for a `DecodingError` quotes
    /// from the file (measured 2026-09-18 on a non-JSON store: "Unexpected
    /// character 'c' around line 1, column 1.") — and records whether the
    /// store hid THIS
    /// key (`unreadableStoreHidItsKey`), for the dial that fails afterwards
    /// to say so (`namingUnreadableStore(_:in:)`).
    ///
    /// `hasPassphrase` is a fast path, as in `ManagedKeyPassphrase.resolve`:
    /// an unencrypted key's slot is never read, so no consent prompt is
    /// raised for a passphrase that does not exist.
    public func secret(for sessionID: UUID) throws -> String? {
        // Not `ManagedKeyPassphrase.resolve`: its Keychain read is a `try?`,
        // which the App's form path relies on, and this source must not
        // swallow that error. The store is read the same way both do
        // (`ManagedKeyStore.lookUp(path:)`).
        let key: ManagedKey?
        // An unreadable key store must not stop sessions whose key it does not
        // manage; the Keychain read below still throws.
        switch keys.lookUp(path: keyPath) {
        case .read(let found):
            key = found
            lastRead.hidTheKey.withLock { $0 = false }
        case .unreadable(let errorType, let hidTheKey):
            lastRead.hidTheKey.withLock { $0 = hidTheKey }
            DiagnosticLog.shared.log(
                .error, "app",
                "managed_keys.json unreadable (\(errorType)); answering as if no key were managed")
            return nil
        }
        guard let key, key.hasPassphrase else { return nil }
        guard let stored = try secrets.password(for: key.id), !stored.isEmpty else { return nil }
        return stored
    }

    /// Whether this source's LAST read found `managed_keys.json` unreadable
    /// while its key path lies in the store's key directory — a key the
    /// store would have managed, whose passphrase slot therefore could not
    /// be found. False before the first read, after a read that could read
    /// the store, and for a key anywhere else: the store being unreadable
    /// costs such a key nothing, because it could never have held it.
    ///
    /// Whether the key is ENCRYPTED is not known here — the store that says
    /// so is the one that could not be read. That is answered by the dial,
    /// which is why the fact only renames the dial's own
    /// `passphraseRequired`.
    public var unreadableStoreHidItsKey: Bool {
        lastRead.hidTheKey.withLock { $0 }
    }

    /// `error`, or `SSHKeyError.managedKeyStoreUnreadable` when `error` is
    /// the dial's `passphraseRequired` and a managed-key link in `sources`
    /// saw the store hide its key on its last read.
    ///
    /// The join between the fact and the failure. The chain is walked
    /// BEFORE the dial (`SecretResolver`, `ChainedSecretSource`), and a dial
    /// that fails for a missing passphrase got none from any link — so the
    /// managed-key link, the last one, was asked, and what it recorded is
    /// about this dial. Called where a chain and its dial meet:
    /// `TunnelConnection.connect` (a forwarding, in the App and from
    /// `tunnels start`) and the command line's `connect(to:options:)`.
    ///
    /// Every other error comes back as it was, and so does
    /// `passphraseRequired` for a chain without such a link or one whose
    /// link could read the store.
    public static func namingUnreadableStore(
        _ error: any Error, in sources: [any SecretSource]
    ) -> any Error {
        guard case .passphraseRequired? = error as? SSHKeyError,
            unreadableStoreHidAKey(in: sources)
        else { return error }
        return SSHKeyError.managedKeyStoreUnreadable
    }

    /// Whether any managed-key link in `sources` — directly, or inside a
    /// `ChainedSecretSource`, the shape a diagnosis holds its chain in —
    /// recorded that the store hid its key.
    static func unreadableStoreHidAKey(in sources: [any SecretSource]) -> Bool {
        sources.contains { source in
            if let link = source as? ManagedKeyPassphraseSecretSource {
                return link.unreadableStoreHidItsKey
            }
            if let chain = source as? ChainedSecretSource {
                return unreadableStoreHidAKey(in: chain.links)
            }
            return false
        }
    }
}

/// The reference-type box behind `unreadableStoreHidItsKey`: a struct's own
/// stored property cannot record anything from inside the non-mutating
/// `secret(for:)`, the reason `ChainedSecretSource` keeps its answer in a
/// box too. A `Mutex`, so the class is plainly `Sendable`.
private final class LastStoreRead: Sendable {
    let hidTheKey = Mutex(false)
}
