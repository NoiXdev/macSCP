import Foundation

/// Decides what a session (or a login set built alongside it) writes into
/// its OWN secret slot.
///
/// Consulted, counted 2026-09-16 with `grep -rn "usesStoredManagedPassphrase\|valueToPersist" Sources`
/// outside comments, by: the new-session creation path
/// (`ContentView.persistFormAsSession`, `valueToPersist`, whose value goes
/// to `SessionListViewModel.save`); `ContentView.maybeCreateNewLoginSet` for
/// a set built alongside a session; `SessionListViewModel.updateSession` for
/// the session's own slot on an edit-save (since `bdf6f013` — this paragraph
/// said until 2026-09-16 that the edit-save path wrote unconditionally); and
/// `SessionListViewModel`'s `jumpEchoesStoredManagedPassphrase`, which both
/// `save` and `updateSession` ask before writing a manual jump's slot
/// (technical backlog of 2026-09-16, Task 5; narrowed to an echo by the
/// maintainer answer of 2026-09-19, `echoesStoredManagedPassphrase` below).
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

    /// Whether `typed` is the managed key's own passphrase read back — the
    /// value a jump fill put into the form — rather than something a person
    /// entered over it (maintainer answer of 2026-09-19).
    ///
    /// The jump's save guard. `usesStoredManagedPassphrase` above asks only
    /// whether a slot EXISTS, and a guard built on that answer discards
    /// everything the field holds, a typed correction included: the person
    /// types the right passphrase over a wrong one, saves, and nothing
    /// happens, silently. This asks the narrower question the guard actually
    /// needs — is this value already stored under `key.id`? — so only the
    /// duplication the guard was built to prevent is refused.
    ///
    /// The cost of being wrong moved, which is why this may compare where
    /// `usesStoredManagedPassphrase` may not. Since
    /// `LoginResolver.preferringManagedKeyPassphrase` the managed key's
    /// passphrase WINS over a hop's own slot, so a copy written there can no
    /// longer shadow the key at connect time; it is at worst a stale value
    /// nothing reads. Dropping what the user typed is not recoverable that
    /// way — there is no other UI for a hop's passphrase.
    ///
    /// So an unanswerable probe — a locked Keychain, a denied prompt, an
    /// unreadable key store — answers `false` and the value is written, the
    /// opposite of `usesStoredManagedPassphrase`'s `true`. The guard must
    /// PROVE the duplication before it discards an input, and a probe that
    /// could not be made proves nothing. `false` too for anything that is not
    /// an SSH private-key login, and for a key macSCP does not manage.
    public static func echoesStoredManagedPassphrase(
        typed: String, kind: ConnectionKind, authChoice: ConnectionViewModel.AuthChoice,
        keyPath: String, keys: ManagedKeyStore, secrets: any SecretStore
    ) -> Bool {
        guard kind == .ssh, authChoice == .privateKey else { return false }
        do {
            guard let stored = try ManagedKeyPassphrase.storedPassphrase(
                keyPath: keyPath.trimmingCharacters(in: .whitespacesAndNewlines),
                store: keys,
                secrets: secrets)
            else { return false }
            return stored == typed
        } catch {
            return false
        }
    }

    /// The value to persist under a session's OWN secret slot when a NEW
    /// session is created. Its one caller, counted 2026-09-16 with
    /// `grep -rn "valueToPersist(" Sources` outside comments, is
    /// `ContentView.persistFormAsSession`; the other consumers this type's own
    /// doc comment lists ask `usesStoredManagedPassphrase` directly. Empty when
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
