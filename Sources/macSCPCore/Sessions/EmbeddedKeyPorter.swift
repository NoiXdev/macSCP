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
/// 5. **The imported key's identity is derived, never taken on trust.** Type,
///    fingerprint, public key AND `hasPassphrase` come from the key material
///    wherever it can be opened, and only from the carried public key line
///    where the material genuinely cannot be opened at all; a declared
///    fingerprint that disagrees aborts the import. Crucially, WHICH of those
///    two the import lands in is decided by the outcome of actually trying,
///    never by a flag out of the payload — otherwise a crafted file picks the
///    check it can pass and shows the user a fingerprint they trust next to a
///    foreign key (see `identity(of:declaredBy:)`).
public enum EmbeddedKeyPorter {
    /// Failures that name their own condition. A caller walking many login
    /// sets can catch one of these, report the affected key by name, and
    /// carry on with the remaining sets — which a raw Cocoa/`ssh-keygen`
    /// error would not allow. No case carries a path, key bytes or a
    /// passphrase.
    public enum PorterError: Error, Equatable {
        /// `managed_keys.json` still lists the key, but there is no file for
        /// it in the key store — typically because the user deleted
        /// something under `keys/` by hand. Also covers a metadata entry
        /// whose `fileName` is not a single path component and therefore
        /// cannot name a file in the store at all.
        case keyFileMissing(name: String)
        /// The key file is there but cannot be read as a file.
        case keyFileUnreadable(name: String)
        /// The import file declared a fingerprint that the embedded key
        /// material does not have — a hard stop, never a warning.
        case fingerprintMismatch
        /// The embedded key material could not be opened even though the
        /// payload's own claims say it should open (it declares no passphrase,
        /// or it carried one). Broken or forged — never a reason to fall back
        /// to the values the payload declared about itself.
        case keyMaterialUnverifiable
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

