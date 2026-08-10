import Foundation

/// Decides what a session (or a login set built alongside it) writes into
/// its OWN secret slot at save time.
///
/// A private-key login's passphrase can live in two different places: the
/// managed key's own Keychain slot (addressed by `key.id`,
/// `ManagedKeyPassphrase.resolve`), or the session's/set's own slot
/// (addressed by `session.id`). Only one of those may hold it — writing it
/// into both means a later edit of one copy silently leaves the other
/// stale, which is the class of bug this type exists to prevent. Lifted out
/// of `ContentView`, which used to build its own `ManagedKeyStore` and
/// `KeychainSecretStore` inline and so could not be tested without touching
/// the real keychain.
public enum SessionSecretPolicy {
    /// Whether `keyPath` names a managed SSH key that already has a
    /// passphrase stored under its OWN Keychain slot (`key.id`), for a
    /// private-key login.
    ///
    /// `false` for anything that isn't an SSH private-key login, and for a
    /// key path this app does not manage — an external key's passphrase, or
    /// a managed key with no slot yet (e.g. one materialized from a
    /// login-set export that carried no secrets), belongs in the session's
    /// or set's own slot exactly like any other typed secret.
    ///
    /// The underlying probe (`ManagedKeyPassphrase.hasStoredPassphrase`)
    /// THROWS when it cannot answer at all — a locked Keychain, a denied
    /// prompt, an unreadable key store — and that case is folded into
    /// `true` here, not `false`. "No slot exists" and "I could not find
    /// out" are different answers: treating an unanswerable probe as "no
    /// slot" would make `valueToPersist` write the typed passphrase into
    /// the session's/set's own slot, permanently duplicating a secret that
    /// may already live under `key.id`. Answering `true` instead only costs
    /// a skipped write — recoverable, since the key's own slot (if it
    /// exists) still resolves the passphrase at connect time — where a
    /// silent duplicate is not recoverable at all. Do not replace this with
    /// `try?`.
    public static func usesStoredManagedPassphrase(
        kind: ConnectionKind, authChoice: ConnectionViewModel.AuthChoice, keyPath: String,
        keys: ManagedKeyStore, secrets: any SecretStore
    ) -> Bool {
        guard kind == .ssh, authChoice == .privateKey else { return false }
        do {
            return try ManagedKeyPassphrase.hasStoredPassphrase(
                keyPath: keyPath.trimmingCharacters(in: .whitespacesAndNewlines),
                store: keys,
                secrets: secrets)
        } catch {
            return true
        }
    }

    /// The value to persist under a session's (or new login set's) OWN
    /// secret slot. Empty when `usesStoredManagedPassphrase` says the
    /// passphrase already lives under the managed key's own slot — nothing
    /// is lost by that: the connect-time fill still resolves it from
    /// `key.id`. `resolvedSecret` otherwise — whichever secret the active
    /// backend and auth choice actually show: SSH's password or passphrase,
    /// S3's secret access key, WebDAV's password, and empty for an agent
    /// login, which has no secret to persist.
    public static func valueToPersist(
        resolvedSecret: String, kind: ConnectionKind, authChoice: ConnectionViewModel.AuthChoice,
        keyPath: String, keys: ManagedKeyStore, secrets: any SecretStore
    ) -> String {
        usesStoredManagedPassphrase(
            kind: kind, authChoice: authChoice, keyPath: keyPath, keys: keys, secrets: secrets)
            ? "" : resolvedSecret
    }
}
