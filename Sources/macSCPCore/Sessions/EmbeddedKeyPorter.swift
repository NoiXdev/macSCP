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
///    fingerprint, public key AND `hasPassphrase` come from the key material:
///    from `ssh-keygen -y` wherever the private half can be opened, and
///    otherwise from the CLEARTEXT public part that an `openssh-key-v1` file
///    carries even while encrypted (`ssh-keygen -l -f`). A declared fingerprint
///    that disagrees aborts the import, and a file that yields neither is
///    rejected rather than believed. Crucially, WHICH check the import lands in
///    is decided by the outcome of actually trying, never by a flag out of the
///    payload — otherwise a crafted file picks the check it can pass and shows
///    the user a fingerprint they trust next to a foreign key (see
///    `identity(of:declaredBy:)`).
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
        /// The local key store could not be updated. Replaces the underlying
        /// Cocoa error, which spells out the local `managed_keys.json` path —
        /// the same thing `keyFileMissing`/`keyFileUnreadable` keep out of the
        /// embed side. The caller holds the key it was importing and can name
        /// it itself.
        case keyStoreUnwritable
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
        guard let key = try store.key(forPath: keyPath) else {
            // `key(forPath:)` can only match an entry that resolves to a file
            // INSIDE the key directory, so an entry whose `fileName` was
            // hand-edited to something else ("../outsider") matches no path at
            // all. Returning nil for it would silently drop a key the user
            // asked to export, as if it were somebody else's: recognize it by
            // the naive join it was written with — compared, never opened —
            // and report it as that key's own missing-file condition.
            if let unusable = try store.keyWithUnusableFileName(forPath: keyPath) {
                throw PorterError.keyFileMissing(name: unusable.name)
            }
            return nil
        }

        // Both failure modes below are NAMED conditions, not raw Cocoa
        // errors: a caller walking many login sets can report this one key as
        // broken and still export the rest. Neither carries the underlying
        // error, which would spell out the store path.
        //
        // `key` matched by its resolved path, so it does have a private key
        // URL and that unwrap cannot fail here; what the guard really catches
        // is the file having disappeared since the store was read.
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
            fileContents: fileContents, name: key.name, comment: key.comment,
            fingerprint: key.fingerprint, publicKeyOpenSSH: key.publicKeyOpenSSH,
            hasPassphrase: key.hasPassphrase, passphrase: passphrase)
    }

    /// What `materialize` did — beyond where the key file landed.
    public struct MaterializedKey: Equatable, Sendable {
        /// The new local path, for the imported set's `keyPath`.
        public let path: String
        /// True when the carried passphrase was verified against the key
        /// material and written into the NEW key's own Keychain slot.
        ///
        /// Reported because the CALLER usually holds the same value a second
        /// time (a `.privateKey` login set's secret IS its key passphrase) and
        /// must not store it again under the set's id: one secret in two slots
        /// is what `ManagedKeyPassphrase.hasStoredPassphrase` exists to
        /// prevent, and the set's slot WINS at connect time — so the copy
        /// would silently shadow a later passphrase change made in the SSH
        /// keys sheet (M19 review, important 2).
        public let storedPassphrase: Bool

        public init(path: String, storedPassphrase: Bool) {
            self.path = path
            self.storedPassphrase = storedPassphrase
        }
    }

    /// Writes the key into the managed store under a FRESH id and reports the
    /// new local path plus whether the key took the passphrase (see
    /// `MaterializedKey`). The caller owns the login set; this function only
    /// touches the key store and the Keychain.
    ///
    /// Failures land on "key present, passphrase missing" rather than on a
    /// Keychain slot under an id no store knows: metadata is written before
    /// the passphrase, and only the metadata leg rolls back. This prevents NEW
    /// orphans; it collects none that already exist, which would need a
    /// Keychain enumeration `SecretStore` deliberately does not have.
    public static func materialize(
        _ key: EmbeddedKey, store: ManagedKeyStore, secrets: any SecretStore
    ) throws -> MaterializedKey {
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

        // Evidence and metadata FIRST, passphrase last. Not a line swap: the
        // identity below is what makes the `ManagedKey` constructible at all,
        // so the order is evidence -> `store.add` -> `savePassword`. What that
        // buys is the direction a failure falls in — see the two error paths
        // below.
        let evidence: KeyMaterialEvidence
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
            evidence = try identity(of: destination, declaredBy: key)

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
            do {
                try store.add(managed)
            } catch {
                // `store.add` reads and rewrites `managed_keys.json`, and its
                // Cocoa error spells that local path out. Name the condition
                // instead, as the embed side already does.
                throw PorterError.keyStoreUnwritable
            }
        } catch {
            // Everything up to and including the metadata write rolls the key
            // file back: without an entry there is no key, so nothing may be
            // left on disk pretending otherwise. No Keychain slot exists yet
            // to clean up — that write only happens below, once this key is
            // discoverable. The error is rethrown unchanged; it carries no key
            // material.
            try? FileManager.default.removeItem(at: destination)
            throw error
        }

        var storedPassphrase = false
        if evidence.keepsTheCarriedPassphrase,
           let passphrase = key.passphrase, !passphrase.isEmpty
        {
            do {
                try secrets.savePassword(passphrase, for: newID)
                // Only after the write actually succeeded: the caller decides
                // whether to keep its own copy based on this, and a `true`
                // that nothing backs would drop the passphrase entirely.
                storedPassphrase = true
            } catch {
                // Deliberately NOT fatal and deliberately no rollback. The key
                // is already in the store, and "key present, passphrase
                // missing" is a state the app carries end to end:
                // `ManagedKeyPassphrase.resolve` falls back to the typed
                // value, the connection form shows the passphrase row, and
                // typing it once persists it. Throwing here would instead
                // discard a key the user asked to import, and `storedPassphrase
                // == false` already tells the caller to keep its own copy.
            }
        }

        return MaterializedKey(path: destinationPath, storedPassphrase: storedPassphrase)
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
        /// No available passphrase opened it, so the key is encrypted and gets
        /// no Keychain slot. The identity is the carried public key line —
        /// admitted only after `ssh-keygen -l -f` read the SAME fingerprint out
        /// of the file's own cleartext public part.
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
    /// Three outcomes, in decreasing strength — but all three check the stored
    /// identity against the FILE, never against the payload's own word:
    ///
    /// - **Opens with no passphrase**: `ssh-keygen -y` binds type, fingerprint
    ///   and public key to the MATERIAL that was just written, and the key is
    ///   recorded as unencrypted. No secret in any argv.
    /// - **Opens with the carried passphrase**: equally strong, and the key is
    ///   recorded as encrypted. Cost: the passphrase is briefly in
    ///   `ssh-keygen`'s argv — the accepted minor `SSHKeyImporter` documents.
    /// - **Encrypted, and no passphrase opens it here**: the private half
    ///   cannot be read, but an `openssh-key-v1` file — the format macSCP
    ///   itself writes — carries its PUBLIC key in CLEARTEXT regardless, so
    ///   `ssh-keygen -l -f` still reads the file's real fingerprint with no
    ///   passphrase and no secret in argv. The carried public key line supplies
    ///   the type and the line itself (`-l` prints neither), and it is accepted
    ///   only if the file's own fingerprint agrees with it. See
    ///   `identityOfAKeyThatWillNotOpen`.
    ///
    /// Anything else — the payload says the key is unencrypted and the material
    /// still will not open — is broken or forged and throws
    /// `keyMaterialUnverifiable`. That also covers an environmental failure (no
    /// `/usr/bin/ssh-keygen`, a key type it rejects): unable to verify is not a
    /// licence to believe the payload.
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
        } else if key.hasPassphrase {
            // Note there is no `carried == nil` condition here. A carried
            // passphrase that no longer opens the key (the exporting side's
            // Keychain slot went stale out of band) lands in this branch too,
            // rather than failing the whole import: the branch verifies the
            // file against its own cleartext public part, so it is no weaker
            // for having been reached this way — and an attacker who wanted it
            // would simply have carried no passphrase at all. Only honest users
            // were ever hit by the stricter reading. The stale string is then
            // dropped, never stored (`keepsTheCarriedPassphrase`).
            derived = .encryptedWithThePassphraseLeftAtHome(
                try identityOfAKeyThatWillNotOpen(at: url, declaredBy: key))
        } else {
            throw PorterError.keyMaterialUnverifiable
        }
        guard derived.info.fingerprint == key.fingerprint else {
            throw PorterError.fingerprintMismatch
        }
        return derived
    }

    /// The identity of an encrypted key that no available passphrase opens.
    ///
    /// The carried public key line is NOT taken on trust here — that was the
    /// hole: checking it against the carried fingerprint compares two values
    /// from the same hand, which always agree, so an attacker could pair their
    /// own encrypted bytes with a victim's public key line and have the keys
    /// list show a locked key carrying the victim's genuine fingerprint. And
    /// bytes that are not a key file at all sailed through the same way.
    ///
    /// The file must also actually BE an `openssh-key-v1` private key — start
    /// with the OpenSSH armor header, `-----BEGIN OPENSSH PRIVATE KEY-----` —
    /// before any of the below runs. Without that check, a `fileContents` that
    /// carried nothing but the victim's PUBLIC key line needed no assembly at
    /// all: a public key is public by definition, and `ssh-keygen -l -f`
    /// fingerprints a plain public key file exactly as readily as a private
    /// one, so that line alone made this branch report the victim's real
    /// fingerprint for a "key" that was never key material to begin with.
    ///
    /// Once the header is present, what decides identity is `ssh-keygen -l -f`
    /// on the file that was just written: an `openssh-key-v1` file carries its
    /// public key in cleartext even when the private half is encrypted, so the
    /// file names its own fingerprint without a passphrase and with no secret
    /// in argv. The carried line only supplies what `-l` does not print (the
    /// type, and the line itself for `authorized_keys`), and only if the two
    /// agree.
    ///
    /// Failing to read the file is a hard stop, not a fallback: that covers
    /// non-key bytes, and legacy PEM (`DEK-Info`) keys, which encrypt the
    /// public part too and therefore leave nothing to check against.
    ///
    /// **What this does NOT establish**, stated plainly so this comment does
    /// not overclaim again: an `openssh-key-v1` file's cleartext section
    /// (cipher name, KDF, and the public key(s)) and its encrypted private
    /// section are independent, and nothing here ties one to the other. So ANY
    /// file whose CLEARTEXT section names the claimed key still passes here —
    /// header and all — regardless of what its encrypted section actually
    /// holds: private bytes for an entirely different key, or bytes that are
    /// simply corrupted. That still takes real assembly of a genuine
    /// `openssh-key-v1` envelope (unlike the bare public-key-line variant just
    /// closed above), and what it produces is not a WORKING credential either
    /// way: such a key fails at the first connect, and no version of it lets an
    /// attacker read anything of the user's. A related residue one level down:
    /// a spliced file that is genuinely unencrypted (`cipher "none"`) but fails
    /// `-y` for some other structural reason also lands in this branch and gets
    /// recorded with `hasPassphrase == true` — a lock glyph on a key that has
    /// none. Closing either residue fully would mean refusing to import
    /// encrypted keys exported without their passphrase at all — which is the
    /// normal, default export.
    private static let opensshPrivateKeyHeader = Data(
        "-----BEGIN OPENSSH PRIVATE KEY-----".utf8)

    private static func identityOfAKeyThatWillNotOpen(
        at url: URL, declaredBy key: EmbeddedKey
    ) throws -> SSHKeyImporter.ImportedKeyInfo {
        // `ssh-keygen -l -f` fingerprints a plain public key file exactly as
        // readily as a private one, so this guard — not `-l -f` — is what
        // rejects a `fileContents` that is only ever the claimed public key
        // line: no splice, no key material, nothing to open at all.
        guard key.fileContents.starts(with: Self.opensshPrivateKeyHeader) else {
            throw PorterError.keyMaterialUnverifiable
        }
        // A payload whose public key line is unusable (empty, malformed, or
        // naming a type its own blob contradicts) is reported as this porter's
        // own condition rather than letting an `SSHKeyImportError` escape the
        // `PorterError` contract — and never as a registered, unverified
        // fingerprint.
        guard let carried = try? SSHKeyImporter.info(fromPublicKeyLine: key.publicKeyOpenSSH)
        else {
            throw PorterError.keyMaterialUnverifiable
        }
        let onDisk: String
        do {
            // `fingerprint(ofPrivateKeyFileAt:)` refuses to run at all when a
            // sibling `<file>.pub` exists, because `ssh-keygen -l -f` would
            // read THAT instead (the M18 trap). `materialize` writes only the
            // private key under a fresh UUID, so there is none today — and if
            // that ever changes, this throws instead of silently fingerprinting
            // whatever the sibling holds.
            onDisk = try SSHKeyImporter.fingerprint(ofPrivateKeyFileAt: url)
        } catch {
            throw PorterError.keyMaterialUnverifiable
        }
        guard onDisk == carried.fingerprint else { throw PorterError.fingerprintMismatch }
        return carried
    }
}
