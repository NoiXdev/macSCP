import Foundation

/// Resolves the effective key passphrase at connect time (M17), and answers
/// the related question the save paths need: does a managed key actually HAVE
/// a Keychain slot?
///
/// The two are not the same question, and conflating them cost a milestone.
/// `ManagedKey.hasPassphrase` means "the key FILE is encrypted" — see its own
/// doc comment. Every key macSCP creates itself is encrypted exactly when it
/// also got a slot, so the two coincided until `EmbeddedKeyPorter` produced the
/// first key that is encrypted with NO slot (a login-set export without
/// secrets, which is the default).
public enum ManagedKeyPassphrase {
    public static func resolve(
        keyPath: String, typed: String, store: ManagedKeyStore, secrets: any SecretStore
    ) -> String {
        if !typed.isEmpty { return typed }
        // `hasPassphrase` is only a fast path here: an encrypted key with no
        // slot simply falls through to the (empty) typed value, exactly as an
        // unencrypted one does.
        guard let key = try? store.key(forPath: keyPath), key.hasPassphrase else { return typed }
        return (try? secrets.password(for: key.id)) ?? typed
    }

    /// Whether the managed key at `keyPath` has a Keychain slot of its own
    /// holding a passphrase.
    ///
    /// Ask this — never `ManagedKey.hasPassphrase` — before deciding that a
    /// typed passphrase does NOT need persisting because the key's own slot is
    /// authoritative (`SessionSecretPolicy.usesStoredManagedPassphrase`). For a
    /// key imported from a login-set export that carried no secrets, the flag
    /// is true and the slot does not exist: trusting the flag there discards
    /// the passphrase the user types on every save, with no other UI anywhere
    /// to store it, so the user retypes it on every connect forever.
    ///
    /// `false` for a path macSCP does not manage, which is what the caller
    /// wants: an external key's passphrase belongs in the session's or login
    /// set's own secret slot, and so does a managed key's when it has no slot.
    ///
    /// THROWS instead of answering `false` when the key store or the Keychain
    /// cannot be read at all (M19). "There is no slot" and "I could not find
    /// out" are different answers, and swallowing the second into the first is
    /// what makes a transient `SecItemCopyMatching` failure — a locked
    /// Keychain, a denied prompt — look like a key that never had a slot: the
    /// caller then persists the typed passphrase into the session's or set's
    /// own slot, and the SAME secret now sits in two places, which is exactly
    /// the duplication this function exists to prevent. Callers must decide
    /// deliberately what an unanswerable probe means for them (see
    /// `SessionSecretPolicy.usesStoredManagedPassphrase`, which treats it as "a
    /// slot may well exist" and declines to duplicate).
    public static func hasStoredPassphrase(
        keyPath: String, store: ManagedKeyStore, secrets: any SecretStore
    ) throws -> Bool {
        guard let key = try store.key(forPath: keyPath), key.hasPassphrase else { return false }
        let stored = try secrets.password(for: key.id)
        return !(stored ?? "").isEmpty
    }
}
