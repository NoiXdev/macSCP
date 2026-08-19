import Foundation

/// Decides what a session (or a login set built alongside it) writes into
/// its OWN secret slot when a NEW session is created.
///
/// Only the new-session creation path consults this type: `ContentView.
/// startSession` reaches `valueToPersist` through `SessionListViewModel.
/// save`. The edit-save path does NOT — `ContentView+Detail`'s
/// `onSaveEdited` closure hands the edited secret straight to
/// `SessionListViewModel.updateSession`, which calls `secrets.
/// savePassword` unconditionally (the "save as new login set" branch is the
/// one exception, since it routes through `maybeCreateNewLoginSet` ->
/// `usesStoredManagedPassphrase` instead). Editing a private-key login's
/// passphrase in place, without creating a login set, can therefore
/// duplicate it into both the session's own slot and the managed key's
/// slot — this type does not guard against that.
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

    /// The same question asked of a session that already exists — the
    /// edit-save path's shape, where there is no form to read.
    ///
    /// Reads the persisted `AuthKind` directly instead of routing through
    /// `ConnectionViewModel.authChoice(for:)`: that mapping is main-actor
    /// isolated, and a rule about which Keychain slot owns a passphrase has
    /// no business being tied to the presentation layer's isolation. Anything
    /// that is not an SSH private-key login is refused here, so the delegation
    /// below always passes the pair the base function's own guard expects.
    public static func usesStoredManagedPassphrase(
        session: StoredSession, keys: ManagedKeyStore, secrets: any SecretStore
    ) -> Bool {
        guard session.kind == .ssh, session.ssh?.authKind == .privateKey else { return false }
        return usesStoredManagedPassphrase(
            kind: .ssh, authChoice: .privateKey,
            keyPath: session.ssh?.keyPath ?? "",
            keys: keys, secrets: secrets)
    }

    /// The value to persist under a session's (or new login set's) OWN
    /// secret slot when a NEW session is created — see this type's own doc
    /// comment for which paths actually call this and which one (edit-save
    /// without a new login set) does not. Empty when
    /// `usesStoredManagedPassphrase` says the
    /// passphrase already lives under the managed key's own slot — on the
    /// ordinary path nothing is lost by that: the connect-time fill still
    /// resolves it from `key.id`. On the `catch` path inside
    /// `usesStoredManagedPassphrase` that is only an assumption, not a
    /// fact — the probe could not confirm a slot exists at all, so this
    /// still declines to persist (see that function's doc comment for why),
    /// but if no slot actually exists the passphrase the user just typed is
    /// simply dropped, and they retype it. `resolvedSecret` otherwise —
    /// whichever secret the active backend and auth choice actually show:
    /// SSH's password or passphrase, S3's secret access key, WebDAV's
    /// password, and empty for an agent login, which has no secret to
    /// persist.
    public static func valueToPersist(
        resolvedSecret: String, kind: ConnectionKind, authChoice: ConnectionViewModel.AuthChoice,
        keyPath: String, keys: ManagedKeyStore, secrets: any SecretStore
    ) -> String {
        usesStoredManagedPassphrase(
            kind: kind, authChoice: authChoice, keyPath: keyPath, keys: keys, secrets: secrets)
            ? "" : resolvedSecret
    }
}
