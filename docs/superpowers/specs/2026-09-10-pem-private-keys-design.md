# PEM private keys: read, convert, or say why not — design

**Status:** approved by the maintainer on 2026-09-10 ("alle drei Varianten
anbieten … ok, konvertieren, lesen"; design "Ja, so ausschreiben").
Implemented, nine commits: Task 1 (the decoder and the container writer)
`79589a00`, `ce366821`; Task 2 (the converter) `7f3e02b8`, `d22f09d4`;
Task 3 (the loader reads PEM, and the failure names what it cannot)
`5634c012`, `71fdf3f2`; Task 4 (convert from the key manager and from
the failed surface) `6dba7444`, `6e89ee9b`, `38e1e062`.

## The occasion

A stored SSH session pointed at a key in PEM format
(`-----BEGIN RSA PRIVATE KEY-----`). macSCP refused it with the message
the key-formats plan of 2026-09-01 wrote for exactly that case
(`core.connect.keyPEMNotSupported`: convert with `ssh-keygen -p`, or use
the agent). That refusal was a decision, recorded in
`2026-08-31-backlog-ssh-key-formats.md` ("Not covered, by decision: PEM
containers, PuTTY `.ppk`, DSA, FIDO2 `sk-*` keys, certificates"). The
maintainer has now reversed it for PEM, in three parts:

1. **Read.** The loader opens PEM keys itself. No dialog when it succeeds.
2. **Convert.** One click turns a copy of the file into an OpenSSH-format
   managed key and re-points the session at it. The original is never
   touched.
3. **OK.** For what the reader cannot open, the message names the exact
   feature that stops it and carries the exact command, and the failed
   surface offers to copy that command.

## What is measured (2026-09-10, this machine)

`ssh-keygen` is OpenSSH_10.3p1 with LibreSSL 3.3.6; `openssl` is LibreSSL
3.3.6. Every file below was generated at runtime in the scratchpad; none
is checked in.

| producer | flag | header | encryption |
|---|---|---|---|
| ssh-keygen -t rsa | `-m PEM` | `RSA PRIVATE KEY` (PKCS#1) | `Proc-Type: 4,ENCRYPTED` / `DEK-Info: AES-128-CBC,<16-byte hex IV>` |
| ssh-keygen -t ecdsa (256/521) | `-m PEM` | `EC PRIVATE KEY` (SEC1) with **explicit** curve parameters (`prime-field`, not a named-curve OID) | same `DEK-Info: AES-128-CBC` |
| ssh-keygen -t rsa / ecdsa | `-m PKCS8` | `PRIVATE KEY` / `ENCRYPTED PRIVATE KEY` | PBES2, PBKDF2 (8-byte salt, 2048 rounds, **no PRF parameter** → hmacWithSHA1 by RFC 8018 default), `aes-128-cbc` |
| ssh-keygen -t ed25519 | `-m PEM` / `-m PKCS8` | refused: "error in libcrypto" | — |
| openssl rsa | `-aes256` | `RSA PRIVATE KEY` | `DEK-Info: AES-256-CBC` |
| openssl rsa | `-des3` | `RSA PRIVATE KEY` | `DEK-Info: DES-EDE3-CBC,<8-byte hex IV>` |
| openssl genpkey rsa | `-aes256` | `ENCRYPTED PRIVATE KEY` | PBES2, PBKDF2 (no PRF), `aes-256-cbc` |
| openssl pkcs8 -topk8 | `-v2 des3` | `ENCRYPTED PRIVATE KEY` | PBES2, PBKDF2, `des-ede3-cbc` |
| openssl pkcs8 -topk8 | `-v2prf …`, `-scrypt` | LibreSSL 3.3.6 has neither flag | — |
| openssl ecparam -genkey | | `EC PRIVATE KEY` with a **named** curve OID (`prime256v1`) | — |
| openssl genpkey ed25519 | | "Algorithm ed25519 not found" | — |

`ssh-keygen -Z aes256-cbc -m PEM` still writes `AES-128-CBC`; the legacy
cipher cannot be chosen from ssh-keygen here.

`ssh-keygen -p -P <pass> -N <pass> -f <copy>` rewrote every one of these
copies — PKCS#1, SEC1, PKCS#8 plain and encrypted, legacy AES and legacy
DES-EDE3, PBES2 DES-EDE3 — to `-----BEGIN OPENSSH PRIVATE KEY-----`, and
`-P '' -N ''` did the same for the unencrypted ones. It refuses a copy
whose mode is 0644 ("bad permissions"); the copy must be 0600 before the
call.

What the library stack offers, read from `.build/checkouts`:

- swift-crypto 3.15.1: `Insecure.MD5`; `_CryptoExtras`: `AES._CBC.decrypt`
  (PKCS#7 padding checked), `KDF.Insecure.PBKDF2.deriveKey` with
  `insecureSHA1`, `sha256`, `sha384`, `sha512` (and `insecureMD5`,
  `insecureSHA224`). No DES, no 3DES, no RC2, no scrypt.
- swift-asn1 1.7.1 is already in the dependency graph (through
  swift-crypto and Citadel), not yet a product `macSCPCore` names.
- CryptoKit (what `Crypto` re-exports on macOS): `P256/P384/P521.Signing
  .PrivateKey(rawRepresentation:)` take the raw scalar (32/48/66 bytes);
  `Curve25519.Signing.PrivateKey(rawRepresentation:)` takes the 32-byte
  seed.
- Citadel fork 0.12.1-noix.3: `Insecure.RSA.PrivateKey` has no
  component initialiser reachable from outside the module (its
  `init(privateExponent:publicExponent:modulus:)` takes BoringSSL
  `BIGNUM` pointers, and `CCryptoBoringSSL` is not a product `macSCPCore`
  can import). Its `init(sshRsa:decryptionKey:)` parses an
  `openssh-key-v1` container whose private section reads, in order,
  `n, e, d, iqmp, p, q` as SSH strings (`OpenSSHKey.swift:26-44`), the
  public blob `e, n`; cipher `none` has block size 8, padding is `1, 2, …`
  and must be **shorter** than the block size (`paddingLength <
  cipher.blockSize`). Citadel's own writer can produce a padding of 8 on
  an aligned buffer, which its parser would refuse; macSCP's writer pads
  `(8 - len % 8) % 8` bytes.

## Part 1 — the reader

### Shape

One new Core type, `PEMPrivateKeyDecoder`, pure: text and passphrase in,
key material out, no file system, no subprocess. The loader calls it when
the file begins with a PEM boundary other than OpenSSH's, exactly where it
throws `pemNotSupported` today.

```
PEM text ──► armor (label, headers, base64)
   ├─ "OPENSSH PRIVATE KEY"           → not this decoder (Citadel, as today)
   ├─ "RSA PRIVATE KEY"  ─┐
   ├─ "EC PRIVATE KEY"   ─┼─ legacy headers? ─► EVP_BytesToKey(MD5) + AES-CBC ─► DER
   ├─ "PRIVATE KEY"      ─┘                                                      │
   ├─ "ENCRYPTED PRIVATE KEY" ─► PBES2 params ─► PBKDF2 + AES-CBC ─► PKCS#8 DER ─┤
   └─ anything else (PuTTY, certificates, …) ─► notReadable                      ▼
                                                        PKCS#1 │ SEC1 │ PKCS#8 (RSA, EC, Ed25519)
                                                                        │
                                                        DecodedPrivateKey (.rsa / .ecdsa / .ed25519)
```

```swift
public enum PEMPrivateKeyDecoder {
    public enum Curve: Equatable, Sendable { case p256, p384, p521 }
    public struct RSAPrivateKeyComponents: Equatable, Sendable {
        /// Big-endian magnitudes without a leading zero byte.
        public let n, e, d, p, q, iqmp: Data
    }
    public enum DecodedPrivateKey: Equatable, Sendable {
        case rsa(RSAPrivateKeyComponents)
        case ecdsa(curve: Curve, scalar: Data)   // scalar left-padded to 32/48/66 bytes
        case ed25519(seed: Data)                  // 32 bytes
    }
    public enum DecodeError: Error, Equatable, Sendable {
        case notPEM
        case passphraseRequired
        case wrongPassphrase
        case notReadable(PEMReadFailure)
    }
    /// True for "-----BEGIN <label>-----" with any label but OpenSSH's.
    public static func isPEM(_ text: String) -> Bool
    public static func decode(_ text: String, passphrase: String?) throws -> DecodedPrivateKey
}

/// What stopped the reader. Every payload is one of the decoder's OWN
/// constants — never a substring of the file. A file's header can claim any
/// cipher name; an unknown one is reported as "unknown", not echoed.
public enum PEMReadFailure: Equatable, Sendable {
    case cipher(String)    // "DES-EDE3-CBC", "DES-CBC", "RC2-CBC", "unknown"
    case scheme(String)    // "PBES1", "PKCS#12", "scrypt", "unknown"
    case keyType(String)   // "DSA", "multi-prime RSA", "unknown"
    case putty
    case malformed
}
```

### What it reads

- **Armor.** `-----BEGIN <label>-----`, optional RFC 1421 headers
  (`Proc-Type`, `DEK-Info`) terminated by a blank line, base64 body,
  `-----END <label>-----`. Labels: `RSA PRIVATE KEY`, `EC PRIVATE KEY`,
  `PRIVATE KEY`, `ENCRYPTED PRIVATE KEY`. `PuTTY-User-Key-File-` at the
  head of the file is `.putty` (it is not PEM but it is the other format
  people have on disk, and naming it costs one line). Every other label
  → `.keyType("unknown")`; a body that is not base64 or DER → `.malformed`.
- **Legacy encryption** (`Proc-Type: 4,ENCRYPTED`, `DEK-Info: <cipher>,<hex IV>`):
  key = OpenSSL `EVP_BytesToKey` with MD5, one iteration, salt = first 8
  bytes of the IV, concatenating `MD5(prev ‖ pass ‖ salt)` blocks until
  the key length is reached (16/24/32 bytes for AES-128/192/256-CBC).
  Decrypt with `AES._CBC.decrypt`. `DES-CBC`, `DES-EDE3-CBC`, `RC2-CBC`
  → `.cipher(<that name>)`; any other → `.cipher("unknown")`. No
  passphrase on an encrypted file → `passphraseRequired` before any
  arithmetic.
- **PBES2** (`ENCRYPTED PRIVATE KEY`, RFC 8018): `EncryptedPrivateKeyInfo
  ::= SEQUENCE { AlgorithmIdentifier, OCTET STRING }`. Scheme OID must be
  PBES2 `1.2.840.113549.1.5.13`; PBES1 (`1.2.840.113549.1.5.{1,3,4,6,10,11}`)
  → `.scheme("PBES1")`, PKCS#12 PBE (`1.2.840.113549.1.12.1.*`) →
  `.scheme("PKCS#12")`, anything else → `.scheme("unknown")`. KDF must be
  PBKDF2 `1.2.840.113549.1.5.12` (salt OCTET STRING, iterations INTEGER,
  optional keyLength, optional PRF AlgorithmIdentifier: absent →
  hmacWithSHA1 `1.2.840.113549.2.7`; `.9` SHA-256, `.10` SHA-384, `.11`
  SHA-512; `.8` SHA-224 and anything else → `.scheme("unknown")`); scrypt
  `1.3.6.1.4.1.11591.4.11` → `.scheme("scrypt")`. Cipher: aes128-CBC
  `2.16.840.1.101.3.4.1.2`, aes192-CBC `.22`, aes256-CBC `.42` with the IV
  as parameter; des-ede3-cbc `1.2.840.113549.3.7` → `.cipher("DES-EDE3-CBC")`,
  rc2 `1.2.840.113549.3.2` → `.cipher("RC2-CBC")`, else `.cipher("unknown")`.
  Iterations above 10 000 000 are refused as `.malformed` rather than run
  (a hostile file must not pin a core for minutes).
- **PKCS#1** `RSAPrivateKey ::= SEQUENCE { version 0, n, e, d, p, q, dp,
  dq, qInv }`; version 1 (multi-prime) → `.keyType("multi-prime RSA")`.
- **SEC1** `ECPrivateKey ::= SEQUENCE { version 1, privateKey OCTET
  STRING, [0] parameters OPTIONAL, [1] publicKey OPTIONAL }`. Parameters
  are either a named-curve OID (P-256 `1.2.840.10045.3.1.7`, P-384
  `1.3.132.0.34`, P-521 `1.3.132.0.35`) or `SpecifiedECDomain`, in which
  case the curve is identified by the field prime `p` in `fieldID`
  against the three NIST primes; any other prime, any other field type,
  and any other named OID → `.keyType("unknown")`. For a PKCS#8-wrapped
  EC key the parameters come from the outer `AlgorithmIdentifier` when
  the inner structure omits them.
- **PKCS#8** `PrivateKeyInfo ::= SEQUENCE { version 0, AlgorithmIdentifier,
  privateKey OCTET STRING, … }`: rsaEncryption `1.2.840.113549.1.1.1` →
  PKCS#1 inside; id-ecPublicKey `1.2.840.10045.2.1` → SEC1 inside;
  id-Ed25519 `1.3.101.112` → `OCTET STRING` holding a 32-byte `OCTET
  STRING`; id-dsa `1.2.840.10040.4.1` → `.keyType("DSA")`; else
  `.keyType("unknown")`.
- **Wrong passphrase.** Neither legacy PEM nor PBES2 carries a MAC. A
  wrong passphrase shows up as a padding error from `AES._CBC` or as DER
  that does not parse. Both, when a passphrase was supplied, map to
  `wrongPassphrase`; without one, an encrypted file is `passphraseRequired`
  before decryption is attempted. A file that is not encrypted and does
  not parse is `.malformed`.

DER is read with swift-asn1 (`SwiftASN1`), added to `Package.swift` as a
direct dependency of `macSCPCore` at the version already resolved
(`from: "1.0.0"`, resolved 1.7.1). Hand-written ASN.1 was the alternative
and was rejected: the structures above have optional and context-tagged
members, which is exactly where a ~80-line reader starts lying.

### Feeding the keys to a connection

- **ECDSA and Ed25519**: `P256/P384/P521.Signing.PrivateKey(rawRepresentation:)`
  and `Curve25519.Signing.PrivateKey(rawRepresentation:)` — the same
  NIOSSH-native types the loader already returns for OpenSSH files.
- **RSA**: a second new Core type, `OpenSSHKeyContainer.unencryptedRSA(_:
  comment:) -> String`, serialises the components into an `openssh-key-v1`
  container (cipher `none`, kdf `none`, one key, public blob `ssh-rsa e n`,
  private section `checkint checkint "ssh-rsa" n e d iqmp p q comment
  padding`, mpint encoding with a leading zero byte where the high bit is
  set) and the loader hands that string to Citadel's existing
  `Insecure.RSA.PrivateKey(sshRsa:)`. The container lives in memory only
  and is never written anywhere. This keeps the one RSA path there is:
  `SSHAuthenticationMethod.rsaSHA2(…, includeSHA1Fallback: false)`,
  pinned by `rsaKeyOffersSHA2Only`. A fork initialiser would have been
  the other route; it was rejected because it changes the fork for a
  format the fork does not otherwise know, and the container writer is
  ~40 lines that Citadel's own parser verifies in the round-trip test.

### The loader

`SSHPrivateKeyLoader.authentication(username:keyPath:passphrase:)`:

```
if PEMPrivateKeyDecoder.isPEM(contents) {
    decode → map DecodeError (.passphraseRequired / .wrongPassphrase / .notReadable → SSHKeyError.pemNotReadable) 
    dispatch DecodedPrivateKey → SSHAuthenticationMethod (same four arms as the OpenSSH path)
} else { … unchanged … }
```

`SSHKeyError.pemNotSupported` becomes `pemNotReadable(PEMReadFailure)`.
The name changes because the meaning did: it is no longer "PEM is not
supported", it is "this PEM file has a feature the reader does not
have". Every mention moves with it — the loader, `ConnectionViewModel`'s
mapping, `DialProbes.reason(for:)`, `KeyType`'s and `SSHKeyImporter`'s
comments, the porter test's comment, and the four tests that name the
case (`SSHPrivateKeyLoaderTests.pemKeyIsReported`,
`ConnectionViewModelTests.pemNotSupportedMapsToLocalizedMessage`,
`ConnectionDiagnosticsTests` row `"PEM"`, `EmbeddedKeyPorterTests`'
comment). Counted 2026-09-10 with
`grep -rn "pemNotSupported\|keyPEMNotSupported" Sources Tests`: 4 source
files, 4 test files.

`ConnectionViewModel.failedState(for:jumpEnabled:jumpKeyPath:jumpAuthChoice:keyPath:)`
gained the `keyPath` parameter Part 3 depends on, defaulted to `""`. It
is always the TARGET hop's key path, raw as the form holds it — because
that is what the form knows there. A PEM key that fails to read on the
JUMP hop therefore still reaches `failedState` with `keyPath: ""`, which
the `.pemNotReadable` arm reads as "no path to name" and answers with
`core.connect.keyPEMNotReadable.noPath %@` (Part 3) rather than the
two-argument message and its command line — not because the jump key's
own path is unknowable, but because this parameter does not carry it.

### What is not read, by decision

DES, 3DES and RC2 (no primitive in swift-crypto; adding one for a cipher
OpenSSH itself deprecated is the wrong direction), PBES1 and PKCS#12 PBE
(same reasoning, they are MD5/SHA-1-with-DES schemes), scrypt (no
producer on this machine to measure against), DSA (the loader does not
connect with DSA in any format), PuTTY. Each is named in the message and
handled by Part 2, because `ssh-keygen -p` reads all of them but PuTTY.

## Part 2 — convert

### Core

```swift
public enum SSHKeyConverter {
    public enum ConversionError: Error, Equatable, Sendable {
        case toolMissing, sourceUnreadable, conversionFailed, destinationExists
    }
    /// The OpenSSH boundary is the first non-blank line of the file.
    public static func isOpenSSHFormat(fileAt url: URL) -> Bool
    /// Copies `source` to `destination` with mode 0600 and, unless the copy
    /// is already OpenSSH-format, rewrites the COPY with
    /// `/usr/bin/ssh-keygen -p -P <passphrase> -N <passphrase> -f <destination>`
    /// (argument array, never a shell string). The source is never opened for
    /// writing. On any failure after the copy, the destination is removed.
    /// Returns `true` when a conversion ran, `false` when the copy was already
    /// OpenSSH-format.
    @discardableResult
    public static func copyAsOpenSSH(from source: URL, to destination: URL, passphrase: String?) throws -> Bool
    /// The in-place conversion a person runs in a terminal:
    /// `ssh-keygen -p -f '<path>'` with `PosixQuoting.singleQuoted`.
    public static func inPlaceCommandLine(forKeyAt path: String) -> String
}
```

The passphrase reaches `ssh-keygen` through `-P`/`-N` in the argument
array — the same accepted minor `SSHKeyImporter` and `SSHKeyGenerator`
document today (visible to the same user via `ps` for the life of the
process, never in a shell string, never in a log). A converted key keeps
the passphrase it had; the converter sets no new one and prints nothing.

### The key manager imports by converting

`ImportKeySheet.performImport()` changes its order: copy the picked file
into the key directory as `<uuid>` through `SSHKeyConverter.copyAsOpenSSH`,
**then** `SSHKeyImporter.inspect` the copy, then `store.add`. Today the
inspection runs on the source and the copy is a byte-for-byte
`copyItem`; a PEM key imported that way would connect (Part 1) but could
not be exported (`EmbeddedKeyPorter` requires the OpenSSH boundary, for
the reason its own comment gives). Converting on the way in keeps the
store homogeneous. `onImported` gains the `ManagedKey` it created:
`(ManagedKey, keptPassphrase: Bool)`. `ImportKeySheet` stops being
`private` so the failed surface can present it.

### The failed surface

Core publishes what the surface may offer, typed, next to the reason it
already publishes:

```swift
public enum ConnectFailureRemedy: Equatable, Sendable {
    /// The key file the failed attempt used, tilde-expanded. Offered only for
    /// `SSHKeyError.pemNotReadable` — the one failure `ssh-keygen -p` fixes.
    case convertKey(path: String)
}
// ConnectionViewModel
public private(set) var lastFailureRemedy: ConnectFailureRemedy?
```

Written in `connect()`'s `catch` beside `lastFailureReason`, cleared at
the head of every attempt beside it, and **not** inside `fail(_:kind:)`
— `ConnectionViewModelSourceGuardTests.theOneFailureWriterSetsTheVerdictFirst`
reads the lines after that function's signature and a sixth line would
push `state = newState` out of its window. The path is the form's
`keyPath` at the time of the attempt, with the same target/jump
imprecision the existing `pemNotSupported` mapping documents.

`ConnectFailurePlan.content(hasStoredSession:remedy:)` gains two optional
messages, `convertKeyButton` (`connection.failed.convertKey`, "Convert
key…") and `copyCommandButton` (`connection.failed.copyCommand`, "Copy
command"), both non-nil exactly when `remedy` is `.convertKey`.
`ConnectFailureView` renders them in the secondary row beside
"Diagnose…" and "Details…", with `onConvertKey` and `onCopyCommand`.

`ContentView`:

- `onCopyCommand`: `NSPasteboard.general` ← `SSHKeyConverter.inPlaceCommandLine(forKeyAt:)`.
  The command is not a display string (the precedent is
  `ShellCompletionRecipe`'s lines); `theFailedSurfaceRendersNoStringOfItsOwn`
  keeps holding because the view still renders only catalog keys — the
  command goes to the pasteboard, not to a `Text`.
- `onConvertKey`: sets `@State var convertKeyTarget: ImportKeyTarget?`
  (`Identifiable` by `UUID`, carrying the file URL) and a `.sheet(item:)`
  presents `ImportKeySheet(fileURL:store:onImported:)` with the app's
  `ManagedKeyStore(directory: SessionStore.defaultDirectory)`. The sheet
  is where the person types the passphrase (it has the field) and a name
  (prefilled with the file name); the converter and the Keychain slot
  are the sheet's existing job.
- `onImported(key, _)`: `path = store.privateKeyURL(for: key)`. With a
  stored session (`failedConnectTarget(for:)` non-nil): copy it, set
  `ssh.keyPath = path`, `sessionListViewModel.updateSession(copy,
  newSecret: nil)` (nil leaves the session's own secret slot alone; the
  passphrase now lives under the managed key's id, which
  `ManagedKeyPassphrase.resolve` reads), then `retryConnect(tab)` — the
  same one dial path, TOFU and all. Without a stored session:
  `tab.connectionViewModel.keyPath = path` and `dismissConnectFailure(tab)`,
  which returns the person to the form with the new key selected —
  the surface offers no retry for an ad-hoc attempt, by the failed-surface
  plan's own rule, and this does not add one.

**Three decisions the reviews made, not in the draft above:**

1. **The tab is captured at press, not resolved at dismissal.** The
   design's `ImportKeyTarget` above carries only `fileURL`; Task 4's
   review (Critical C1) found that reading `activeTab` when the sheet
   is dismissed lets a tab switch in between re-point the wrong tab's
   session. `ImportKeyTarget` therefore also carries the tab the failed
   attempt belongs to, captured when "Convert key…" is pressed — a
   reference, so the conversion still reaches it if the tab is dragged
   to another window before the sheet closes.
2. **The session's own Keychain slot is dropped after re-pointing only
   when the managed key's own slot holds the passphrase.** The
   `newSecret: nil` sentence above stays true — `updateSession` is still
   called with `newSecret: nil` — but a second write follows it:
   `ManagedKeyPassphrase.hasStoredPassphrase(keyPath:store:secrets:)`
   is asked whether the managed key's own slot holds a passphrase, and
   only when it answers `true` does `SessionListViewModel
   .dropSessionSecret(for:)` remove the session's now-redundant copy.
   `keptPassphrase` from the import sheet's own report is not this
   answer and is not used for it (Task 4 review, finding I3, closed in
   two rounds) — that flag means something else (whether the typed
   passphrase reached the Keychain at all) and answering a different
   question with it would risk deleting a secret's only copy on a
   probe that could not actually confirm one existed elsewhere. `try?`
   around the probe collapses "no slot" and "could not find out" onto
   the same answer, deliberately in the safe direction: no drop.
3. **A stored session bound to a login set takes the ad-hoc route.**
   `loginSetID == nil` gates the branch above, not just the write
   inside it — a set-bound session does not own its `ssh.keyPath` or
   its Keychain slot (the set does, through `LoginResolver.resolve`),
   so re-pointing the session's own fields would persist a path no dial
   reads. Such a session therefore falls to the `else` arm: converted
   for this one attempt, with the set left untouched. The residue this
   leaves is recorded in `docs/BACKLOG.md`'s Interface section: the
   next submit re-applies the set (`SessionListViewModel+Submit.swift`),
   so the converted key is dialled only after the person switches the
   login to Manual or edits the set itself; offering a login-set edit
   from the failed surface is a scope decision, not made here.

## Part 3 — the message

`core.connect.keyPEMNotSupported` is replaced by two keys: one for a dial
that has a key path, `core.connect.keyPEMNotReadable %@ %@`; one for a
dial that has none, `core.connect.keyPEMNotReadable.noPath %@`.

> Note, 2026-09-10: the two message texts and the `pemFeature.keyType`
> sentence below are the design's ORIGINAL wording. Task 3's fix round 1
> (`71fdf3f2`) corrected all three after review — `ssh-keygen -p`
> rewrites its target IN PLACE, not onto a copy, and the sentence as
> first drafted said "convert a copy," which is true of the button, not
> of the command it sits beside. What follows is the catalog's current
> text, copied verbatim from
> `Sources/macSCPCore/Resources/en.lproj/Localizable.strings`.

> macSCP cannot read this PEM key: %1$@. Convert it in place in the
> terminal with %2$@ (the passphrase stays), press Convert key… to let
> macSCP convert a copy, or load the key into the ssh-agent and choose
> the agent as the login.

`%1$@` is one of five feature sentences, each its own key so every
language can phrase it:

| key | en |
|---|---|
| `core.connect.pemFeature.cipher %@` | its %@ encryption is not supported |
| `core.connect.pemFeature.scheme %@` | its %@ password scheme is not supported |
| `core.connect.pemFeature.keyType %@` | its key type (%@) is not one macSCP connects with |
| `core.connect.pemFeature.putty` | it is a PuTTY key file, not PEM |
| `core.connect.pemFeature.malformed` | its contents do not parse |

`%2$@` is `SSHKeyConverter.inPlaceCommandLine(forKeyAt:)` over the
attempt's key path. The path is the one the person typed; it is not a
credential, and the existing `keyNotFound %@` already prints it.

The `.noPath` variant carries no `%2$@` and no in-place remedy at all:

> macSCP cannot read this PEM key: %@. Convert it with ssh-keygen -p, or
> load it into the ssh-agent and choose the agent as the login.

Its rule is the one Part 1 states below: an empty key path means there
is no file to name in a command line, so the sentence builds no command
(`ssh-keygen -p` appears as the bare tool name, not a command line
`SSHKeyConverter` built) and offers no "convert it in place" clause —
only the button and the agent remain as remedies.

Seven keys in each of the four Core catalogs (`en`, `de`, `fr`, `pl`),
German in du-form. `DialProbes.reason(for:)` says
`"the key is a PEM file with a feature this app does not read"` — fixed
text, no payload, per that function's rule.

## Tests

Red first, every one; the plan carries the exact cases. Keys are
generated at runtime, never checked in; no real host name appears
anywhere; passphrases live in named constants so an `#expect` failure
cannot print one.

Two things measured in Task 1 that the plan's own text did not say:

- **PBKDF2 is called through `KDF.Insecure.PBKDF2.deriveKey(…,
  unsafeUncheckedRounds:)`**, not the checked variant. swift-crypto's
  checked `deriveKey` refuses fewer than 210 000 rounds; every producer
  in the design's measurement table above (`ssh-keygen`, `openssl`)
  writes PBES2 files with 2048 rounds, RFC 8018's own example count and
  what every reader of this format actually has to accept. Reading a
  file with a lower round count is not a choice this decoder makes —
  it is what a PEM/PKCS#8 private key on disk looks like.
- **The RSA components `p`, `q` and `iqmp` are measured arithmetically,
  not against an external oracle.** `ssh-keygen -y` derives a public key
  from `n` and `e` alone, so it can confirm those two components but
  says nothing about the other three — Citadel's own `Insecure.RSA
  .PrivateKey` discards `p`, `q` and `iqmp` once it has verified the key
  parses, so the container round-trip test does not see them either.
  What pins them instead is RFC 8017 §3.2's own arithmetic: `p · q = n`
  and `iqmp · q ≡ 1 (mod p)`, computed with `BigInt`. This is why
  `BigInt` (resolved 5.7.0, already in the graph through Citadel)
  became a direct dependency of the `macSCPCoreTests` target — see
  `docs/superpowers/specs/2026-08-20-backlog-dependencies.md`.

- **Decoder unit tests** (`PEMPrivateKeyDecoderTests`): for RSA 2048 and
  ECDSA 256/384/521, each of `-m PEM` and `-m PKCS8`, plain and with a
  passphrase (`ssh-keygen`); legacy AES-256 and DES-EDE3 and PBES2
  DES-EDE3 (`openssl`); named-curve SEC1 (`openssl ecparam`); Ed25519
  PKCS#8 built in the test from a CryptoKit seed
  (`302e020100300506032b657004220420 ‖ seed` — ssh-keygen 10.3 writes
  none, and LibreSSL 3.3.6 knows no ed25519). Each readable file
  decodes; the public key derived from the decoded material equals
  `ssh-keygen -y -f` on the same file (an external oracle, not our
  writer). Wrong passphrase → `wrongPassphrase`, none → `passphraseRequired`,
  DES-EDE3 → `.cipher("DES-EDE3-CBC")`, a PuTTY header → `.putty`. The
  PBES2 branch for an explicit PRF (SHA-256) cannot be produced on this
  machine; the test builds one with swift-asn1 and the swift-crypto
  primitives and says so in its comment — it measures the OID table and
  the wiring, not an external producer.
- **Container round trip** (`OpenSSHKeyContainerTests`): components from
  a PEM RSA key → container → `Insecure.RSA.PrivateKey(sshRsa:)` parses
  it and its public key line equals `ssh-keygen -y`; padding is measured
  for lengths 0 through 7.
- **Loader**: `pemKeyIsReported` becomes `aPEMKeyLoads` (RSA and each
  curve, plain and encrypted, both `-m` flags); a DES-EDE3 file throws
  `pemNotReadable(.cipher("DES-EDE3-CBC"))`; `rsaKeyOffersSHA2Only` gets
  a PEM twin.
- **Rig (gated)**: `FileKeyTypeIntegrationTests` gains PEM shapes —
  `makeInstalledKey` takes `extraKeygenArguments:`; RSA `-m PEM`, ECDSA
  P-256 `-m PEM`, RSA `-m PKCS8` encrypted — and each logs in and lists.
- **Converter**: every readable and unreadable sample above converts to
  a 0600 OpenSSH copy with the source byte-identical afterwards; a
  wrong passphrase leaves no destination; an already-OpenSSH source is
  copied without a conversion (`returns false`); the command line quotes
  a path with a space and an apostrophe.
- **Import sheet**: no App test target; the Core-side order (copy,
  convert, inspect) is what the converter tests cover, and the sheet's
  wiring is read in review.
- **Failed surface** (`ConnectFailurePlanTests`): the two buttons appear
  exactly with a remedy; their keys resolve in all four App catalogs;
  German du-form; `everyReachableMessageComesFromTheFixedCatalogKeySet`
  extended. `ConnectionViewModelTests`: a `pemNotReadable` dial publishes
  `.convertKey(path:)` and the localized message; any other error
  publishes `nil`; the head of the next attempt clears it.
- **Guards**: the `.sheet(item: $convertKeyTarget)` presentation and the
  `retryConnect`/`updateSession` wiring are scanned by a new
  `ConvertKeyWiringGuardTests`, positive and negative side by side, over
  comment-blanked source.

### Coverage addendum 2026-09-11

The "Rig (gated)" bullet above named three PEM shapes; two gaps were still
open at that point — Ed25519 PKCS#8 and openssl's encrypted legacy files had
been measured only against the decoder, never against the rig — and the
CLI's own store-to-dial chain had never been dialled with a PEM key at all.
Plan `docs/superpowers/plans/2026-09-11-pem-rig-coverage.md` closed both,
in `Tests/macSCPCoreTests/FileKeyTypeIntegrationTests.swift` and
`Tests/macSCPCoreTests/CLIMatrixITests.swift`.

- **Rig, six new producer cells** in `FileKeyTypeIntegrationTests.swift`,
  under `// MARK: - The producer cells: files no \`ssh-keygen -t\` run
  writes`:
  - `ed25519PKCS8FileAuthenticates(encrypted:)` — `"an Ed25519 PKCS#8 key
    authenticates"`, `arguments: [false, true]` — 2 cells.
  - `opensslEncryptedLegacyRSAFileAuthenticates()` — `"openssl's encrypted
    legacy RSA file authenticates"` — 1 cell.
  - `opensslNamedCurveSEC1KeyAuthenticates()` — `"openssl's named-curve
    SEC1 key authenticates"` — 1 cell.
  - `desEDE3KeyIsRefusedThenConverted(container:)` — `"a DES-EDE3 key is
    refused by the dial and logs in once converted"`, `arguments: ["legacy",
    "pbes2"]` — 2 cells: each first asserts the refusal
    (`SSHKeyError.pemNotReadable(.cipher("DES-EDE3-CBC"))`) straight out of
    `CitadelFileSystem.connect`, unwrapped, then converts a copy with
    `SSHKeyConverter.copyAsOpenSSH` and logs in with it.

  Six new cells, recounted against the file's own MARK line
  (`FileKeyTypeIntegrationTests.swift:119`): `// MARK: - The cells: 5 types
  × 2, 3 PEM containers × 2, 6 producer cells — 22`.

- **CLI matrix**: `CLIMatrixCases.listsThroughAPEMKeySession(_:)` in
  `Tests/macSCPCoreTests/CLIMatrixITests.swift`, run as
  `listsThroughAPEMKeySession()` in the SSH matrix suite only (`--key`,
  `--host` and `--port` are SSH-only flags, so there is no S3 or WebDAV
  counterpart). It proves the chain none of the cells above touch:
  the binary's own `sessions add --key <path>` writing a `StoredSession`
  in one process, and a later `ls` in a second process reading that store
  and dialling with it — not Core's `CitadelFileSystem.connect` called
  directly in the same process, which is what every `FileKeyTypeIntegrationTests`
  cell does. The key is unencrypted only: `sessions add` takes no
  passphrase flag, and the CLI's login chain reads a stored key's
  passphrase from the Keychain read-only, as its last link, which this rig
  has no way to seed for a session it is about to create.

- **Two measured limits**, both on this machine, OpenSSH 10.3p1 / LibreSSL
  3.3.6:
  - `ssh-keygen -y` cannot read an Ed25519 PKCS#8 file (answers "invalid
    format"), so `ed25519PKCS8FileAuthenticates` computes the authorized
    line from the seed instead, with
    `PEMFixtures.ed25519PublicKeyLine(seed:comment:)`.
  - LibreSSL 3.3.6 cannot encrypt an Ed25519 PKCS#8 container, so the
    encrypted half of the same cell wraps the plain file's DER with
    `PEMFixtures.pbes2PEM(pkcs8DER: Data, passphrase: String, rounds: Int =
    2048, declaredRounds: Int? = nil) throws -> String` — the PBES2 builder
    `PEMPrivateKeyDecoderTests` already used at two call sites
    (`decodesPBES2WithExplicitSHA256` and `refusesAnAbsurdIterationCount`),
    moved into `PEMFixtures` in the same task so both suites share it.

- **`sessions --json` carries no key path, by design**:
  `OutputFormatter.print(rows:asJSON:)` prints `name`/`kind`/`target`/
  `group`/`tags` only — `SessionCatalog.Row` never carries `authKind` or
  `keyPath`. `listsThroughAPEMKeySession` therefore asserts the private-key
  login two ways: `authKind` and `keyPath` are read directly off
  `SessionStore(directory:).all()`, the same type the fixture used to seed
  itself; "no secret field present" is asserted against the actual
  `sessions --json` output via `CLIMatrix.sessionRowKeys`.

- Commits: `d9c4ff54` (the six rig cells), `2465d684` (the CLI case).

## What stays as it was

- The agent route, the OpenSSH-format path, and the SHA-2-only RSA offer.
- TOFU. Conversion re-dials through `connect(in:stored:)`, nothing else.
- No secret in any store, state, log or reason string: the decoder's
  errors carry the decoder's own constants; the remedy carries a path.
- No key material is written by the reader. The converter writes one
  file, the copy the person asked for, into the key directory the store
  already protects (0700 / 0600).

## Decisions 2026-09-16

The maintainer ruled on four open points from this design and the port-
forwarding design's own fingerprint row; three are implemented, the
fourth is a manual measurement handed off outside the plan. Full record:
`docs/superpowers/plans/2026-09-16-maintainer-decisions.md` and its
ledger, `.superpowers/sdd/2026-09-16-maintainer-decisions/progress.md`.

### (a) The passphrase-slot rule after a re-point

Confirmed ("Ja, löschen"): after a login set (or a plain session) is
re-pointed at a converted key, its OWN Keychain slot is dropped once the
managed key's slot holds the passphrase — one passphrase, one place.
Built first as exactly that single condition (`5ce949b7`,
`ManagedKeyPassphrase.hasStoredPassphrase(keyPath:store:secrets:)`
probed with `try?`, `== true` gating the drop) and REFINED by review,
because it was wrong as written: a jump hop that reaches a set or a
session for its OWN credentials never falls back to the managed key's
slot, so dropping the shared copy the jump reads would leave that hop
with nothing to authenticate with. Task 2's report traced the jump
path to confirm this before the fix landed — `ContentView.swift:2913`
and `:2961` put `resolved…secret ?? ""` into `form.jumpPassword`, and
`ConnectionViewModel.buildJumpConfig` passes
`passphrase: jumpPassword.isEmpty ? nil : jumpPassword`
(`ConnectionViewModel.swift:1954`): no call to
`ManagedKeyPassphrase.resolve` sits anywhere on that path, so a jump
hop's own slot is the only place its passphrase can come from.

The rule as built (`d8db692c`, Task 2 fix round 1): a slot — the
session's own, or a set's — is dropped only when BOTH hold:

1. `ManagedKeyPassphrase.hasStoredPassphrase(keyPath:store:secrets:)`
   says the managed key's slot holds the passphrase, and
2. no session depends on that slot for a jump hop —
   `SessionListViewModel.sessionServesAJumpHop(_:)`
   (`Sources/macSCPCore/Presentation/SessionListViewModel.swift:875`)
   for a session's own slot, `setServesAJumpHop(_:)` (`:863`) for a
   set's.

Both gates are written as one `if` — `keySlotHoldsThePassphrase &&
!jumpHopReadsTheSessionSlot` (`ContentView.swift:2659`) and
`keySlotHoldsThePassphrase && !jumpHopReadsTheSetSlot` (`:2727`) — read
by `ConvertKeyWiringGuardTests`' structural gate scanner, which requires
the probe and the negated jump check in the same condition and rejects
two nested `if`s. `dropSessionSecret(for:)` /
`dropLoginSetSecret(for:)` (`SessionListViewModel.swift:583`, `:599`)
do the actual `secrets.deletePassword(for:)`, `try?`, no reload.

### (b) A PEM conversion on a login-set session offers to re-point the set

Confirmed ("Set umhängen, nachfragen"). `ContentView.convertedKeyImported`
(`5ce949b7`) asks `LoginSetRepointPlan.request(session:sets:usageCount:
key:keyPath:tab:)` (`Sources/MacSCPAppKit/LoginSetRepointPlan.swift:64`)
whether the failed attempt's stored session is bound to an SSH
private-key set; when it is, a `.confirmationDialog(` bound to
`@State var setRepointRequest: LoginSetRepointRequest?`
(`ContentView+Sheets.swift:187-219`) asks
`connection.convertKey.repoint.title %@` — "Update the login set
"%@"?" — naming the set, with the session/jump count in
`connection.convertKey.repoint.message %lld %@` (a `Localizable
.stringsdict` plural, `pl` carrying `one`/`few`/`many`/`other`).

- **Confirm** ("Update login set", `connection.convertKey.repoint
  .confirm`) → `repointLoginSet(_:)` (`ContentView.swift:2712`):
  re-reads the set through `LoginSetRepointPlan.currentSet(id:in:)`
  (`LoginSetRepointPlan.swift:54`, added in fix round 1, `d8db692c`,
  MINOR 5) — a FRESH copy from `sessionListViewModel.loginSets` at
  confirm time, not the one captured when the sheet opened, so an edit
  made to the set while the dialog was up is kept and a deleted or
  retyped set falls back to the one-attempt route instead of resurrecting
  a stale copy. Only `keyPath` is changed on that fresh copy;
  `saveLoginSet(set, secret: nil)` persists it, the probe/jump gate from
  (a) decides whether `dropLoginSetSecret(for:)` runs, and
  `retryConnect(request.tab)` re-dials the same tab through
  `connect(in:stored:)` — no other dial path.
- **"This attempt only"** (`connection.convertKey.repoint.thisAttempt`,
  `role: .cancel`) → `convertForThisAttemptOnly(_:keyPath:)`
  (`ContentView.swift:2739`): today's one-attempt route, moved rather
  than duplicated — the tab's `keyPath` is set locally and
  `dismissConnectFailure(tab)` returns to the form; the set is untouched.
- **Escape** presses the dialog's `.cancel`-role button by AppKit's own
  rule, so it takes the same "this attempt only" route; no other close
  path exists for a `.confirmationDialog`.

Both buttons are pinned to their own handler by a dedicated scanner
(`ConvertKeyWiringGuardTests.dialogViolations(_:)`, Task 2 fix rounds 1
and 2, `d8db692c`/`5680442c`): exactly two buttons, their keys are
exactly the two catalog keys above, the confirm span calls
`repointLoginSet(` and never `convertForThisAttemptOnly(`, the
this-attempt span the reverse, and `repointLoginSet(` appears exactly
once in the whole buttons closure — closing the gap a first version of
the guard missed (a swapped pair of actions stayed green until the
pairing check existed).

### (c) The CLI secret chain gained a last, read-only link

Not a maintainer decision on its own — a consequence review found while
implementing (a): the session's slot being the only place the CLI's
secret chain looked meant that dropping it, exactly as (a) now does,
broke `macscp-cli` for that session, because nothing in the CLI's chain
ever read the managed key's own slot. Task 2 re-review round 1 named
this "pre-existing, fixed here because it falsifies the confirmed rule".

`ManagedKeyPassphraseSecretSource` (`5680442c`, Task 2 fix round 2)
moved from `Sources/MacSCPAppKit/TunnelSecretSources.swift` into Core as
`Sources/macSCPCore/Sessions/ManagedKeyPassphraseSecretSource.swift`,
`public`, unchanged in body — the type depended only on Core already —
and is now the last link in BOTH chains, after the session's own
Keychain slot: the forwarding chain
(`TunnelSecretSources.chain(for:keys:secrets:)`, `TunnelSecretSources
.swift:50` keychain, `:55` managed) and the CLI's
(`secretSources(for:passwordCommand:keychainStore:keyStore:)`,
`CLISecretSources.swift:212` keychain, `:223` managed), both gated on
an SSH private-key session with a non-empty trimmed `keyPath`.

The link is READ-ONLY (its own doc comment says so): it reads the
managed-key store's record and the key's Keychain slot, writes neither.
Two rounds of review split what an error on each read should do
(`ManagedKeyPassphraseSecretSource.swift:52-62`):

- A **Keychain error** on the key's own slot (`secrets.password(for:
  key.id)`) is THROWN, not swallowed (`79e161ab`, fix round 3) — the
  same behaviour `KeychainSecretSource`'s own read already has — so it
  stops the chain visibly (`SecretResolver` propagates it) instead of
  reading as "no secret" and failing later, unexplained, at key-loading
  time.
- An **unreadable key store** (`managed_keys.json` failing to decode)
  answers **nil**, "not managed" (`12573d5a`, fix round 4, superseding
  round 3's first attempt at throwing here too) — because the whole
  store is decoded before the path can even be matched, so a throw here
  would stop every private-key session with an empty own slot,
  including ones whose key the store does not manage at all. Ruling,
  recorded in the ledger: "store error → nil, Keychain error → throw."

**Consequence measured, not designed away**: an unattended CLI run
(cron, CI) can now need a SECOND Keychain consent grant — one for the
session's own item, a second, separate one for the managed key's item
— because the two live under different Keychain items and macOS asks
per item. This is reached only when the session's own slot is empty,
i.e. only for a session whose slot (a) has already dropped in favour
of the managed key's shared one. A workstation user sees one extra
"Always Allow" prompt the first time; a cron job pre-authorized only for
the session's item will fail on the key's item until someone grants
that one too. Not measured with a signed binary.

### (d) Host-key fingerprints leave the fixed mismatch reason

Confirmed ("Weglassen"), Task 1, `8db25be8`. `DialSupport.reason(for:)`'s
`HostKeyError.mismatch` arm (`Sources/macSCPCore/Diagnostics/DialProbes
.swift:207-224`, the arm itself at `:211-222`) now pattern-discards
`expected`/`presented` and returns a fixed sentence naming only the
host: `"host key MISMATCH for \(host): the presented key differs from
the recorded one"`. Every consumer of this one function is covered by
construction — the diagnostic log, `ConnectionViewModel.lastFailureReason`
(the audit-row field), `TunnelState.failed(reason:)` (the forwarding
failure reason, `TunnelRunner.swift:288`), and the diagnostics report
rows all persist or display this same sentence, and none of them sees a
fingerprint any more.

Two surfaces were read and confirmed to build their OWN sentence
directly from `host`/`expected`/`presented`, never through
`DialSupport.reason(for:)`, and so are unchanged and still show both
fingerprints to the person deciding whether to trust a new key: the
App's `core.hostkey.mismatch %@ %@ %@` alert
(`ConnectionViewModel.swift:2284-2289`) and the CLI's stderr
(`CLIErrorMapping.swift:202`).

**The one surface that lost the fingerprints** (Task 1's report): the
tunnel profile's failure reason — `TunnelProfilesSheet`'s state column
and the three other places that render the same `TunnelState
.failed(reason:)` text verbatim (the autostart sheet's state column,
the Dock menu's tooltip, the sidebar glyph's tooltip; all four
documented at `TunnelProfilesSheet.swift:508-521`). Before this fix, a
mismatch during a tunnel's own SSH dial showed both fingerprints inline
in that state text; after it, that text names only the host. What that
surface still offers, unaffected by this change: `Sources/MacSCPAppKit
/KnownHostsSheet.swift`, the known-hosts sheet, where the recorded and
presented keys remain visible and comparable — it never went through
`DialSupport.reason(for:)`.

### Decision 4, outside this record

"At login" ("first measure with a signed build and a real login") is a
manual measurement, not a code change, and stays outside this plan; its
handoff is recorded in `docs/BACKLOG.md`'s "Forwardings 'At login'" row.
