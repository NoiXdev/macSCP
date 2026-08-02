import Foundation

/// Carries a macSCP-MANAGED SSH key inside a login-set export (`embed`) and
/// writes it back into the local managed key store on import (`materialize`),
/// spec M19 "Payload".
///
/// Security invariants — all five are load-bearing, none are optional:
///
/// 1. **Only managed keys are ever embedded.** Ownership is decided from
///    metadata alone (`ManagedKeyStore.key(forPath:)`, a path comparison
///    against `managed_keys.json`). A `keyPath` that is not one of macSCP's
///    own key files — typically `~/.ssh/id_ed25519` — returns `nil` and its
///    bytes are never opened, let alone read into memory. The user opted into
///    exporting THEIR macSCP keys, not the contents of their `~/.ssh`.
/// 2. **Permissions are set explicitly.** The materialized private key is
///    0600 and its containing directory 0700. `createDirectory(attributes:)`
///    applies its attributes only when it actually creates the directory, so
///    a pre-existing (possibly world-readable) key directory is hardened with
///    an explicit `setAttributes` — the same trap M17/M18 documented.
/// 3. **Passphrases live in the Keychain only**, under the FRESH id the
///    imported key gets. They are never written to a file, never logged, and
///    never folded into an error message; key bytes likewise.
/// 4. **A failed import leaves nothing behind.** Any error after the private
///    key file was written rolls back both the file and the Keychain slot
///    (best-effort, `try?`), exactly like the manual key import in
///    `SSHKeysSheet`. The metadata entry is written LAST, so the rollback
///    never has to undo a half-registered key.
/// 5. **The imported key's identity comes from the key material**, not from
///    the metadata next to it in the file. Type, fingerprint and public key
///    are derived from the bytes that were actually written; a declared
///    fingerprint that disagrees aborts the import. Otherwise a crafted file
///    could show the user a fingerprint they trust next to a foreign key.
public enum EmbeddedKeyPorter {
    /// Failures that name their own condition. A caller walking many login
    /// sets can catch one of these, report the affected key by name, and
    /// carry on with the remaining sets — which a raw Cocoa/`ssh-keygen`
    /// error would not allow. No case carries a path, key bytes or a
    /// passphrase.
    public enum PorterError: Error, Equatable {
        /// The import file declared a fingerprint that the embedded key
        /// material does not have — a hard stop, never a warning.
        case fingerprintMismatch
    }

    /// Returns an `EmbeddedKey` only when `keyPath` resolves to a MANAGED key.
    /// External paths are never read — a `nil` result means "not ours, skip".
    ///
    /// `passphrase` is filled only when the caller asked for secrets AND the
    /// key actually has one; `hasPassphrase` travels either way, because the
    /// import side has to know whether the key file is encrypted even when
    /// the passphrase stayed at home.
    public static func embed(
        keyPath: String?, includePassphrase: Bool,
        store: ManagedKeyStore, secrets: any SecretStore
    ) throws -> EmbeddedKey? {
        guard let keyPath, !keyPath.isEmpty else { return nil }
        // Ownership first, and from metadata only: nothing below this guard
        // runs for a path macSCP does not manage, so an external key file is
        // never opened (invariant 1). Keep the file read AFTER this line.
        guard let key = try store.key(forPath: keyPath) else { return nil }

        let fileURL = store.keyDirectory.appendingPathComponent(key.fileName)
        let fileContents = try Data(contentsOf: fileURL)

        var passphrase: String?
        if includePassphrase && key.hasPassphrase {
            passphrase = try secrets.password(for: key.id)
        }

        return EmbeddedKey(
            fileContents: fileContents, name: key.name, comment: key.comment, type: key.type,
            fingerprint: key.fingerprint, hasPassphrase: key.hasPassphrase, passphrase: passphrase)
    }

    /// Writes the key into the managed store under a FRESH id and returns the
    /// new local path for the imported set's `keyPath`. The caller owns the
    /// login set; this function only touches the key store and the Keychain.
    public static func materialize(
        _ key: EmbeddedKey, store: ManagedKeyStore, secrets: any SecretStore
    ) throws -> String {
        let newID = UUID()
        let destination = store.keyDirectory.appendingPathComponent(newID.uuidString)
        let destinationPath = destination.path(percentEncoded: false)

        try FileManager.default.createDirectory(
            at: store.keyDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        // `createDirectory` only applies `attributes` when it creates the
        // directory; if it already existed, permissions are left untouched.
        // Harden explicitly so the 0700 invariant holds either way.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: store.keyDirectory.path(percentEncoded: false))

        do {
            // The directory above is already 0700, so the key bytes are
            // unreachable for other users even in the moment between this
            // write and the chmod that follows it.
            try key.fileContents.write(to: destination, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: destinationPath)

            if let passphrase = key.passphrase, !passphrase.isEmpty {
                try secrets.savePassword(passphrase, for: newID)
            }

            // The identity the key list will show comes from the key MATERIAL
            // wherever it can be derived, never from the file's own metadata
            // (invariant 5).
            let identity = try identity(of: destination, declaredBy: key)

            let managed = ManagedKey(
                id: newID, name: key.name, comment: key.comment, type: identity.type,
                fingerprint: identity.fingerprint,
                publicKeyOpenSSH: identity.publicKeyOpenSSH,
                createdAt: Date(), hasPassphrase: key.hasPassphrase,
                fileName: newID.uuidString)
            try store.add(managed)
        } catch {
            // Anything failing after the write above — chmod, Keychain save,
            // or the metadata write — must not leave an orphaned key file or
            // Keychain slot behind. Both removals are best-effort and safe to
            // run even if the step that "created" them never got there. The
            // error is rethrown unchanged; it carries no key material.
            try? FileManager.default.removeItem(at: destination)
            try? secrets.deletePassword(for: newID)
            throw error
        }

        return destinationPath
    }

    /// What the key at `url` REALLY is (type, fingerprint, public key), and a
    /// check that the import file's own claim agrees with it.
    ///
    /// The declared metadata is attacker-controlled: a crafted
    /// `.macscplogins` can pair foreign key bytes with the fingerprint of a
    /// key its victim recognizes, and the keys list would then repeat that
    /// claim back at a user asking "is this my prod key?". So where the
    /// private key can be opened, `ssh-keygen -y` decides — and a declared
    /// fingerprint that disagrees aborts the import (the caller's rollback
    /// removes the file and the Keychain slot).
    ///
    /// For an encrypted key whose passphrase was NOT exported the derivation
    /// is impossible; the entry then keeps the declared metadata and an empty
    /// public key, which costs the "copy public key" convenience in the key
    /// list.
    private static func identity(of url: URL, declaredBy key: EmbeddedKey) throws
        -> SSHKeyImporter.ImportedKeyInfo
    {
        guard let derived = try? SSHKeyImporter.inspect(
            privateKeyURL: url, passphrase: key.passphrase)
        else {
            return SSHKeyImporter.ImportedKeyInfo(
                type: key.type, fingerprint: key.fingerprint, publicKeyOpenSSH: "")
        }
        guard derived.fingerprint == key.fingerprint else {
            throw PorterError.fingerprintMismatch
        }
        return derived
    }
}
