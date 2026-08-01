import Foundation

/// Resolves the effective key passphrase at connect time (M17). A typed
/// passphrase always wins. Otherwise, if `keyPath` points at a managed key
/// that has a stored passphrase, it is read from the Keychain under the key's
/// id. Otherwise the (empty) typed value is returned. Keeps
/// `SSHPrivateKeyLoader` and the connect view model unchanged — the caller
/// just supplies a better `passphrase` than the empty form field.
public enum ManagedKeyPassphrase {
    public static func resolve(
        keyPath: String, typed: String, store: ManagedKeyStore, secrets: any SecretStore
    ) -> String {
        if !typed.isEmpty { return typed }
        guard let key = try? store.key(forPath: keyPath), key.hasPassphrase else { return typed }
        return (try? secrets.password(for: key.id)) ?? typed
    }
}