        // Both failure modes below are NAMED conditions, not raw Cocoa
        // errors: a caller walking many login sets can report this one key as
        // broken and still export the rest. Neither carries the underlying
        // error, which would spell out the store path.
        guard let fileURL = store.privateKeyURL(for: key),
              FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false))
        else {
            throw PorterError.keyFileMissing(name: key.name)
        }
        let fileContents: Data
        do {
            fileContents = try Data(contentsOf: fileURL)
        } catch {
            throw PorterError.keyFileUnreadable(name: key.name)
        }

        var passphrase: String?
        if includePassphrase && key.hasPassphrase {
            passphrase = try secrets.password(for: key.id)
        }

        return EmbeddedKey(
            fileContents: fileContents, name: key.name, comment: key.comment, type: key.type,
            fingerprint: key.fingerprint, publicKeyOpenSSH: key.publicKeyOpenSSH,
            hasPassphrase: key.hasPassphrase, passphrase: passphrase)
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

            // The identity the key list will show comes from the key MATERIAL
            // wherever it can be derived, never from the file's own metadata
            // (invariant 5). This runs BEFORE the Keychain write, so a rejected
            // payload never reaches the Keychain at all and the slot is only
            // created for a key whose passphrase demonstrably opens it.
            let evidence = try identity(of: destination, declaredBy: key)

            if evidence.keepsTheCarriedPassphrase,
               let passphrase = key.passphrase, !passphrase.isEmpty
            {
                try secrets.savePassword(passphrase, for: newID)
            }

            // `name` and `comment` stay as the payload wrote them BY DESIGN:
            // they are user-facing labels, not identity, and the importer can
            // rename the key afterwards. Everything the user would check a key
            // BY — type, fingerprint, public key, and whether it is encrypted
            // at all — comes from `evidence`.
            let managed = ManagedKey(
                id: newID, name: key.name, comment: key.comment, type: evidence.info.type,
                fingerprint: evidence.info.fingerprint,
                publicKeyOpenSSH: evidence.info.publicKeyOpenSSH,
                createdAt: Date(), hasPassphrase: evidence.hasPassphrase,
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

    /// What could actually be established about the key material that was just
    /// written — and, in the one case where nothing could, what the carried
    /// public key line says instead.
    private enum KeyMaterialEvidence {
        /// `ssh-keygen -y` opened the file with NO passphrase: the key is not
        /// encrypted, whatever the payload declared about it, and no Keychain
        /// slot belongs to it.
        case openedWithoutAPassphrase(SSHKeyImporter.ImportedKeyInfo)
        /// It opened only with the passphrase the payload carried: the key is
        /// encrypted and that passphrase is the one worth keeping.
        case openedWithTheCarriedPassphrase(SSHKeyImporter.ImportedKeyInfo)
        /// It did not open without a passphrase and the payload carried none
        /// to try — the identity comes from the carried public key line.
        case encryptedWithThePassphraseLeftAtHome(SSHKeyImporter.ImportedKeyInfo)

        var info: SSHKeyImporter.ImportedKeyInfo {
            switch self {
            case .openedWithoutAPassphrase(let info),
                 .openedWithTheCarriedPassphrase(let info),
                 .encryptedWithThePassphraseLeftAtHome(let info):
                return info
            }
        }

        /// Whether the file needs a passphrase to open — observed, not
        /// declared. It drives the lock glyph in the keys list and whether the
        /// connect path goes looking for a Keychain passphrase at all, so a
        /// payload must not be able to set it by writing it down.
        var hasPassphrase: Bool {
            switch self {
            case .openedWithoutAPassphrase: return false
            case .openedWithTheCarriedPassphrase,
                 .encryptedWithThePassphraseLeftAtHome: return true
            }
        }

        /// Only a passphrase that really opened the key earns a Keychain slot:
        /// a key that opens without one must not get a slot it never needs,
        /// and a key that claims a passphrase must not get a slot holding a
        /// string that does not unlock it.
        var keepsTheCarriedPassphrase: Bool {
            switch self {
            case .openedWithTheCarriedPassphrase: return true
            case .openedWithoutAPassphrase,
                 .encryptedWithThePassphraseLeftAtHome: return false
            }
        }
    }

    /// What the key at `url` REALLY is (type, fingerprint, public key, and
    /// whether it is encrypted), plus a check that the import file's own claim
    /// agrees with it.
    ///
    /// The declared metadata is attacker-controlled: a crafted
    /// `.macscplogins` can pair foreign key bytes with the fingerprint of a
    /// key its victim recognizes, and the keys list would then repeat that
    /// claim back at a user asking "is this my prod key?". So the values that
    /// end up in the store are derived, and a declared fingerprint that
    /// disagrees with them aborts the import (the caller's rollback removes
    /// the file and the Keychain slot).
    ///
    /// **Which case applies is decided by trying, never by what the payload
    /// says.** `hasPassphrase` comes out of the same bytes as `fingerprint`,
    /// so gating the inspection on it would let a payload route itself to the
    /// weakest check by simply declaring an encrypted key — and there the
    /// carried public key line is checked against the carried fingerprint,
    /// both from the same hand, which always agrees. Trying unconditionally is
    /// safe and cheap: `ssh-keygen -y -P "" -f <encrypted key>` exits 255
    /// immediately (no prompt; `SSHKeyImporter` hands the subprocess
    /// `/dev/null` for stdin anyway), and `-P` is ignored for an unencrypted
    /// key, so a crafted passphrase cannot force the fallback either.
    ///
    /// Three outcomes, in decreasing strength:
    ///
    /// - **Opens with no passphrase**: `ssh-keygen -y` binds type, fingerprint
    ///   and public key to the MATERIAL that was just written, and the key is
    ///   recorded as unencrypted. No secret in any argv.
    /// - **Opens with the carried passphrase**: equally strong, and the key is
    ///   recorded as encrypted. Cost: the passphrase is briefly in
    ///   `ssh-keygen`'s argv — the accepted minor `SSHKeyImporter` documents.
    /// - **Does not open, and no passphrase was carried**: the genuinely
    ///   irreducible case (an encrypted key deliberately exported without its
    ///   passphrase). The carried public key line is the only thing left to
    ///   check against: the stored fingerprint is then the one that line really
    ///   encodes rather than a free-form claim, but nothing ties it to the
    ///   private key bytes. Deriving the public key from the file is impossible
    ///   here, which is exactly why `EmbeddedKey` carries it.
    ///
    /// Anything else — the payload says the key is unencrypted, or hands over a
    /// passphrase, and the material still will not open — is broken or forged
    /// and throws `keyMaterialUnverifiable`. That also covers an environmental
    /// failure (no `/usr/bin/ssh-keygen`, a key type it rejects): unable to
    /// verify is not a licence to believe the payload.
    private static func identity(of url: URL, declaredBy key: EmbeddedKey) throws
        -> KeyMaterialEvidence
    {
        let carried = key.passphrase.flatMap { $0.isEmpty ? nil : $0 }
        let derived: KeyMaterialEvidence
        if let plain = try? SSHKeyImporter.inspect(privateKeyURL: url, passphrase: nil) {
            derived = .openedWithoutAPassphrase(plain)
        } else if let carried,
                  let unlocked = try? SSHKeyImporter.inspect(
                      privateKeyURL: url, passphrase: carried)
        {
            derived = .openedWithTheCarriedPassphrase(unlocked)
        } else if key.hasPassphrase, carried == nil {
            // A payload whose public key line is unusable throws out of here
            // rather than registering an unverified fingerprint.
            derived = .encryptedWithThePassphraseLeftAtHome(
                try SSHKeyImporter.info(fromPublicKeyLine: key.publicKeyOpenSSH))
        } else {
            throw PorterError.keyMaterialUnverifiable
        }
        guard derived.info.fingerprint == key.fingerprint else {
            throw PorterError.fingerprintMismatch
        }
        return derived
    }
}
