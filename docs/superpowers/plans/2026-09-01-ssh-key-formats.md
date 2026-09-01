# SSH Key Formats: Name the Type, Point at the Agent — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A key file macSCP cannot open produces a message that names what
the key IS and what works instead — measured, not claimed — and the agent
route is proved for every key type and for a passphrase-protected key.

**Architecture:** `SSHPrivateKeyLoader` asks Citadel's public
`SSHKeyDetection.detectPrivateKeyType(from:)` BEFORE handing the file to the
ed25519 parser. That reads the cleartext header of an `openssh-key-v1`
file — present even when the private half is encrypted — so an RSA key is
named as RSA before anyone is asked for a passphrase. Two new `SSHKeyError`
cases carry only an algorithm name, never file content. The App maps them
to two new catalog strings. Gated tests extend the existing agent-auth
pattern to P-384, P-521 and a passphrase-protected key loaded through
`ssh-add` with `SSH_ASKPASS`.

**Tech Stack:** Swift 6 (`.swiftLanguageMode(.v6)` on every target), Swift
Testing, Citadel 0.12.1 (`SSHKeyDetection`, `SSHKeyType`), `ssh-keygen` /
`ssh-agent` / `ssh-add` at runtime, Docker rig for the gated suite.

**Source:** `docs/superpowers/specs/2026-08-31-backlog-ssh-key-formats.md`
— the measurements there are binding: RSA from a file parses and then fails
auth (Citadel's file signer is SHA-1 only); ECDSA from a file has no parser;
every type connects through the agent (measured with UNENCRYPTED keys — the
passphrase case is a conclusion until Task 4 measures it).

## Global Constraints

- Code, comments, identifiers, test names, commit messages: **English only**.
- Conventional Commits; footer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- **Never commit key material.** Keys are generated at runtime with
  `ssh-keygen` into a temp directory the test removes. **No secret in an
  `#expect` literal** — `#expect` prints the expression source on failure
  (see CLAUDE.md "two exits"); compute the `Bool` first.
- **An error value carries an algorithm name at most, never file content.**
  `ConnectFailureSecrecyTests.privateKeyLoadFailuresCarryNoSecret` is the
  guard; the new cases must pass it unchanged.
- User-visible text in **all four catalogs** (`en`, `de`, `fr`, `pl` under
  `Sources/macSCPCore/Resources/<locale>.lproj/Localizable.strings`), looked
  up through `CoreL10n.string(_:)`. **No String Catalog, no
  `String(localized:)`, no `Bundle.module`.** German addresses the user as
  **du**. `LocalizationParityTests` fails on a key missing from any catalog.
- **The Go-server caveat is not claimed.** The entry records that the RSA
  agent blob is *reportedly* incompatible with Gitea/Forgejo/SFTPGo — read,
  not measured. No message says it.
- **No own key parser, no decryption.** Type detection reads the cleartext
  header through Citadel's public API; nothing else touches the container.
- Gated tests only under `MACSCP_ITEST=1`; the rig is started from the main
  checkout; every spawned agent is killed AND its socket removed (Task 5).
- Warnings are measured on a **fresh scratch path** with the CI expression
  (`^[^[:space:]]+:[0-9]+:[0-9]+: warning:`); the budget is 1.
- Commit per task. Do not push; the coordinator pushes after the final
  review.

---

### Task 1: The loader names the type before it parses

**Files:**
- Modify: `Sources/macSCPCore/SSH/SSHPrivateKeyLoader.swift`
- Test: `Tests/macSCPCoreTests/SSHPrivateKeyLoaderTests.swift`

**Interfaces:**
- Produces: two new cases on `public enum SSHKeyError`:
  `case typeNotLoadable(algorithm: String)` — an `openssh-key-v1` file whose
  key is not ed25519; `algorithm` is `SSHKeyType.description`
  (`"RSA"`, `"ECDSA P-256"`, `"ECDSA P-384"`, `"ECDSA P-521"`).
  `case pemNotSupported` — the file begins with a PEM boundary other than
  `-----BEGIN OPENSSH PRIVATE KEY-----`. Task 2 maps both.

- [ ] **Step 1: Red — an RSA key must be named, not "unsupported".**
  Extend the test file's generator to take a type:

```swift
/// Generates a key of `type` in the temp directory; passphrase "" = unencrypted.
/// `extra` is appended to the ssh-keygen argument list (e.g. `["-b", "384"]`,
/// `["-m", "PEM"]`).
private func makeKey(type: String = "ed25519", passphrase: String = "",
                     extra: [String] = []) throws -> (dir: URL, keyPath: String) {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("macscp-key-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let keyURL = dir.appendingPathComponent("id_\(type)")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
    process.arguments = ["-t", type, "-f", keyURL.path(percentEncoded: false),
                         "-N", passphrase, "-q", "-C", "macscp-test"] + extra
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    return (dir, keyURL.path(percentEncoded: false))
}
```

  Keep the existing `makeKey(passphrase:)` call sites compiling (default
  `type`). Then the tests, one per shape — all must be RED first:

```swift
@Test("an RSA key is named RSA, not 'unsupported'")
func rsaKeyIsNamed() throws {
    let (dir, keyPath) = try makeKey(type: "rsa", extra: ["-b", "2048"])
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(throws: SSHKeyError.typeNotLoadable(algorithm: "RSA")) {
        _ = try SSHPrivateKeyLoader.authentication(username: "tim", keyPath: keyPath, passphrase: nil)
    }
}

@Test("an ECDSA key is named with its curve", arguments: [(256, "ECDSA P-256"), (384, "ECDSA P-384"), (521, "ECDSA P-521")])
func ecdsaKeyIsNamed(bits: Int, expected: String) throws {
    let (dir, keyPath) = try makeKey(type: "ecdsa", extra: ["-b", String(bits)])
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(throws: SSHKeyError.typeNotLoadable(algorithm: expected)) {
        _ = try SSHPrivateKeyLoader.authentication(username: "tim", keyPath: keyPath, passphrase: nil)
    }
}

/// The header is cleartext even when the private half is encrypted, so an
/// encrypted RSA key is named BEFORE anyone is asked for a passphrase — the
/// order that used to produce "passphrase required" for a key that could
/// never have been used.
@Test("an encrypted RSA key is named without a passphrase")
func encryptedRSAKeyIsNamedFirst() throws {
    let (dir, keyPath) = try makeKey(type: "rsa", passphrase: "geheime-phrase", extra: ["-b", "2048"])
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(throws: SSHKeyError.typeNotLoadable(algorithm: "RSA")) {
        _ = try SSHPrivateKeyLoader.authentication(username: "tim", keyPath: keyPath, passphrase: nil)
    }
}

@Test("a PEM-format key is reported as PEM, not as garbage")
func pemKeyIsReported() throws {
    let (dir, keyPath) = try makeKey(type: "rsa", extra: ["-b", "2048", "-m", "PEM"])
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(throws: SSHKeyError.pemNotSupported) {
        _ = try SSHPrivateKeyLoader.authentication(username: "tim", keyPath: keyPath, passphrase: nil)
    }
}
```

- [ ] **Step 2: Run** `swift test --filter SSHPrivateKeyLoaderTests` — the
  new tests fail (they get `unsupportedFormat` or `passphraseRequired`).
  Confirm `ssh-keygen -t rsa -m PEM` on this machine really writes
  `-----BEGIN RSA PRIVATE KEY-----` (`head -1` the file) — if it writes the
  OpenSSH format, say so in the report and drop the PEM test rather than
  fake it.
- [ ] **Step 3: Implement.** In `SSHPrivateKeyLoader.authentication`, after
  reading `contents` and before the ed25519 parse:

```swift
// Name the key before parsing it. The openssh-key-v1 header is cleartext
// even when the private half is encrypted, so an RSA key is reported as
// RSA before anyone is asked for a passphrase it could never have used.
// Citadel's file signer is SHA-1 only for RSA and has no ECDSA parser
// (measured 2026-08-31, see the backlog entry); ed25519 is the one type
// this loader can hand to a connection.
let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
if trimmed.hasPrefix("-----BEGIN ") && !trimmed.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----") {
    throw SSHKeyError.pemNotSupported
}
if let type = try? SSHKeyDetection.detectPrivateKeyType(from: contents), type != .ed25519 {
    throw SSHKeyError.typeNotLoadable(algorithm: type.description)
}
```

  `try?` on the detector is deliberate: a file the detector cannot read
  falls through to the ed25519 parser, whose errors the existing `map`
  already turns into `unsupportedFormat` — the garbage test stays green.
  Add the two cases to `SSHKeyError`. Replace the stale doc comment on the
  enum ("RSA/ecdsa and ssh-agent are deliberately deferred (YAGNI)") — the
  agent exists (`AgentBackedPrivateKey`) and is the measured route for the
  other types; say that instead.
- [ ] **Step 4: Run** the loader suite (green), then
  `swift test --filter ConnectFailureSecrecyTests` (must stay green — the
  new cases carry an algorithm name only).
- [ ] **Step 5: Commit** — `feat(ssh): name a key's type before trying to load it`

---

### Task 2: The message says what the key is and what works

**Files:**
- Modify: `Sources/macSCPCore/Presentation/ConnectionViewModel.swift` (the
  `SSHKeyError` cases in the failure mapping, near the existing
  `case SSHKeyError.unsupportedFormat:`)
- Modify: `Sources/macSCPCore/Resources/{en,de,fr,pl}.lproj/Localizable.strings`
- Test: `Tests/macSCPCoreTests/ConnectionViewModelTests.swift`

**Interfaces:**
- Consumes: `SSHKeyError.typeNotLoadable(algorithm:)`, `.pemNotSupported` from Task 1.

- [ ] **Step 1: Red.** Find how `ConnectionViewModelTests` drives a connect
  failure through the mapping (search for `keyPassphraseRequired` or
  `.failed(message:` in that file and copy the nearest pattern). Assert that
  a `typeNotLoadable(algorithm: "RSA")` failure yields a message that
  contains `"RSA"` and the `en` text of `core.connect.keyTypeNotLoadable %@`
  with `"RSA"` substituted, and that `pemNotSupported` yields
  `core.connect.keyPEMNotSupported`. Both red (the cases fall into the
  generic branch today).
- [ ] **Step 2: Strings**, exact `en` text, the other three rendered from it:

```
"core.connect.keyTypeNotLoadable %@" = "This is an %@ key. macSCP opens only OpenSSH ed25519 keys from a file — load this key into the ssh-agent (ssh-add) and choose the agent as the login instead.";
"core.connect.keyPEMNotSupported" = "This key is in PEM format. macSCP opens OpenSSH-format keys — convert it with ssh-keygen -p (the passphrase stays), or load it into the ssh-agent and choose the agent as the login.";
"core.connect.keyUnsupportedFormat" = "This file could not be read as an SSH key. macSCP opens OpenSSH ed25519 keys from a file; other types work through the ssh-agent.";
```

  German (du): „Das ist ein %@-Schlüssel. macSCP öffnet aus einer Datei nur
  OpenSSH-ed25519-Schlüssel — lade diesen Schlüssel in den ssh-agent
  (ssh-add) und wähle den Agenten als Anmeldung." — and the other two in
  the same register. `%@` is the algorithm; keep it in every catalog. Measure
  the `ssh-keygen -p` claim before shipping the PEM string: generate a PEM
  key, run `ssh-keygen -p -N '' -f <key>`, `head -1` it. If it does not
  come back as `-----BEGIN OPENSSH PRIVATE KEY-----`, drop the conversion
  hint from all four catalogs and say so in the report.
- [ ] **Step 3: Mapping** — two new `case` arms beside
  `case SSHKeyError.unsupportedFormat:`, both `field: Self.sshField(.keyPath)`
  (and the jump-key twin if the surrounding code distinguishes it — read
  the `fileNotFound` arm, it does).
- [ ] **Step 4: Run** `swift test --filter "ConnectionViewModelTests|LocalizationParityTests|GermanAddressFormTests"` — green.
- [ ] **Step 5: Commit** — `feat(ssh): say what a key is and what works instead`

---

### Task 3: One table instead of two literals in `AgentPrivateKeyFactory`

**Files:**
- Modify: `Sources/macSCPCore/SSH/AgentBackedPrivateKey.swift` (`enum AgentPrivateKeyFactory`)
- Test: `Tests/macSCPCoreTests/` — the suite that already covers
  `AgentPrivateKeyFactory.supports(keyType:)` (search for it; if none
  exists, add `AgentPrivateKeyFactoryTests.swift`)

The entry counted it: `supportedKeyTypes` and the `switch` in
`privateKey(for:client:)` list the same five names twice. A rename pulls
them apart silently — `supports` says yes, `privateKey` returns `nil`, and
the connect loop skips an identity it just promised to try.

- [ ] **Step 1: Red — plant the drift.** Temporarily remove `"ssh-rsa"` from
  `supportedKeyTypes` only and run the existing agent-factory tests. If
  nothing goes red, that is the finding: write a test that, for every type
  in `supportedKeyTypes`, builds a fake `AgentIdentity` of that type and
  expects `privateKey(for:client:)` to be non-nil — and the converse, that
  a type the switch handles is in the set. Restore the literal.
- [ ] **Step 2: Implement** — one table:

```swift
/// The closed set of agent key types, as ONE table: the name and the
/// factory for it live in the same entry, so `supports` and `privateKey`
/// cannot disagree. Used by `CitadelFileSystem.connectHop` to pre-filter
/// identities before spending a reconnect on one.
private static let factories: [String: @Sendable (AgentIdentity, SSHAgentClient) -> NIOSSHPrivateKey] = [
    "ssh-ed25519":          { NIOSSHPrivateKey(custom: AgentBackedPrivateKey<AgentAlgorithm.Ed25519>(identity: $0, client: $1)) },
    "ecdsa-sha2-nistp256":  { NIOSSHPrivateKey(custom: AgentBackedPrivateKey<AgentAlgorithm.ECDSAP256>(identity: $0, client: $1)) },
    "ecdsa-sha2-nistp384":  { NIOSSHPrivateKey(custom: AgentBackedPrivateKey<AgentAlgorithm.ECDSAP384>(identity: $0, client: $1)) },
    "ecdsa-sha2-nistp521":  { NIOSSHPrivateKey(custom: AgentBackedPrivateKey<AgentAlgorithm.ECDSAP521>(identity: $0, client: $1)) },
    "ssh-rsa":              { NIOSSHPrivateKey(custom: AgentBackedPrivateKey<AgentAlgorithm.RSASha512>(identity: $0, client: $1)) },
]
static func supports(keyType: String) -> Bool { factories[keyType] != nil }
static func privateKey(for identity: AgentIdentity, client: SSHAgentClient) -> NIOSSHPrivateKey? {
    factories[identity.keyType]?(identity, client)
}
```

  Check `AgentIdentity` and `SSHAgentClient` are `Sendable` (a `@Sendable`
  closure in a static requires it under `.v6`); if the client is not,
  drop `@Sendable` and mark the table `nonisolated(unsafe)` is NOT the
  answer — report it and keep the switch, with the test from Step 1 as the
  guard instead.
- [ ] **Step 3: Run** the unit suite; measure warnings on a fresh scratch path.
- [ ] **Step 4: Commit** — `refactor(ssh): one table for the agent key types`

---

### Task 4: The agent route is measured for P-384, P-521 and a passphrase-protected key

**Files:**
- Modify: `Tests/macSCPCoreTests/CitadelFileSystemIntegrationTests.swift`
  (`makeInstalledKey`, `addKey`, new tests beside `agentAuthConnectsECDSA`)

**Why:** the entry's table says all three ECDSA curves connect through the
agent — measured by a throwaway script, not by a test in the tree. And the
passphrase case, the one 90 % of this project's users are in, is a
conclusion from how ssh-agent works, not a measurement. Task 2's message
sends users down this route; a test must hold it.

- [ ] **Step 1: Curves.** Copy `agentAuthConnectsECDSA` twice as
  `agentAuthConnectsECDSAP384` / `agentAuthConnectsECDSAP521` with
  `makeInstalledKey(type: "ecdsa", bits: 384)` / `521`. Run under
  `MACSCP_ITEST=1` — both must connect. If one does not, that is a finding
  for the report, not something to fix here.
- [ ] **Step 2: Passphrase — the helper.** `ssh-add` reads the passphrase
  from `SSH_ASKPASS` when `SSH_ASKPASS_REQUIRE=force` is set and no
  terminal is attached. Extend `addKey`:

```swift
/// Adds a key to the spawned agent. For an encrypted key, `passphrase` is
/// handed to ssh-add through an SSH_ASKPASS helper the test writes into
/// `dir` and removes — never through argv, never through stdin of the test
/// process. The helper is a two-line shell script that prints the
/// passphrase; it is 0700 and lives only for the call.
private func addKey(atPath keyPath: String, to agent: SpawnedAgent,
                    passphrase: String? = nil, helperDirectory: URL? = nil) throws {
    let add = Process()
    add.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-add")
    add.arguments = [keyPath]
    var environment = [
        "SSH_AUTH_SOCK": agent.socketPath,
        "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
    ]
    var helper: URL?
    if let passphrase, let helperDirectory {
        let script = helperDirectory.appendingPathComponent("askpass.sh")
        try "#!/bin/sh\nprintf '%s' '\(passphrase)'\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path(percentEncoded: false))
        environment["SSH_ASKPASS"] = script.path(percentEncoded: false)
        environment["SSH_ASKPASS_REQUIRE"] = "force"
        environment["DISPLAY"] = ":0"
        helper = script
    }
    add.environment = environment
    try add.run()
    add.waitUntilExit()
    if let helper { try? FileManager.default.removeItem(at: helper) }
    #expect(add.terminationStatus == 0)
}
```

  The passphrase is a test constant with no security value; it still does
  not appear in an `#expect` literal.
- [ ] **Step 3: Passphrase — the test.** `makeInstalledKey` needs a
  `passphrase:` parameter passed to `-N`. Then
  `agentAuthConnectsWithPassphraseProtectedKey`: ed25519 key with a
  passphrase, added through the helper, `.agent` login, `list("/data/seed")`
  contains `hello.txt`. Run it. **This is the measurement the entry marked
  as missing** — record the outcome in the report either way.
- [ ] **Step 4: Run** the whole gated suite once (`MACSCP_ITEST=1 swift test`).
- [ ] **Step 5: Commit** — `test(ssh): measure the agent route for every curve and for a passphrase-protected key`

---

### Task 5: The gated suite removes the sockets it creates

**Files:**
- Modify: `Tests/macSCPCoreTests/CitadelFileSystemIntegrationTests.swift` (`killAgent`)

Measured 2026-09-01: on this macOS, `ssh-agent -s` puts its socket directly
into `~/.ssh/agent/` (e.g. `s.qVAlalc9PG.agent.mzEFNLzaZz`), a directory it
shares with every other agent and recreates on its own. `killAgent` sends
TERM and stops; the socket file stays. Two leftovers from 21.08. and 28.08.
were found there.

- [ ] **Step 1: Implement** — after `waitUntilExit`, remove exactly
  `agent.socketPath` (the file — never its parent directory, which is
  shared):

```swift
// The agent's socket lives in the shared ~/.ssh/agent/ on this macOS and
// outlives the process. Remove the FILE; the directory belongs to every
// agent on the machine.
try? FileManager.default.removeItem(atPath: agent.socketPath)
```

- [ ] **Step 2: Prove it** — count entries in `~/.ssh/agent/` before and after
  one gated agent test in the report (`ls ~/.ssh/agent | wc -l`); the
  count must be unchanged.
- [ ] **Step 3: Commit** — `test(ssh): remove the agent socket the gated suite creates`

---

### Task 6: Backlog entry closes

**Files:**
- Modify: `docs/superpowers/specs/2026-08-31-backlog-ssh-key-formats.md`

- [ ] **Step 1:** Append a "Done 2026-09-0x" section: what shipped per task,
  the measured outcomes of Task 4 (three curves, the passphrase case — as
  measured, including a failure if there was one), and the one thing that
  is still not measured: the Go-server RSA claim.
- [ ] **Step 2: Commit** — `docs(backlog): close the ssh key formats entry`

## What is explicitly not in this plan

- **No RSA-from-file support.** Citadel's signer is SHA-1; the fix is
  Citadel PR #135 or a Citadel fork, and this plan does neither.
- **No own container parser and no decryption.**
- **No change to `ManagedKey.KeyType.isConnectable`** — the key manager
  still offers only ed25519 as a file login; the agent is a separate login.
- **No change to TOFU** or to the hard stop on a fingerprint mismatch.
