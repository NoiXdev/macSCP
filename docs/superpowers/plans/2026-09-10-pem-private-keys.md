# PEM private keys — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A PEM-format private key (PKCS#1, SEC1, PKCS#8, plain or encrypted) connects like an OpenSSH one; what cannot be read is named and can be converted with one click or one copied command.

**Architecture:** A pure Core decoder (`PEMPrivateKeyDecoder`, swift-asn1 + swift-crypto primitives) turns PEM text into key components; the loader dispatches those into the same `SSHAuthenticationMethod` arms it has today, RSA through an in-memory `openssh-key-v1` container so Citadel's parser and the SHA-2-only offer stay the single RSA path. A Core converter (`SSHKeyConverter`, `ssh-keygen -p` on a copy) serves the key manager's import and the failed surface's "Convert key…". The failed surface learns what it may offer from a typed `ConnectFailureRemedy` the view model publishes, never from reading a string.

**Tech Stack:** Swift 6 strict, SwiftPM, Swift Testing, macOS 15; swift-crypto 3.15.1 (`Crypto`, `_CryptoExtras`), swift-asn1 1.7.1 (`SwiftASN1`, new direct dependency), Citadel fork 0.12.1-noix.3, `/usr/bin/ssh-keygen` (OpenSSH 10.3p1) and `/usr/bin/openssl` (LibreSSL 3.3.6) as test fixture producers only.

## Global Constraints

- Design: `docs/superpowers/specs/2026-09-10-pem-private-keys-design.md` (approved 2026-09-10). Its measurement table is the record of what each producer writes; do not restate it, cite it.
- Swift 6 strict, `.swiftLanguageMode(.v6)`, macOS 15. Swift Testing, red first — every new test is run and seen red before the code that makes it green, and the report names the red. No `#require` on a non-optional.
- Tests never block the cooperative pool: every wait is an `await`; child processes only through `SubprocessRunner` (test support) in tests. No wall-clock ceiling in any test (`.timeLimit` traits only).
- No secret in any store, state, log, `reason` string, error payload or test failure message. Passphrases in tests live in named constants and never appear in an `#expect` expression's source text; a test that checks a value is absent computes the `Bool` first. `PEMReadFailure` payloads are the decoder's own constants, never bytes from the file.
- No key material committed: every key is generated at runtime by `ssh-keygen`/`openssl` into a temporary directory that the test removes. No real host name anywhere; the rig is `127.0.0.1:2222`, `testuser`, started from the MAIN checkout (`docker compose -f docker/test-server/compose.yml up -d`).
- The passphrase reaches `ssh-keygen` only through `-P`/`-N` in an argument array (the accepted minor `SSHKeyImporter` documents); never a shell string, never stdin, never an environment variable, never a log line.
- The reader writes nothing to disk. The converter writes exactly one file: the destination the caller named, mode 0600, removed again on any failure after the copy. The source file is never opened for writing.
- TOFU untouched: the conversion flow re-dials through `retryConnect(_:)` → `connect(in:stored:)` and nothing else.
- Every App string through `L10n.string(_:_:)`, every Core string through `CoreL10n.string(_:)`, in `en`, `de`, `fr`, `pl`; German in du-form; no hardcoded display string. A command line (`ssh-keygen -p -f '…'`) is not a display string and comes from `SSHKeyConverter`, never from a catalog.
- Comments naming callers, counts or lists are counted in the same pass; a rename searches for comments naming the old symbol in files the diff does not touch (`pemNotSupported` is named in 4 source and 4 test files, counted 2026-09-10). Source-scanning guards read `SwiftSource.blankingCommentsAndStrings` (App tests) / `SwiftSource.stripCommentsAndStrings` (Core tests) output; a negative check has a positive check beside it; scripted edits assert their anchor before writing; the report is written from the diff.
- `ConnectionViewModel.fail(_:kind:origin:)` keeps its one-line signature and its five-line body: `ConnectionViewModelSourceGuardTests.theOneFailureWriterSetsTheVerdictFirst` reads them. New per-attempt properties are cleared next to `lastFailureReason = nil` and written next to `lastFailureReason = DialSupport.reason(for: error)`.
- Zero warnings (`swift build --build-tests`). Conventional Commits, English, footer exactly `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`. Do not push; do not launch the GUI (the dev build is the maintainer's sight check).

---

### Task 1: The decoder and the container writer

**Files:**
- Modify: `Package.swift` (add `.package(url: "https://github.com/apple/swift-asn1.git", from: "1.0.0")` and `.product(name: "SwiftASN1", package: "swift-asn1")` to `macSCPCore`; Package.resolved already pins 1.7.1 — verify it does not move)
- Create: `Sources/macSCPCore/SSH/PEM/PEMReadFailure.swift`
- Create: `Sources/macSCPCore/SSH/PEM/PEMArmor.swift`
- Create: `Sources/macSCPCore/SSH/PEM/PEMEncryption.swift`
- Create: `Sources/macSCPCore/SSH/PEM/PEMKeyStructures.swift`
- Create: `Sources/macSCPCore/SSH/PEM/PEMPrivateKeyDecoder.swift`
- Create: `Sources/macSCPCore/SSH/PEM/OpenSSHKeyContainer.swift`
- Create: `Tests/macSCPCoreTests/Support/PEMFixtures.swift`
- Test: `Tests/macSCPCoreTests/PEMPrivateKeyDecoderTests.swift`, `Tests/macSCPCoreTests/OpenSSHKeyContainerTests.swift`

**Interfaces:**
- Produces (public, all `Sendable`):
  ```swift
  public enum PEMReadFailure: Equatable, Sendable {
      case cipher(String)    // "DES-EDE3-CBC", "DES-CBC", "RC2-CBC", "unknown"
      case scheme(String)    // "PBES1", "PKCS#12", "scrypt", "unknown"
      case keyType(String)   // "DSA", "multi-prime RSA", "unknown"
      case putty
      case malformed
  }
  public enum PEMPrivateKeyDecoder {
      public enum Curve: Equatable, Sendable { case p256, p384, p521 }
      public struct RSAPrivateKeyComponents: Equatable, Sendable {
          public let n: Data, e: Data, d: Data, p: Data, q: Data, iqmp: Data   // big-endian, no leading zero
          public init(n: Data, e: Data, d: Data, p: Data, q: Data, iqmp: Data)
      }
      public enum DecodedPrivateKey: Equatable, Sendable {
          case rsa(RSAPrivateKeyComponents)
          case ecdsa(curve: Curve, scalar: Data)   // 32 / 48 / 66 bytes, left-padded
          case ed25519(seed: Data)                  // 32 bytes
      }
      public enum DecodeError: Error, Equatable, Sendable {
          case notPEM, passphraseRequired, wrongPassphrase, notReadable(PEMReadFailure)
      }
      public static func isPEM(_ text: String) -> Bool
      public static func decode(_ text: String, passphrase: String?) throws -> DecodedPrivateKey
  }
  public enum OpenSSHKeyContainer {
      /// An unencrypted `openssh-key-v1` PEM string holding one RSA key.
      public static func unencryptedRSA(_ key: PEMPrivateKeyDecoder.RSAPrivateKeyComponents, comment: String) -> String
  }
  ```
- Consumes: `SwiftASN1` (`DER.parse`, `ASN1Node`, `ASN1ObjectIdentifier`, `ASN1OctetString`, `ArraySlice<UInt8>` integers via `Int`/`[UInt8]` decoding), `Insecure.MD5`, `AES._CBC.decrypt(_:using:iv:)`, `KDF.Insecure.PBKDF2.deriveKey(from:salt:using:outputByteCount:rounds:)`.

- [ ] **Step 1: Fixture helper.** `Tests/macSCPCoreTests/Support/PEMFixtures.swift`:
  ```swift
  import Foundation
  import Testing

  /// Runtime PEM key files for the decoder, loader and converter tests. Every
  /// file is written into a fresh temporary directory the caller removes;
  /// nothing here is checked in. The passphrase is the caller's constant and
  /// reaches exactly one place: `ssh-keygen -N` / `openssl -passout pass:`.
  enum PEMFixtures {
      static func tempDir() throws -> URL {
          let dir = URL(fileURLWithPath: NSTemporaryDirectory())
              .appendingPathComponent("macscp-pem-\(UUID().uuidString)")
          try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                  attributes: [.posixPermissions: 0o700])
          return dir
      }
      enum Format: String { case pem = "PEM", pkcs8 = "PKCS8" }
      /// `ssh-keygen -t <type> [-b bits] -m <format> -N <passphrase> -f <dir>/key -C fixture`.
      /// Returns the private key path; `<path>.pub` is beside it.
      static func sshKeygen(type: String, bits: Int?, format: Format, passphrase: String?, in dir: URL) async throws -> String {
          let path = dir.appendingPathComponent("key-\(UUID().uuidString)").path(percentEncoded: false)
          var args = ["-q", "-t", type, "-m", format.rawValue, "-N", passphrase ?? "", "-f", path, "-C", "fixture"]
          if let bits { args += ["-b", String(bits)] }
          let result = try await SubprocessRunner.run(URL(fileURLWithPath: "/usr/bin/ssh-keygen"), arguments: args)
          #expect(result.status == 0)
          return path
      }
      /// `openssl <args>`; returns stdout. LibreSSL 3.3.6 here (design table).
      @discardableResult
      static func openssl(_ args: [String]) async throws -> String {
          let result = try await SubprocessRunner.run(URL(fileURLWithPath: "/usr/bin/openssl"), arguments: args)
          #expect(result.status == 0)
          return result.stdoutText
      }
      /// The public key line `ssh-keygen -y` derives from the file — the external oracle.
      static func publicKeyLine(ofKeyAt path: String, passphrase: String?) async throws -> String {
          let result = try await SubprocessRunner.run(
              URL(fileURLWithPath: "/usr/bin/ssh-keygen"),
              arguments: ["-y", "-P", passphrase ?? "", "-f", path])
          #expect(result.status == 0)
          return result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
      }
      /// The base64 blob (second field) of a public key line, decoded.
      static func blob(ofPublicKeyLine line: String) -> Data? {
          let parts = line.split(separator: " ")
          guard parts.count >= 2 else { return nil }
          return Data(base64Encoded: String(parts[1]))
      }
      /// Reads `count` SSH strings (uint32 length + bytes) from a blob.
      static func sshStrings(in blob: Data, count: Int) -> [Data]? { … }   // plain loop, returns nil on short read
      /// PKCS#8 PEM for an Ed25519 seed: the fixed 16-byte PrivateKeyInfo
      /// prefix `30 2e 02 01 00 30 05 06 03 2b 65 70 04 22 04 20` and the seed.
      /// Built here because ssh-keygen 10.3 and LibreSSL 3.3.6 produce none (design table).
      static func ed25519PKCS8PEM(seed: Data) -> String {
          precondition(seed.count == 32)
          let prefix: [UInt8] = [0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20]
          let der = Data(prefix) + seed
          return "-----BEGIN PRIVATE KEY-----\n" + der.base64EncodedString(options: [.lineLength64Characters]) + "\n-----END PRIVATE KEY-----\n"
      }
  }
  ```
  Fill in `sshStrings` (a loop over `UInt32` big-endian lengths).
- [ ] **Step 2: Failing decoder tests** (`PEMPrivateKeyDecoderTests`, `@Suite("PEMPrivateKeyDecoder", .timeLimit(.minutes(2)))`). Passphrase constant: `private static let passphrase = "fixture-passphrase-2026"` (5+ characters: ssh-keygen refuses shorter). Cases, each generating into `PEMFixtures.tempDir()` and removing it in a `defer`:
  1. `@Test("RSA and ECDSA decode in both PEM formats, plain and encrypted", arguments: [("rsa", 2048), ("ecdsa", 256), ("ecdsa", 384), ("ecdsa", 521)], [PEMFixtures.Format.pem, .pkcs8], [false, true])` — decode; then the oracle: for RSA, `PEMFixtures.sshStrings(in: blob, count: 3)` gives `["ssh-rsa", e, n]` as mpints — strip one leading zero byte from each mpint and compare to `components.e` / `.n`; for ECDSA, `PXXX.Signing.PrivateKey(rawRepresentation: scalar).publicKey.x963Representation` equals the third SSH string of the blob (`["ecdsa-sha2-nistpNNN", "nistpNNN", point]`), and the curve matches the bits.
  2. `@Test("an Ed25519 PKCS#8 key decodes to its seed")` — seed from `Curve25519.Signing.PrivateKey().rawRepresentation`, PEM from `PEMFixtures.ed25519PKCS8PEM`, decoded `.ed25519(seed:)` equals; and `Curve25519.Signing.PrivateKey(rawRepresentation:)` of it has the same public key as the generator.
  3. `@Test("a named-curve SEC1 key decodes")` — `openssl ecparam -name prime256v1 -genkey -noout -out <f>`; `.ecdsa(curve: .p256, …)`; oracle via `ssh-keygen -y` as in case 1.
  4. `@Test("legacy AES-256 decodes with the passphrase")` — `openssl rsa -in <pkcs1 plain> -aes256 -passout pass:<constant> -out <f>`; equals the plain file's decode.
  5. `@Test("an encrypted key without a passphrase asks for one", arguments: [legacy AES-128 via ssh-keygen -m PEM, PBES2 via ssh-keygen -m PKCS8])` → `DecodeError.passphraseRequired`.
  6. `@Test("a wrong passphrase is reported as wrong, not as garbage", same two arguments)` → `.wrongPassphrase` with `passphrase: "not-the-" + …`.
  7. `@Test("DES-EDE3 is named, not attempted", arguments: [legacy via openssl rsa -des3, PBES2 via openssl pkcs8 -topk8 -v2 des3])` → `.notReadable(.cipher("DES-EDE3-CBC"))`.
  8. `@Test("a PuTTY header is named")` — text `"PuTTY-User-Key-File-3: ssh-ed25519\n"` → `.notReadable(.putty)`; `@Test("an unknown label is named")` — `-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----` → `.notReadable(.keyType("unknown"))`; `@Test("a body that is not DER is malformed")` — `-----BEGIN RSA PRIVATE KEY-----\nAAAA\n-----END RSA PRIVATE KEY-----` → `.notReadable(.malformed)`.
  9. `@Test("isPEM tells PEM from OpenSSH and from noise")` — three inputs.
  10. `@Test("a PBES2 file with an explicit SHA-256 PRF decodes")` — LibreSSL 3.3.6 cannot write one (design table), so the test BUILDS the `EncryptedPrivateKeyInfo` with `SwiftASN1`'s `DER.Serializer` around the PKCS#8 DER of an ssh-keygen `-m PKCS8` plain RSA key: PBKDF2 (salt 8 random bytes, 2048 rounds, PRF `1.2.840.113549.2.9`) via `KDF.Insecure.PBKDF2.deriveKey(… using: .sha256, outputByteCount: 32 …)`, `AES._CBC.encrypt` with a random IV, scheme OID `2.16.840.1.101.3.4.1.42`. The comment says this measures the OID table and the wiring, not an external producer.
  11. `@Test("an iteration count above the ceiling is refused")` — same builder with `rounds: 10_000_001` → `.notReadable(.malformed)`.
- [ ] **Step 3: Failing container tests** (`OpenSSHKeyContainerTests`): `@Test("the container parses through Citadel and names the same public key")` — components from a decoded `-m PEM` RSA key → `OpenSSHKeyContainer.unencryptedRSA(_, comment: "fixture")` → `try Insecure.RSA.PrivateKey(sshRsa: container)`; its `publicKey.write(to: &buffer)` (the `NIOSSHPublicKeyProtocol` requirement) yields the same bytes as `PEMFixtures.blob(ofPublicKeyLine:)` from `ssh-keygen -y`. `@Test("the padding is shorter than the block for every remainder", arguments: 0..<8)` — build components whose `comment` length shifts the private section by `n` bytes, parse each through Citadel (green means `paddingLength < 8` held).
- [ ] **Step 4: Run** `swift test --filter "PEMPrivateKeyDecoder|OpenSSHKeyContainer"` → FAIL to compile (types missing). Record the red.
- [ ] **Step 5: Implement.**
  - `PEMArmor`: `struct PEMArmor { let label: String; let headers: [String: String]; let body: Data }`, `static func parse(_ text: String) throws(DecodeError)` — first non-blank line must be `-----BEGIN <label>-----`; a file beginning with `PuTTY-User-Key-File-` → `.notReadable(.putty)`; headers until the first blank line (only when the line after BEGIN contains `:`); base64 with whitespace stripped; `-----END <label>-----` must match. Legacy: `Proc-Type: 4,ENCRYPTED` and `DEK-Info: <CIPHER>,<HEXIV>`.
  - `PEMEncryption`: `static func legacyDecrypt(body:, cipherName:, ivHex:, passphrase: String?) throws -> Data` — cipher table `["AES-128-CBC": 16, "AES-192-CBC": 24, "AES-256-CBC": 32]`, named refusals `["DES-CBC", "DES-EDE3-CBC", "RC2-CBC"]` → `.cipher(name)`, others `.cipher("unknown")`; `passphrase == nil` → `.passphraseRequired` before deriving; EVP_BytesToKey: `var key = Data(); var prev = Data(); while key.count < keyLength { prev = Data(Insecure.MD5.hash(data: prev + pass + salt)); key += prev }` with `salt = iv.prefix(8)`; `AES._CBC.decrypt` errors → `.wrongPassphrase`. `static func pbes2Decrypt(encryptedPrivateKeyInfo: ASN1Node, passphrase: String?) throws -> Data` with the OID tables from the design (PBES2 `1.2.840.113549.1.5.13`; PBKDF2 `1.2.840.113549.1.5.12`; PRFs `.2.7` SHA1 (default when absent), `.2.9` SHA256, `.2.10` SHA384, `.2.11` SHA512; ciphers `2.16.840.1.101.3.4.1.{2,22,42}`; refusals: PBES1 `1.2.840.113549.1.5.{1,3,4,6,10,11}` → `.scheme("PBES1")`, `1.2.840.113549.1.12.1.*` → `.scheme("PKCS#12")`, scrypt `1.3.6.1.4.1.11591.4.11` → `.scheme("scrypt")`, `1.2.840.113549.3.7` → `.cipher("DES-EDE3-CBC")`, `1.2.840.113549.3.2` → `.cipher("RC2-CBC")`); `rounds > 10_000_000` → `.malformed`.
  - `PEMKeyStructures`: `static func rsaPKCS1(_ der: Data) throws -> RSAPrivateKeyComponents` (version must be 0; version 1 → `.keyType("multi-prime RSA")`; integers via `ArraySlice<UInt8>` from `ASN1Node.content`, strip leading zero bytes); `static func ecSEC1(_ der: Data, outerCurve: Curve?) throws -> (Curve, Data)` (version 1; `[0]` parameters: OID → curve table, `SpecifiedECDomain` → `fieldID.p` compared against the three NIST primes as byte arrays; missing parameters → `outerCurve` or `.keyType("unknown")`; scalar left-padded to 32/48/66); `static func pkcs8(_ der: Data) throws -> DecodedPrivateKey` (`rsaEncryption 1.2.840.113549.1.1.1` → `rsaPKCS1(inner)`; `id-ecPublicKey 1.2.840.10045.2.1` → `ecSEC1(inner, outerCurve: from params)`; `id-Ed25519 1.3.101.112` → inner `OCTET STRING` of 32 bytes; `id-dsa 1.2.840.10040.4.1` → `.keyType("DSA")`; else `.keyType("unknown")`). Any `ASN1Error` → `.malformed`, or `.wrongPassphrase` when the caller decrypted with a passphrase (pass a flag).
  - `PEMPrivateKeyDecoder.decode`: armor → by label: `RSA PRIVATE KEY` → (legacy?) → `rsaPKCS1`; `EC PRIVATE KEY` → (legacy?) → `ecSEC1(outerCurve: nil)`; `PRIVATE KEY` → `pkcs8`; `ENCRYPTED PRIVATE KEY` → `pbes2Decrypt` → `pkcs8`; else `.keyType("unknown")`. `isPEM`: trimmed text `hasPrefix("-----BEGIN ")` and not `hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----")`, or `hasPrefix("PuTTY-User-Key-File-")`.
  - `OpenSSHKeyContainer.unencryptedRSA`: `ByteBuffer` (NIOCore) with `writeSSHString` equivalents written locally (uint32 big-endian length + bytes) — do not depend on Citadel's internal helpers; mpint = magnitude with a `0x00` prefix when the first byte's high bit is set; layout `"openssh-key-v1\0"`, string `none`, string `none`, string `""`, uint32 1, string(pubblob = string "ssh-rsa" + mpint e + mpint n), string(private = check ‖ check ‖ string "ssh-rsa" ‖ mpint n ‖ mpint e ‖ mpint d ‖ mpint iqmp ‖ mpint p ‖ mpint q ‖ string comment ‖ padding 1,2,… of `(8 - len % 8) % 8` bytes); base64 in 70-column lines between the OpenSSH boundaries. `check` is `UInt32.random(in:)`.
- [ ] **Step 6: Run** the filter → PASS; `swift build --build-tests` zero warnings; `swift test` green. Mutation probes (record red/green each): swap `e` and `n` in the public blob → container test red; drop the leading-zero mpint rule → the RSA oracle case red for a modulus with a high bit set (2048-bit moduli always have it); change the P-384 prime by one byte → the 384 SEC1 case red; return `.wrongPassphrase` for a missing passphrase → case 5 red.
- [ ] **Step 7: Commit** `feat(ssh): decode PEM private keys — PKCS#1, SEC1, PKCS#8, legacy and PBES2 encryption`.

---

### Task 2: The converter

**Files:**
- Create: `Sources/macSCPCore/SSH/SSHKeyConverter.swift`
- Test: `Tests/macSCPCoreTests/SSHKeyConverterTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum SSHKeyConverter {
      public enum ConversionError: Error, Equatable, Sendable {
          case toolMissing, sourceUnreadable, conversionFailed, destinationExists
      }
      public static let opensshBoundary = "-----BEGIN OPENSSH PRIVATE KEY-----"
      public static func isOpenSSHFormat(fileAt url: URL) -> Bool
      @discardableResult
      public static func copyAsOpenSSH(from source: URL, to destination: URL, passphrase: String?) throws -> Bool
      public static func inPlaceCommandLine(forKeyAt path: String) -> String   // "ssh-keygen -p -f " + PosixQuoting.singleQuoted(path)
  }
  ```
- Consumes: `PosixQuoting.singleQuoted(_:)` (`Sources/macSCPCore/Terminal/PosixQuoting.swift`), `Process` the way `SSHKeyImporter.run` uses it (argument array, stdin and stderr to `FileHandle.nullDevice`).

- [ ] **Step 1: Failing tests** (`@Suite("SSHKeyConverter", .timeLimit(.minutes(2)))`, fixtures from `PEMFixtures`, passphrase constant as in Task 1):
  1. `@Test("every PEM variant converts to an OpenSSH copy and the source is untouched", arguments: …)` over: ssh-keygen `-m PEM` RSA plain, `-m PEM` ECDSA-256 encrypted, `-m PKCS8` RSA encrypted, openssl legacy DES-EDE3, openssl PBES2 DES-EDE3 — `copyAsOpenSSH` returns `true`; destination's first line is the OpenSSH boundary; destination mode is 0600 (`FileManager.attributesOfItem`); source bytes before == after (`Data(contentsOf:)` compared, and the source's mtime unchanged); `PEMFixtures.publicKeyLine(ofKeyAt: destination, passphrase:)` equals the source's.
  2. `@Test("an OpenSSH source is copied without a conversion")` — plain `ssh-keygen -t ed25519` (no `-m`); returns `false`; bytes identical.
  3. `@Test("a wrong passphrase leaves no destination")` — encrypted PEM with `"not-" + constant` → `ConversionError.conversionFailed`; `!FileManager.default.fileExists(atPath: destination)`.
  4. `@Test("an existing destination is refused before anything is written")` → `.destinationExists`, destination bytes unchanged.
  5. `@Test("the command line quotes the path for a POSIX shell")` — path `/tmp/it's here/id rsa` → `ssh-keygen -p -f '/tmp/it'\''s here/id rsa'`.
  6. `@Test("isOpenSSHFormat reads only the first non-blank line")` — three files.
- [ ] **Step 2: Run** `swift test --filter SSHKeyConverter` → FAIL to compile. Record.
- [ ] **Step 3: Implement.** `copyAsOpenSSH`: refuse when `destination` exists; `copyItem`; `setAttributes([.posixPermissions: 0o600])`; if `isOpenSSHFormat(fileAt: destination)` return `false`; else run `/usr/bin/ssh-keygen` with `["-q", "-p", "-P", passphrase ?? "", "-N", passphrase ?? "", "-f", destination.path(percentEncoded: false)]`; non-zero status or a destination that still lacks the boundary → remove destination, throw `.conversionFailed`; `toolMissing` when `/usr/bin/ssh-keygen` is not executable (checked before the copy). Doc comment states the argv accepted-minor by pointing at `SSHKeyImporter`'s paragraph, not by repeating it.
- [ ] **Step 4: Run** the filter → PASS; whole suite green; zero warnings. Probe: skip the `chmod` → case 1's mode check red (ssh-keygen itself refuses a 0644 copy, measured in the design — record which of the two reds you saw).
- [ ] **Step 5: Commit** `feat(ssh): convert a copy of a PEM key to OpenSSH format with ssh-keygen`.

---

### Task 3: The loader reads PEM, and the failure names what it cannot

**Files:**
- Modify: `Sources/macSCPCore/SSH/SSHPrivateKeyLoader.swift`
- Modify: `Sources/macSCPCore/Presentation/ConnectionViewModel.swift` (error mapping; new `ConnectFailureRemedy` + `lastFailureRemedy`)
- Modify: `Sources/macSCPCore/Diagnostics/DialProbes.swift`
- Modify: `Sources/macSCPCore/SSH/ManagedKey.swift` (the `KeyType` doc comment's PEM sentence), `Sources/macSCPCore/SSH/SSHKeyImporter.swift:103` (comment), `Sources/macSCPCore/Sessions/EmbeddedKeyPorter.swift` (the `pemNotSupported`-free but PEM-naming comment near line 412 stays true — read it, change nothing unless it names the case)
- Modify: `Sources/macSCPCore/Resources/{en,de,fr,pl}.lproj/Localizable.strings` — remove `core.connect.keyPEMNotSupported`, add `core.connect.keyPEMNotReadable %@ %@`, `core.connect.pemFeature.cipher %@`, `core.connect.pemFeature.scheme %@`, `core.connect.pemFeature.keyType %@`, `core.connect.pemFeature.putty`, `core.connect.pemFeature.malformed` (six keys, en texts in the design §Part 3)
- Modify tests: `Tests/macSCPCoreTests/SSHPrivateKeyLoaderTests.swift` (`pemKeyIsReported` → replaced), `Tests/macSCPCoreTests/ConnectionViewModelTests.swift:416-427`, `Tests/macSCPCoreTests/ConnectionDiagnosticsTests.swift:1322`, `Tests/macSCPCoreTests/EmbeddedKeyPorterTests.swift:849` (comment), `Tests/macSCPCoreTests/Support/InstalledKey.swift` (`extraKeygenArguments:`), `Tests/macSCPCoreTests/FileKeyTypeIntegrationTests.swift` (PEM cells)

**Interfaces:**
- Consumes: Task 1's `PEMPrivateKeyDecoder`, `OpenSSHKeyContainer`; Task 2's `SSHKeyConverter.inPlaceCommandLine(forKeyAt:)`.
- Produces:
  ```swift
  // SSHKeyError: `case pemNotSupported` is REPLACED by
  case pemNotReadable(PEMReadFailure)
  // ConnectionViewModel.swift, file scope
  public enum ConnectFailureRemedy: Equatable, Sendable { case convertKey(path: String) }
  // ConnectionViewModel
  public private(set) var lastFailureRemedy: ConnectFailureRemedy?
  static func remedy(for error: Error, keyPath: String) -> ConnectFailureRemedy?   // .pemNotReadable → .convertKey(path: NSString(string: keyPath).expandingTildeInPath); else nil
  static func pemFeatureSentence(_ failure: PEMReadFailure) -> String              // the five CoreL10n keys
  ```

- [ ] **Step 1: Failing tests.**
  - Loader: replace `pemKeyIsReported` with `@Test("a PEM key loads", arguments: [("rsa", 2048), ("ecdsa", 256), ("ecdsa", 384), ("ecdsa", 521)], [PEMFixtures.Format.pem, .pkcs8], [false, true])` — `authentication(username:keyPath:passphrase:)` returns; for RSA the offer walk `rsaKeyOffersSHA2Only` already uses (its helper) sees `rsa-sha2-512`/`rsa-sha2-256` and never `ssh-rsa` — add `@Test("a PEM RSA key is offered as rsa-sha2 only")` as the twin. `@Test("an Ed25519 PKCS#8 key loads")` via `PEMFixtures.ed25519PKCS8PEM`. `@Test("a DES-EDE3 PEM key is named")` → `#expect(throws: SSHKeyError.pemNotReadable(.cipher("DES-EDE3-CBC")))`. `@Test("an encrypted PEM key maps the two passphrase failures")` (none → `.passphraseRequired`, wrong → `.wrongPassphrase`) for legacy and PBES2.
  - `ConnectionViewModelTests`: rewrite the `pemNotSupported` test as `pemNotReadableMapsToLocalizedMessageAndRemedy`: connector throws `SSHKeyError.pemNotReadable(.cipher("DES-EDE3-CBC"))` with the form's `keyPath = "~/.ssh/legacy"`; expect `state == .failed(message: String(format: CoreL10n.string("core.connect.keyPEMNotReadable %@ %@"), String(format: CoreL10n.string("core.connect.pemFeature.cipher %@"), "DES-EDE3-CBC"), SSHKeyConverter.inPlaceCommandLine(forKeyAt: expanded)), field: …keyPath)` and `lastFailureRemedy == .convertKey(path: expanded)`; a second test: any other error → `lastFailureRemedy == nil`; a third: the next `connect()` clears it before dialing (connector that records `vm.lastFailureRemedy` when called — it must be `nil` at that moment).
  - `ConnectionDiagnosticsTests:1322`: the row becomes `(AnyDialError(SSHKeyError.pemNotReadable(.putty)), "PEM")` and the sentence is `"the key is a PEM file with a feature this app does not read"` — no payload.
  - Rig: `InstalledKey.swift` — `generateKeyPair`/`makeInstalledKey` gain `extraKeygenArguments: [String] = []` appended to the argument list. `FileKeyTypeIntegrationTests`: `KeyShape` gains `let format: [String]` (`[]` today), `KeyShape.all` unchanged in meaning (five, `format: []`), and a new `static let pem: [KeyShape] = [rsa-2048 ["-m","PEM"], ecdsa-256 ["-m","PEM"], rsa-2048 ["-m","PKCS8"]]`; `@Test("PEM file keys authenticate through macSCP", arguments: KeyShape.pem, [false, true])` with the same body as `fileKeyAuthenticatesThroughMacSCP`. Update `KeyShape`'s "five" comment: it now counts `all`, not every shape.
- [ ] **Step 2: Run** `swift test --filter "SSHPrivateKeyLoader|ConnectionViewModelTests|ConnectionDiagnostics"` → FAIL (compile: `pemNotReadable`, `lastFailureRemedy`). Record.
- [ ] **Step 3: Implement.**
  - Loader: after reading `contents`, `if PEMPrivateKeyDecoder.isPEM(contents) { return try Self.authentication(username:, decoded: try Self.decodePEM(contents, passphrase: passphrase)) }` where `decodePEM` maps `DecodeError` (`.passphraseRequired` → `SSHKeyError.passphraseRequired`, `.wrongPassphrase` → `.wrongPassphrase`, `.notReadable(f)` → `.pemNotReadable(f)`, `.notPEM` → `.unsupportedFormat(reason: "not PEM")`) and the dispatch is: `.rsa(c)` → `.rsaSHA2(username:, privateKey: try Insecure.RSA.PrivateKey(sshRsa: OpenSSHKeyContainer.unencryptedRSA(c, comment: "")), includeSHA1Fallback: false)` (the same explicit `false`, same comment pointer); `.ecdsa(.p256, s)` → `.p256(username:, privateKey: try P256.Signing.PrivateKey(rawRepresentation: s))` and the two siblings; `.ed25519(seed)` → `.ed25519(username:, privateKey: try Curve25519.Signing.PrivateKey(rawRepresentation: seed))`. The old boundary check and `pemNotSupported` go; the doc comment's "PEM-format files … are named rather than parsed" sentence becomes the truth: PEM is parsed, and what the decoder refuses is named.
  - `ConnectionViewModel`: the `case SSHKeyError.pemNotSupported:` arm becomes `case SSHKeyError.pemNotReadable(let failure):` building the message above (the function already has the form's key path in scope — the `keyNotFound` arm compares it against `jumpKeyPath`; use the same expansion). `lastFailureRemedy = nil` directly after `lastFailureReason = nil`; `lastFailureRemedy = Self.remedy(for: error, keyPath: keyPath)` directly after `lastFailureReason = DialSupport.reason(for: error)`. Doc comment on the property: what it is, where it is written, and the `fail(_:kind:)` window it stays out of.
  - `DialProbes`: `case .pemNotReadable: return "the key is a PEM file with a feature this app does not read"`.
  - Catalogs: six keys ×4; German du-form; the `%2$@` positional form in every language.
  - Comments: `ManagedKey.swift:6` ("PEM-format keys are not modelled here at all") → "PEM-format files are read by `PEMPrivateKeyDecoder` since 2026-09-10 and reach the same three cases"; `SSHKeyImporter.swift:103` unchanged in meaning (legacy PEM has no cleartext public part — still true); `EmbeddedKeyPorterTests.swift:849` — replace "refuses PEM for every type (`pemNotSupported`)" with the new truth; grep the whole tree for `pemNotSupported`/`keyPEMNotSupported` at the end: zero hits.
- [ ] **Step 4: Run** the filter → PASS; `swift test` green; `MACSCP_ITEST=1 swift test --filter FileKeyTypeIntegrationTests` with the rig up (from the main checkout) → the three PEM cells × 2 green, log the counts; catalog parity tests green; zero warnings. Probes: make `remedy(for:)` return `.convertKey` for `fileNotFound` → the "any other error" test red; drop the `lastFailureRemedy = nil` clear → the clearing test red.
- [ ] **Step 5: Commit** `feat(ssh): PEM private keys connect, and an unreadable one names its feature and its remedy`.

---

### Task 4: Convert from the key manager and from the failed surface

**Files:**
- Modify: `Sources/MacSCPAppKit/SSHKeysSheet.swift` (`ImportKeySheet`: not `private`; copy→convert→inspect order; `onImported: (ManagedKey, Bool) -> Void`; the one call site at line ~175)
- Modify: `Sources/MacSCPAppKit/ContentView+Detail.swift` (`ConnectFailureContent` + `ConnectFailurePlan.content(hasStoredSession:remedy:)`; `ConnectFailureView` two buttons + two closures; the call site at line ~782)
- Modify: `Sources/MacSCPAppKit/ContentView.swift` (`@State var convertKeyTarget: ImportKeyTarget?`, `.sheet(item:)` in `ContentView+Sheets.swift`, `convertFailedKey(_:)`, `convertedKeyImported(_:for:)`, `copyConversionCommand(for:)`)
- Modify: `Sources/MacSCPAppKit/Resources/{en,de,fr,pl}.lproj/Localizable.strings` — `connection.failed.convertKey` = "Convert key…", `connection.failed.copyCommand` = "Copy command"
- Test: `Tests/macSCPAppKitTests/ConnectFailurePlanTests.swift` (extend), `Tests/macSCPAppKitTests/ConvertKeyWiringGuardTests.swift` (new)

**Interfaces:**
- Consumes: Task 2's `SSHKeyConverter.copyAsOpenSSH` / `inPlaceCommandLine`; Task 3's `ConnectFailureRemedy`, `ConnectionViewModel.lastFailureRemedy`; `SessionListViewModel.updateSession(_:newSecret:jumpSecret:)`; `ManagedKeyStore.privateKeyURL(for:)`; `ContentView.retryConnect(_:)`, `dismissConnectFailure(_:)`, `failedConnectTarget(for:)`.
- Produces:
  ```swift
  struct ImportKeyTarget: Identifiable { let id = UUID(); let fileURL: URL }
  // ConnectFailureContent
  let convertKeyButton: Message?      // non-nil iff remedy == .convertKey
  let copyCommandButton: Message?     // same
  static func content(hasStoredSession: Bool, remedy: ConnectFailureRemedy?) -> ConnectFailureContent
  // ConnectFailureView
  let onConvertKey: () -> Void
  let onCopyCommand: () -> Void
  ```

- [ ] **Step 1: Failing tests.**
  - `ConnectFailurePlanTests`: `everyReachableMessage()` iterates `[nil, .convertKey(path: "/k")]` as well and appends the two optionals; `allowedKeys` gains the two keys (comment count: twelve); `@Test("the conversion buttons appear exactly with a remedy", arguments: [true, false])` — both nil without, both present with; `everyKeyThisPlanProducesIsTranslatedInEveryLanguage` and `theGermanCatalogActuallyTranslatesThisSurface` pick the new keys up through the enumeration (verify they turn red before the catalogs are edited — that is the red for this step).
  - `ConvertKeyWiringGuardTests` (over `SwiftSource.blankingCommentsAndStrings` of `ContentView.swift`, `ContentView+Sheets.swift`, `SSHKeysSheet.swift`): (a) positive: `ContentView+Sheets.swift` contains `.sheet(item: $convertKeyTarget)` and `ImportKeySheet(`; (b) positive: the body of `func convertedKeyImported(` (from its signature to the next top-level `func ` at the same indentation) contains `updateSession(` and `retryConnect(` and `dismissConnectFailure(`; negative beside it: that body contains neither `CitadelFileSystem.connect` nor `connect(in:` (the dial goes through `retryConnect`, the property `ReconnectWiringGuardTests` holds for the surface's other buttons); (c) positive: `SSHKeysSheet.swift`'s `performImport(` body contains `SSHKeyConverter.copyAsOpenSSH(`; negative beside it: it no longer contains `copyItem(`. Each negative names the positive it is pinned by in its comment.
- [ ] **Step 2: Run** `swift test --filter "ConnectFailurePlan|ConvertKeyWiringGuard"` → FAIL. Record.
- [ ] **Step 3: Implement.**
  - `ImportKeySheet.performImport()`: `destination = store.keyDirectory/<newID>`; create the directory (0700, hardened as today); `try SSHKeyConverter.copyAsOpenSSH(from: fileURL, to: destination, passphrase: passphrase.isEmpty ? nil : passphrase)`; `let info = try SSHKeyImporter.inspect(privateKeyURL: destination, passphrase: …)`; `store.add(key)`; the existing cleanup (`removeItem(at: destination)` on any failure after the copy) stays; `onImported(key, keptPassphrase)`. The call site in `SSHKeysSheet` ignores the key: `{ _, keptPassphrase in … }`.
  - `ConnectFailurePlan.content(hasStoredSession:remedy:)`: the two messages non-nil iff `remedy != nil`. `ConnectFailureView`: in the secondary `HStack` beside "Diagnose…", `if let convert = content.convertKeyButton { Button(L10n.string(convert.key, convert.fallback), action: onConvertKey) }` and the copy button likewise. The view renders catalog keys only — `theFailedSurfaceRendersNoStringOfItsOwn` must stay green without edits.
  - Call site (`ContentView+Detail.swift` ~782): `remedy: tab.connectionViewModel.lastFailureRemedy`, `onConvertKey: { convertFailedKey(tab) }`, `onCopyCommand: { copyConversionCommand(for: tab) }`.
  - `ContentView`: `convertFailedKey(_ tab:)` — `guard case .convertKey(let path)? = tab.connectionViewModel.lastFailureRemedy else { return }`; `convertKeyTarget = ImportKeyTarget(fileURL: URL(fileURLWithPath: path))`; the sheet: `.sheet(item: $convertKeyTarget) { target in ImportKeySheet(fileURL: target.fileURL, store: ManagedKeyStore(directory: SessionStore.defaultDirectory)) { key, _ in convertedKeyImported(key, for: activeTab) } }` (resolve the tab the way the other sheets resolve theirs — read `ContentView+Sheets.swift` for the pattern the audit-log sheet uses). `convertedKeyImported(_ key: ManagedKey, for tab: SessionTab)`: `guard let path = ManagedKeyStore(directory: SessionStore.defaultDirectory).privateKeyURL(for: key)?.path(percentEncoded: false) else { return }`; if `let stored = failedConnectTarget(for: tab)`: `var updated = stored; updated.ssh?.keyPath = path; sessionListViewModel.updateSession(updated, newSecret: nil); retryConnect(tab)`; else `tab.connectionViewModel.keyPath = path; dismissConnectFailure(tab)`. `copyConversionCommand(for:)`: `NSPasteboard.general.clearContents(); NSPasteboard.general.setString(SSHKeyConverter.inPlaceCommandLine(forKeyAt: path), forType: .string)`.
  - Catalogs ×4 (German: "Schlüssel konvertieren…", "Befehl kopieren").
- [ ] **Step 4: Run** the filter → PASS; `swift test` green; zero warnings. Probes: remove `retryConnect(` from `convertedKeyImported` → guard (b) red; restore `copyItem(` in `performImport` → guard (c) red; return both buttons unconditionally → the "exactly with a remedy" test red.
- [ ] **Step 5: Commit** `feat(keys): convert a PEM key from the key manager import and from the failed-connect surface`.

---

### Task 5: Closeout

- [ ] `docs/BACKLOG.md`: a Done row for this plan pointing at the design; the "Not covered, by decision" line in `docs/superpowers/specs/2026-08-31-backlog-ssh-key-formats.md` gets a dated addendum ("PEM containers: reversed 2026-09-10, see …") — an addendum, not an edit of the 2026-09-02 sentence. `README.md` "Command line"/keys section: one sentence that PEM keys open directly and that the key manager converts on import. The design's status line lists the five commits. `docs/superpowers/specs/2026-08-20-backlog-dependencies.md`: a line that `swift-asn1` became a direct dependency (version, date, why). This plan's checkboxes. Commit `docs(backlog): PEM private keys are read, converted, or named`.

## Self-review

- Spec coverage: reader (Task 1 + 3), converter and import (Task 2 + 4), message and copy (Task 3 + 4), remedy type (Task 3), surface buttons and wiring (Task 4), docs (Task 5). The design's "explicit PRF" and "iteration ceiling" cases → Task 1 cases 10 and 11; rig cells → Task 3; the `fail(_:kind:)` window → Task 3 Step 3.
- Placeholders: `PEMFixtures.sshStrings` is described, not written out — the plan says what it does (uint32 big-endian length-prefixed loop, nil on a short read); the implementer writes the loop. Everything else carries its values.
- Type consistency: `PEMReadFailure`, `PEMPrivateKeyDecoder.DecodedPrivateKey`, `RSAPrivateKeyComponents`, `OpenSSHKeyContainer.unencryptedRSA(_:comment:)`, `SSHKeyConverter.copyAsOpenSSH(from:to:passphrase:)`, `inPlaceCommandLine(forKeyAt:)`, `SSHKeyError.pemNotReadable(_:)`, `ConnectFailureRemedy.convertKey(path:)`, `lastFailureRemedy`, `ConnectFailurePlan.content(hasStoredSession:remedy:)`, `ImportKeySheet(fileURL:store:onImported:)` with `(ManagedKey, Bool)` are spelled the same in every task that names them.
