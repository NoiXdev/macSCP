# M23 Phase 1 — Foundation and Session Lifecycle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Collapse `connect()`, `validateForEditSave()` and `beginEditing()` to one body each by making field validation declarative in the schema, and move SSH's flat top-level fields into their own `ssh:` block — so a fourth protocol costs zero lines in `ConnectionViewModel`, `ContentView`, `SessionListViewModel` and `ConnectionFormView`.

**Architecture:** Two new declarations on `ConnectionField` (`format`, `invalidMessageKey`) plus one pure Core validator (`firstViolation`) replace the six hand-written validation bodies. A `apply: (FieldValues, inout StoredSession) -> Void` closure on `BackendDescriptor` — the write counterpart to M22's read-only `sessionValues(_:)` — replaces the three bodies that hand-assemble a `StoredSession`. Only then does `StoredSession` change shape, because by that point almost nothing constructs one directly.

**Tech Stack:** Swift 6 toolchain in `.swiftLanguageMode(.v5)`, SwiftPM, macOS 15+, SwiftUI, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-08-07-m23-session-lifecycle-design.md`

## Global Constraints

- **Code and comments: English only.** No German in source files, test names or `reason:` strings.
- **App UI is localized.** All four catalogs (`en`/`de`/`fr`/`pl`) carry every key and stay identical in key set — a guard test enforces this. Core's catalogs are `Sources/macSCPCore/Resources/<lang>.lproj/Localizable.strings`. French uses the typographic apostrophe (U+2019). CLI output is English-only.
- Swift tools 6.0, all targets `.swiftLanguageMode(.v5)`, minimum macOS 15.
- Tests: Swift Testing (`@Test`/`#expect`), TDD red→green. Prove every regression red first.
- Unit suite: `swift test`. Gated: `MACSCP_ITEST=1` (Docker rig), `MACSCP_KEYCHAIN=1`.
- Docker rig: `docker compose -f docker/test-server/compose.yml up -d`, **always from the main checkout, never a git worktree.**
- **Never commit key material or secrets.** Test keys are generated at runtime via `ssh-keygen`. Secrets live exclusively in the Keychain (`SecretStore`); JSON stores never contain them. A secret's value must never be printed, logged or embedded in an error.
- **TOFU is a hard stop.** A host-key or TLS-certificate fingerprint mismatch never consults the user decider and has no accept-anything path. Task 5 touches the connect path — any change there needs a line-by-line comparison against current behaviour, not a plausibility argument.
- Conventional Commits, English messages. Footer on every commit: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`. **Commit only; never push** — the coordinator pushes per milestone.
- Do not launch the GUI app. Verification is `swift test` plus `swift build`.

## Behaviour changes this phase makes deliberately

Three, all of them consequences of the design rather than incidental. A reviewer should accept or reject them explicitly:

1. **`ConnectionViewModel.Field` loses its SSH cases** (`.host`, `.port`, `.username`, `.password`, `.keyPath`) and gains `.schema(String)` carrying a namespaced `FieldValues` key. Consequence: **S3 and WebDAV form fields start highlighting on error** — today they always report `field: nil` because the App's `failedFieldID` mapping hardcodes SSH's namespace.
2. **`SSHField.keyPath` becomes `isRequired: true`.** `connect()` already refuses a private-key login with a blank path; the login-set editor did not. After this task a private-key login *set* with a blank key path is also unsaveable. M22's comment on `isRequired` worried that "a key path may be blank because an agent or managed-key login supplies it another way" — but the field is `visibleWhen: authKind == privateKey`, so an agent login never reaches the check, and the managed-key picker writes `keyPath` before save.
3. **Validation order becomes schema order.** Today `connectSSH` checks port → secret, while `validateForEditSaveSSH` checks host → port → username → name → keyPath. Afterwards both walk connection-schema order then credential-schema order. Which message appears when *two* fields are blank can change; which fields are rejected does not.

## File structure

**Created**

| File | Responsibility |
|---|---|
| `Tests/macSCPCoreTests/SessionFixtures.swift` | The one place tests build a `StoredSession`. Absorbs the whole Task 8 format change in three function bodies. |
| `Sources/macSCPCore/Sessions/StoredSSHConfig.swift` | SSH's persisted block, sibling to `StoredS3Config`/`StoredWebDAVConfig`. |
| `Sources/macSCPCore/Sessions/LegacyStoredSession.swift` | Decode-only mirror of the pre-M23 flat shape plus its upgrade. Never written. |
| `Tests/macSCPCoreTests/Fixtures/legacy-sessions-pre-m23.json` | Frozen file in today's exact format. The only test that proves nobody loses their connections. |

**Modified**

| File | Change |
|---|---|
| `Sources/macSCPCore/Capabilities/FieldVocabulary.swift` | `FieldFormat`; `LeafField` untouched. |
| `Sources/macSCPCore/Capabilities/ConnectionFieldSchema.swift` | `ConnectionField.format` + `.invalidMessageKey`; `firstViolation(in:namespace:requireSecrets:)`. |
| `Sources/macSCPCore/Capabilities/BackendDescriptor.swift` | `apply` closure; `firstViolation(in:requireSecrets:)` over both schemas. |
| `Sources/macSCPCore/{SSH,S3,WebDAV}/*FieldSchema.swift` | Declare `format`/`invalidMessageKey`/`isRequired`; S3+WebDAV gain `apply`. |
| `Sources/macSCPCore/Presentation/ConnectionViewModel.swift` | Six bodies become three; `Field.schema`; `editingOriginal`. |
| `Sources/macSCPCore/Presentation/SessionListViewModel.swift` | `save(...)` takes `values:` instead of the flat fields. |
| `Sources/macSCPCore/Sessions/StoredSession.swift` | Flat fields → `ssh:` block. |
| `Sources/macSCPCore/Sessions/SessionStore.swift` | `sessions-v2.json` + one-time migration. |
| `Sources/MacSCPApp/ContentView.swift` | The three save branches become one; the prefill branches go. |
| `Sources/MacSCPApp/ConnectionFormView.swift` | `failedFieldID` becomes a pass-through. |

---

### Task 1: One fixture helper for every test session

**Why first:** 136 of the 144 `StoredSession(…)` construction sites are test fixtures across 21 files, and no shared helper exists. Migrating them *while the type is unchanged* is purely mechanical and keeps the suite green throughout. Task 8 then edits three function bodies instead of 136 call sites — and a reviewer can tell a behavioural mistake from a transcription slip.

**Files:**
- Create: `Tests/macSCPCoreTests/SessionFixtures.swift`
- Modify: all 21 test files that construct `StoredSession` directly
- Test: the existing suite is the test — it must stay green, unchanged in meaning

**Interfaces:**
- Produces: `sshSession(id:name:host:port:username:authKind:keyPath:groupID:loginSetID:jump:)`, `s3Session(id:name:groupID:loginSetID:config:)`, `webdavSession(id:name:groupID:loginSetID:config:)` — all `-> StoredSession`, all internal to the test target.

- [ ] **Step 1: Write the helper**

`Tests/macSCPCoreTests/SessionFixtures.swift`:

```swift
import Foundation
@testable import macSCPCore

// Test fixtures for `StoredSession`. The ONE place the test target builds one.
//
// Not convenience: insulation. `StoredSession`'s shape changes in this
// milestone, and without this file that change would mean 136 hand edits
// across 21 files — where a mistyped port produces a test that still passes
// while asserting the wrong thing. With it, the change is three bodies.
//
// Defaults are deliberately recognisable rather than realistic: a test that
// depends on a value should name it.

func sshSession(
    id: UUID = UUID(),
    name: String,
    host: String = "example.com",
    port: Int = 22,
    username: String = "tim",
    authKind: StoredSession.AuthKind = .password,
    keyPath: String? = nil,
    groupID: UUID? = nil,
    loginSetID: UUID? = nil,
    jump: StoredSession.JumpSpec? = nil
) -> StoredSession {
    StoredSession(
        id: id, name: name, host: host, port: port, username: username,
        authKind: authKind, keyPath: keyPath, groupID: groupID,
        loginSetID: loginSetID, jump: jump, kind: .ssh)
}

func s3Session(
    id: UUID = UUID(),
    name: String,
    groupID: UUID? = nil,
    loginSetID: UUID? = nil,
    config: StoredS3Config = StoredS3Config(
        accessKeyID: "AKIA", region: "eu-central-1",
        endpoint: "https://s3.example.com", bucket: "bucket", usePathStyle: false)
) -> StoredSession {
    StoredSession(
        id: id, name: name, host: "unused", port: 22, username: "unused",
        groupID: groupID, loginSetID: loginSetID, kind: .s3, s3: config)
}

func webdavSession(
    id: UUID = UUID(),
    name: String,
    groupID: UUID? = nil,
    loginSetID: UUID? = nil,
    config: StoredWebDAVConfig = StoredWebDAVConfig(
        baseURL: "https://cloud.example.com/remote.php/dav",
        username: "tim", useNextcloudPath: false)
) -> StoredSession {
    StoredSession(
        id: id, name: name, host: "unused", port: 22, username: "unused",
        groupID: groupID, loginSetID: loginSetID, kind: .webdav, webdav: config)
}
```

- [ ] **Step 2: Verify it compiles before touching any call site**

Run: `swift build --build-tests 2>&1 | tail -20`
Expected: builds clean. The helper is unused at this point, which is fine.

- [ ] **Step 3: Migrate the call sites, file by file**

Work through these in descending order, committing after each **group** of ~5 files so a mistake is bisectable:

```
23  LoginMergePlannerTests.swift          19  SessionImportPlannerTests.swift
18  LoginResolverTests.swift              18  ConnectionViewModelTests.swift
17  SessionListViewModelTests.swift        8  LoginResolverSchemaTests.swift
 7  SessionStoreTests.swift                6  JumpSessionEligibilityTests.swift
 3  SSHFieldSchemaTests.swift              3  CLIRoundtripITests.swift
 2  WebDAVRegistrationTests.swift          2  StoredSessionConnectionConfigTests.swift
 2  StoredSessionCompatTests.swift         2  CitadelFileSystemIntegrationTests.swift
 2  CLISecretSourcesSchemaTests.swift      1  StoredSessionTests.swift
 1  SessionReferenceTests.swift            1  S3FileSystemIntegrationTests.swift
 1  CLISecretSourcesTests.swift
```

Rules for the migration — **read all four before starting**:

1. **Never change a value a test names.** `StoredSession(name: "web", host: "example.com", username: "unused", loginSetID: set.id, kind: .ssh)` becomes `sshSession(name: "web", host: "example.com", username: "unused", loginSetID: set.id)` — the `"unused"` username stays, because that test is *about* a session whose username comes from a login set.
2. **Do not let a default silently replace a named value.** If a call site says `port: 22`, keep writing `port: 22`. Dropping it because the default matches makes a later default change invisible.
3. **Leave `StoredSessionCompatTests.swift` and `StoredSessionTests.swift` alone if they test the initializer or the Codable shape itself.** Those are *about* `StoredSession`'s surface; routing them through a helper would remove the very coverage Task 8 depends on. Migrate only the fixtures that are incidental to what the test asserts.
4. **`WebDAVRegistrationTests.swift` builds `var session = StoredSession(...)` then mutates `session.kind`/`session.webdav`.** Replace the whole construction with `webdavSession(name: "cloud", config: ...)`, not just the initializer call.

- [ ] **Step 4: Verify the suite is green and the count is zero**

Run:

```bash
swift test 2>&1 | tail -5
```

Expected: same test count as before this task, all passing.

Then confirm the migration is complete:

```bash
grep -rn --include='*.swift' 'StoredSession(' Tests | grep -v 'func \|-> StoredSession\|\[StoredSession\]'
```

Expected: only `SessionFixtures.swift` plus whatever `StoredSessionCompatTests.swift` / `StoredSessionTests.swift` deliberately kept under rule 3. Every remaining line must be justifiable out loud.

- [ ] **Step 5: Commit**

```bash
git add Tests/macSCPCoreTests
git commit -m "test(core): build every fixture session through one helper

136 of 144 StoredSession construction sites were test fixtures across 21
files with no shared helper. Routing them through sshSession/s3Session/
webdavSession makes the upcoming format change three function bodies
instead of 136 hand edits.

No production code changes; no test changes meaning.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Declare format and message on every field

**Files:**
- Modify: `Sources/macSCPCore/Capabilities/FieldVocabulary.swift`
- Modify: `Sources/macSCPCore/Capabilities/ConnectionFieldSchema.swift`
- Modify: `Sources/macSCPCore/SSH/SSHFieldSchema.swift`, `Sources/macSCPCore/S3/S3FieldSchema.swift`, `Sources/macSCPCore/WebDAV/WebDAVFieldSchema.swift`
- Modify: `Sources/macSCPCore/Resources/{en,de,fr,pl}.lproj/Localizable.strings`
- Test: `Tests/macSCPCoreTests/SchemaConformanceTests.swift` (add to the existing file)

**Interfaces:**
- Produces: `FieldFormat.numeric`; `ConnectionField.format: FieldFormat?`; `ConnectionField.invalidMessageKey: String?`; the init gains both with `nil` defaults.

- [ ] **Step 1: Write the failing guard test**

Append to `Tests/macSCPCoreTests/SchemaConformanceTests.swift`:

```swift
/// Every field that can FAIL validation must say what to tell the user.
/// Without this the validator falls back to a generic message and a field
/// silently loses the specific text it used to have — the exact regression
/// "the port must be a number" flattening into "this field is required".
@Test func everyValidatableFieldDeclaresItsMessage() {
    for kind in ConnectionKind.allCases {
        let descriptor = BackendDescriptor.descriptor(for: kind)
        for schema in [descriptor.connectionSchema, descriptor.credentialSchema] {
            for field in schema.fields where field.isRequired || field.format != nil {
                #expect(
                    field.invalidMessageKey != nil,
                    "\(kind).\(field.id) can fail validation but declares no message key")
            }
        }
    }
}

/// The port is the ONE numeric field in the app. Pinned so that adding a
/// second `.numeric` field is a deliberate act with a test to update, not a
/// drive-by.
@Test func onlyTheSSHPortIsNumeric() {
    let numeric = ConnectionKind.allCases.flatMap { kind -> [String] in
        let descriptor = BackendDescriptor.descriptor(for: kind)
        return [descriptor.connectionSchema, descriptor.credentialSchema]
            .flatMap(\.fields)
            .filter { $0.format == .numeric }
            .map { "\(kind).\($0.id)" }
    }
    #expect(numeric == ["ssh.port"])
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter SchemaConformance 2>&1 | tail -20`
Expected: FAIL — `value of type 'ConnectionField' has no member 'format'`.

- [ ] **Step 3: Add the vocabulary**

In `Sources/macSCPCore/Capabilities/FieldVocabulary.swift`, after `OptionSource`:

```swift
/// A parse rule a field's raw string must satisfy (M23).
///
/// Exactly one case, and deliberately so: the port is the only format rule in
/// the entire pre-M23 validation code. A second case should arrive with a
/// second real need, not in anticipation of one — the same discipline that
/// keeps `FieldCondition` from growing into an expression language.
public enum FieldFormat: Sendable, Equatable {
    case numeric
}
```

In `Sources/macSCPCore/Capabilities/ConnectionFieldSchema.swift`, add to `ConnectionField` after `isRequired`:

```swift
    /// A parse rule the raw value must satisfy while this field is visible
    /// (M23). `nil` means any string is acceptable.
    public let format: FieldFormat?

    /// The localized message to show when this field is blank-but-required or
    /// violates its `format` (M23). ONE key covers both, because the two are
    /// the same complaint from the user's side: a blank port and the text
    /// "abc" both mean "the port must be a number".
    ///
    /// Optional in the type, mandatory in practice —
    /// `everyValidatableFieldDeclaresItsMessage` fails the build for a field
    /// that can fail validation without declaring one. The fallback below it
    /// exists so a slip degrades to a correct-but-generic message rather than
    /// to silence.
    public let invalidMessageKey: String?
```

and widen the initializer:

```swift
    public init(id: String, labelKey: String, labelDefault: String,
                kind: Kind, visibleWhen: FieldCondition? = nil,
                isRequired: Bool = false, format: FieldFormat? = nil,
                invalidMessageKey: String? = nil) {
        self.id = id; self.labelKey = labelKey; self.labelDefault = labelDefault
        self.kind = kind; self.visibleWhen = visibleWhen; self.isRequired = isRequired
        self.format = format; self.invalidMessageKey = invalidMessageKey
    }
```

- [ ] **Step 4: Declare the rules on SSH**

In `Sources/macSCPCore/SSH/SSHFieldSchema.swift`, `connection`:

```swift
            ConnectionField(id: SSHField.host.rawValue,
                            labelKey: "connection.field.host",
                            labelDefault: "Host", kind: .text,
                            isRequired: true,
                            invalidMessageKey: "core.connect.emptyHost"),
            ConnectionField(id: SSHField.port.rawValue,
                            labelKey: "connection.field.port",
                            labelDefault: "Port", kind: .number,
                            format: .numeric,
                            invalidMessageKey: "core.connect.portNumeric"),
```

(the `jump` group field is unchanged — its leaves are validated by `validateJump`, which stays a form rule)

and in `credential`:

```swift
            ConnectionField(id: SSHField.username.rawValue,
                            labelKey: "connection.field.username",
                            labelDefault: "Username", kind: .text,
                            isRequired: true,
                            invalidMessageKey: "core.connect.emptyUsername"),
            ConnectionField(id: SSHField.authKind.rawValue,
                            labelKey: "connection.field.authMethod",
                            labelDefault: "Authentication",
                            kind: .picker(.fixed(authOptions))),
            ConnectionField(id: SSHField.password.rawValue,
                            labelKey: "connection.auth.password",
                            labelDefault: "Password", kind: .secret,
                            visibleWhen: onPassword,
                            isRequired: true,
                            invalidMessageKey: "core.connect.passwordEmpty"),
            // The passphrase stays OPTIONAL: an unencrypted key has none, and
            // `makeConfig` already turns an empty secret into `nil` rather
            // than an empty passphrase.
            ConnectionField(id: SSHField.passphrase.rawValue,
                            labelKey: "connection.field.passphrase",
                            labelDefault: "Passphrase (optional)", kind: .secret,
                            visibleWhen: onPrivateKey),
            ConnectionField(id: SSHField.keyPath.rawValue,
                            labelKey: "connection.field.keyPath",
                            labelDefault: "Key path", kind: .text,
                            visibleWhen: onPrivateKey,
                            isRequired: true,
                            invalidMessageKey: "core.connect.keyPathEmpty"),
            ConnectionField(id: SSHField.managedKeyID.rawValue,
                            labelKey: "keys.picker.managed",
                            labelDefault: "Managed key",
                            kind: .picker(.managedKeys), visibleWhen: onPrivateKey),
```

Then **replace** the doc comment on `ConnectionField.isRequired` (it currently says the flag is marked on the identifying field "and nowhere else", and that a key path may be blank) with:

```swift
    /// The form cannot be saved, and a connection cannot be opened, while this
    /// field is visible and blank (M22/T9, widened in M23).
    ///
    /// Data because the login-set editor used to answer it with a `switch`
    /// over `ConnectionKind` — and that switch is exactly where `.webdav`
    /// returned "always disabled", making a WebDAV login set unsaveable.
    ///
    /// M23 marked SSH's `keyPath` required too. The M22 rationale for leaving
    /// it optional — "an agent or managed-key login supplies it another way" —
    /// does not survive `visibleWhen`: the field is shown only under
    /// private-key auth, so an agent login never reaches the check, and the
    /// managed-key picker writes `keyPath` before the form is saved. A
    /// private-key login with no key path was already refused at connect time;
    /// now it is refused at save time too.
    ///
    /// A SECRET may still be blank in edit mode ("keep the stored one") — that
    /// asymmetry is `firstViolation(in:namespace:requireSecrets:)`'s parameter,
    /// not a property of the field.
    public let isRequired: Bool
```

- [ ] **Step 5: Declare the rules on S3 and WebDAV**

In `S3FieldSchema`, every field that `validateS3Fields` checks today gets `isRequired: true, invalidMessageKey: "core.connect.s3FieldRequired"` — that is `endpoint`, `region`, `bucket` in `connection`, and `accessKeyID`, `secretAccessKey` in `credential`. `usePathStyle` is a toggle and stays untouched. Read the file and place them on the existing `ConnectionField` initializers; do not reorder the fields.

In `WebDAVFieldSchema`: `baseURL` gets `isRequired: true, invalidMessageKey: "core.connect.webdavFieldRequired"`. `username` already carries `isRequired: true` from M22 — add `invalidMessageKey: "core.connect.webdavFieldRequired"` to it. `password` gets `isRequired: true, invalidMessageKey: "core.connect.webdavFieldRequired"` (today `connectWebDAV` relies on `makeConfig` throwing; declaring it makes the rejection explicit and gives it the same message). `useNextcloudPath` is a toggle and stays untouched.

- [ ] **Step 6: Add the fallback key to all four Core catalogs**

Add to `Sources/macSCPCore/Resources/en.lproj/Localizable.strings`:

```
"core.connect.fieldRequired" = "This field is required.";
```

`de`: `"core.connect.fieldRequired" = "Dieses Feld ist erforderlich.";`
`fr`: `"core.connect.fieldRequired" = "Ce champ est obligatoire.";`
`pl`: `"core.connect.fieldRequired" = "To pole jest wymagane.";`

- [ ] **Step 7: Run the tests**

Run: `swift test 2>&1 | tail -10`
Expected: PASS, including `everyValidatableFieldDeclaresItsMessage`, `onlyTheSSHPortIsNumeric` and the catalog key-set guard.

- [ ] **Step 8: Commit**

```bash
git add Sources/macSCPCore Tests/macSCPCoreTests/SchemaConformanceTests.swift
git commit -m "feat(core): declare field format and failure message in the schema

Adds ConnectionField.format (one case, .numeric) and .invalidMessageKey,
and declares both on all three backends' fields. Nothing consumes them yet
— the validator lands in the next task.

SSHField.keyPath becomes isRequired: connect already refused a private-key
login with a blank path, and the field is only visible under private-key
auth, so an agent login never reaches the check.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: One validator in Core

**Files:**
- Modify: `Sources/macSCPCore/Capabilities/ConnectionFieldSchema.swift`
- Modify: `Sources/macSCPCore/Capabilities/BackendDescriptor.swift`
- Test: `Tests/macSCPCoreTests/FieldValidationTests.swift` (new file)

**Interfaces:**
- Consumes: `ConnectionField.format`/`.invalidMessageKey`/`.isRequired` (Task 2); `visibleFields(in:namespace:)` (M22).
- Produces:
  - `ConnectionFieldSchema.firstViolation(in: FieldValues, namespace: String, requireSecrets: Bool) -> (messageKey: String, fieldKey: String)?`
  - `BackendDescriptor.firstViolation(in: FieldValues, requireSecrets: Bool) -> (messageKey: String, fieldKey: String)?`
  - `fieldKey` is the **namespaced** key (`"SSHField.host"`), the same string `FieldValues.raw` and `SchemaFormView.failedFieldID` use.

- [ ] **Step 1: Write the failing tests**

`Tests/macSCPCoreTests/FieldValidationTests.swift`:

```swift
import Foundation
import Testing
@testable import macSCPCore

@Suite struct FieldValidationTests {
    private let ssh = BackendDescriptor.descriptor(for: .ssh)

    private func sshValues(
        host: String = "example.com", port: String = "22",
        username: String = "tim", authKind: StoredSession.AuthKind = .password,
        password: String = "hunter2", keyPath: String = ""
    ) -> FieldValues {
        var values = FieldValues()
        values[SSHField.host] = host
        values[SSHField.port] = port
        values[SSHField.username] = username
        values[SSHField.authKind] = authKind.rawValue
        values[SSHField.password] = password
        values[SSHField.keyPath] = keyPath
        return values
    }

    @Test func aCompleteFormHasNoViolation() {
        #expect(ssh.firstViolation(in: sshValues(), requireSecrets: true) == nil)
    }

    @Test func aBlankRequiredFieldReportsItsOwnMessageAndKey() {
        let violation = ssh.firstViolation(in: sshValues(host: ""), requireSecrets: true)
        #expect(violation?.messageKey == "core.connect.emptyHost")
        #expect(violation?.fieldKey == "SSHField.host")
    }

    /// Whitespace is not a value. A row of spaces in the host field used to
    /// reach `SSHConnectionConfig.init` and fail there with a different text.
    @Test func whitespaceDoesNotCountAsFilled() {
        let violation = ssh.firstViolation(in: sshValues(host: "   "), requireSecrets: true)
        #expect(violation?.fieldKey == "SSHField.host")
    }

    @Test func aNonNumericPortReportsThePortMessage() {
        let violation = ssh.firstViolation(in: sshValues(port: "http"), requireSecrets: true)
        #expect(violation?.messageKey == "core.connect.portNumeric")
        #expect(violation?.fieldKey == "SSHField.port")
    }

    /// A SECRET is checked verbatim, never trimmed: " " is a legal password
    /// and rejecting it would lock a user out of their own server.
    @Test func aSecretMadeOfSpacesIsAccepted() {
        #expect(ssh.firstViolation(in: sshValues(password: " "), requireSecrets: true) == nil)
    }

    @Test func anEmptySecretIsRejectedOnlyWhenSecretsAreRequired() {
        let values = sshValues(password: "")
        #expect(ssh.firstViolation(in: values, requireSecrets: true)?.fieldKey
                == "SSHField.password")
        #expect(ssh.firstViolation(in: values, requireSecrets: false) == nil)
    }

    /// The whole point of walking `visibleFields`: the auth-kind branching
    /// `connectSSH` did by hand falls out of the visibility conditions.
    @Test func anInvisibleFieldIsNotValidated() {
        // Agent auth shows neither secret nor key path.
        let agent = sshValues(authKind: .agent, password: "", keyPath: "")
        #expect(ssh.firstViolation(in: agent, requireSecrets: true) == nil)
        // Private-key auth shows the key path, and it is blank.
        let key = sshValues(authKind: .privateKey, password: "", keyPath: "")
        #expect(ssh.firstViolation(in: key, requireSecrets: true)?.fieldKey
                == "SSHField.keyPath")
    }

    @Test func s3ReportsItsOwnFieldsAndMessage() {
        var values = BackendDescriptor.descriptor(for: .s3).defaultValues
        values[S3Field.endpoint] = "https://s3.example.com"
        values[S3Field.region] = "eu-central-1"
        values[S3Field.bucket] = ""
        values[S3Field.accessKeyID] = "AKIA"
        values[S3Field.secretAccessKey] = "secret"
        let violation = BackendDescriptor.descriptor(for: .s3)
            .firstViolation(in: values, requireSecrets: true)
        #expect(violation?.messageKey == "core.connect.s3FieldRequired")
        #expect(violation?.fieldKey == "S3Field.bucket")
    }

    @Test func webdavReportsItsOwnFieldsAndMessage() {
        var values = BackendDescriptor.descriptor(for: .webdav).defaultValues
        values[WebDAVField.baseURL] = ""
        values[WebDAVField.username] = "tim"
        values[WebDAVField.password] = "pw"
        let violation = BackendDescriptor.descriptor(for: .webdav)
            .firstViolation(in: values, requireSecrets: true)
        #expect(violation?.messageKey == "core.connect.webdavFieldRequired")
        #expect(violation?.fieldKey == "WebDAVField.baseURL")
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter FieldValidation 2>&1 | tail -20`
Expected: FAIL — `value of type 'BackendDescriptor' has no member 'firstViolation'`.

- [ ] **Step 3: Implement the schema-level validator**

Append to the `extension ConnectionFieldSchema` in `Sources/macSCPCore/Capabilities/ConnectionFieldSchema.swift`:

```swift
    /// The first rule these values break, or nil when they break none (M23).
    ///
    /// Walks `visibleFields` and nothing else, which is what makes the
    /// auth-kind branching `connectSSH` used to do by hand disappear: SSH's
    /// password is required AND only visible under password auth, so an agent
    /// login is never asked for one. A field that is not on screen has no say.
    ///
    /// `requireSecrets` is the connect-versus-save asymmetry, made explicit
    /// rather than inherited: opening a connection needs an actual secret in
    /// hand, while an edit-mode save deliberately leaves the secret blank to
    /// mean "keep the stored one". No default — a caller must decide which it
    /// is.
    ///
    /// Secrets are compared VERBATIM while everything else is trimmed. A
    /// password of spaces is a legal password, and trimming it would refuse a
    /// user their own server; a host of spaces is a typo.
    public func firstViolation(
        in values: FieldValues, namespace: String, requireSecrets: Bool
    ) -> (messageKey: String, fieldKey: String)? {
        for field in visibleFields(in: values, namespace: namespace) {
            if field.isSecret && !requireSecrets { continue }
            let key = "\(namespace).\(field.id)"
            let raw = values.raw[key] ?? ""
            let value = field.isSecret
                ? raw : raw.trimmingCharacters(in: .whitespacesAndNewlines)

            let isBlank = field.isRequired && value.isEmpty
            let isUnparsable = field.format == .numeric && Int(value) == nil
            guard isBlank || isUnparsable else { continue }
            // The `??` is unreachable while
            // `everyValidatableFieldDeclaresItsMessage` passes; it is here so
            // a slip degrades to a generic message rather than to silence.
            return (field.invalidMessageKey ?? "core.connect.fieldRequired", key)
        }
        return nil
    }
```

- [ ] **Step 4: Implement the descriptor-level validator**

Add to `BackendDescriptor` in `Sources/macSCPCore/Capabilities/BackendDescriptor.swift`, next to `sessionValues(_:)`:

```swift
    /// The first rule these values break across BOTH of this backend's
    /// schemas (M23) — connection fields first, then credentials, which is the
    /// order the form renders them in, so the reported field is the topmost
    /// offending row rather than an arbitrary one.
    public func firstViolation(
        in values: FieldValues, requireSecrets: Bool
    ) -> (messageKey: String, fieldKey: String)? {
        connectionSchema.firstViolation(
            in: values, namespace: fieldNamespace, requireSecrets: requireSecrets)
            ?? credentialSchema.firstViolation(
                in: values, namespace: fieldNamespace, requireSecrets: requireSecrets)
    }
```

- [ ] **Step 5: Run the tests**

Run: `swift test --filter FieldValidation 2>&1 | tail -10`
Expected: PASS, 9 tests.

Then the whole suite: `swift test 2>&1 | tail -5` — expected PASS, nothing else consumes the validator yet.

- [ ] **Step 6: Commit**

```bash
git add Sources/macSCPCore Tests/macSCPCoreTests/FieldValidationTests.swift
git commit -m "feat(core): add the declarative field validator

firstViolation walks visibleFields and returns the first broken rule as a
(messageKey, namespaced fieldKey) pair. Secrets are compared verbatim, not
trimmed — a password of spaces is a legal password. requireSecrets carries
the connect-versus-edit-save asymmetry and has no default.

No caller yet.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: The write adapter on the descriptor

**Files:**
- Modify: `Sources/macSCPCore/S3/S3FieldSchema.swift`, `Sources/macSCPCore/WebDAV/WebDAVFieldSchema.swift`
- Modify: `Sources/macSCPCore/Capabilities/BackendDescriptor.swift`
- Test: `Tests/macSCPCoreTests/BackendApplyTests.swift` (new file)

**Interfaces:**
- Consumes: `SSHFieldSchema.apply(_:to:)` (already exists, M22); `S3FieldSchema.stored(from:)`, `WebDAVFieldSchema.stored(from:)` (already exist, M22).
- Produces: `BackendDescriptor.apply: @Sendable (FieldValues, inout StoredSession) -> Void`; `S3FieldSchema.apply(_:to:)`; `WebDAVFieldSchema.apply(_:to:)`.

- [ ] **Step 1: Write the failing tests**

`Tests/macSCPCoreTests/BackendApplyTests.swift`:

```swift
import Foundation
import Testing
@testable import macSCPCore

/// The write counterpart to M22's read-only `sessionValues(_:)`.
///
/// Every test here is the same shape on purpose: populate the parts of a
/// `StoredSession` the adapter has NO business touching, apply, and assert
/// they survived. An adapter that rebuilds instead of mutating passes a
/// round-trip test and silently drops a group assignment, a login-set binding
/// or a jump host.
@Suite struct BackendApplyTests {
    private func jumpSpec() -> StoredSession.JumpSpec {
        StoredSession.JumpSpec(
            host: "bastion.example.com", port: 2022, username: "hop",
            authKind: .privateKey, keyPath: "/keys/hop")
    }

    @Test func sshApplyPreservesEverythingItDoesNotOwn() {
        let group = UUID(), set = UUID(), jump = jumpSpec()
        var session = sshSession(
            name: "prod", groupID: group, loginSetID: set, jump: jump)

        var values = FieldValues()
        values[SSHField.host] = "new.example.com"
        values[SSHField.port] = "2222"
        values[SSHField.username] = "deploy"
        values[SSHField.authKind] = StoredSession.AuthKind.password.rawValue
        BackendDescriptor.descriptor(for: .ssh).apply(values, &session)

        #expect(session.host == "new.example.com")
        #expect(session.port == 2222)
        #expect(session.username == "deploy")
        #expect(session.groupID == group)
        #expect(session.loginSetID == set)
        #expect(session.jump == jump)
        #expect(session.name == "prod")
    }

    @Test func s3ApplyPreservesEverythingItDoesNotOwn() {
        let group = UUID(), set = UUID()
        var session = s3Session(name: "bucket", groupID: group, loginSetID: set)

        var values = FieldValues()
        values[S3Field.endpoint] = "https://minio.example.com"
        values[S3Field.region] = "us-east-1"
        values[S3Field.bucket] = "archive"
        values[S3Field.accessKeyID] = "AKIANEW"
        values[bool: S3Field.usePathStyle] = true
        BackendDescriptor.descriptor(for: .s3).apply(values, &session)

        #expect(session.s3?.bucket == "archive")
        #expect(session.s3?.region == "us-east-1")
        #expect(session.s3?.usePathStyle == true)
        #expect(session.groupID == group)
        #expect(session.loginSetID == set)
        #expect(session.name == "bucket")
    }

    @Test func webdavApplyPreservesEverythingItDoesNotOwn() {
        let group = UUID(), set = UUID()
        var session = webdavSession(name: "cloud", groupID: group, loginSetID: set)

        var values = FieldValues()
        values[WebDAVField.baseURL] = "https://nas.example.com/dav"
        values[WebDAVField.username] = "tim"
        values[bool: WebDAVField.useNextcloudPath] = true
        BackendDescriptor.descriptor(for: .webdav).apply(values, &session)

        #expect(session.webdav?.baseURL == "https://nas.example.com/dav")
        #expect(session.webdav?.useNextcloudPath == true)
        #expect(session.groupID == group)
        #expect(session.loginSetID == set)
        #expect(session.name == "cloud")
    }

    /// `sessionValues` and `apply` are inverses. Proving it for all three
    /// backends at once is what keeps a field added to one side and forgotten
    /// on the other from shipping.
    @Test(arguments: ConnectionKind.allCases)
    func applyIsTheInverseOfSessionValues(kind: ConnectionKind) {
        let descriptor = BackendDescriptor.descriptor(for: kind)
        let original: StoredSession
        switch kind {
        case .ssh: original = sshSession(
            name: "s", host: "h.example.com", port: 2222, username: "u",
            authKind: .privateKey, keyPath: "/k")
        case .s3: original = s3Session(name: "s")
        case .webdav: original = webdavSession(name: "s")
        }

        var rebuilt = original
        descriptor.apply(descriptor.sessionValues(original), &rebuilt)
        #expect(rebuilt == original)
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter BackendApply 2>&1 | tail -20`
Expected: FAIL — `value of type 'BackendDescriptor' has no member 'apply'`.

- [ ] **Step 3: Add `apply` to S3 and WebDAV**

In `Sources/macSCPCore/S3/S3FieldSchema.swift`, after `stored(from:)`:

```swift
    /// Writes ONLY the fields `S3Field` covers, mirroring
    /// `SSHFieldSchema.apply(_:to:)`. `StoredSession` carries group, login-set
    /// binding and the other backends' blocks; rebuilding it from these values
    /// would silently drop them.
    public static func apply(_ values: FieldValues, to session: inout StoredSession) {
        session.s3 = stored(from: values)
    }
```

In `Sources/macSCPCore/WebDAV/WebDAVFieldSchema.swift`, after `stored(from:)`:

```swift
    /// Writes ONLY the fields `WebDAVField` covers — same contract as
    /// `SSHFieldSchema.apply(_:to:)` and `S3FieldSchema.apply(_:to:)`.
    public static func apply(_ values: FieldValues, to session: inout StoredSession) {
        session.webdav = stored(from: values)
    }
```

- [ ] **Step 4: Hoist it onto the descriptor**

In `Sources/macSCPCore/Capabilities/BackendDescriptor.swift`, add the stored member after `displaySummary`:

```swift
    /// Writes collected form values back into a stored session — the write
    /// counterpart to the read-only `sessionValues(_:)` (M23).
    ///
    /// MUTATES IN PLACE, never reconstructs. `StoredSession` carries group
    /// assignment, login-set binding and per-protocol blocks that a rebuilding
    /// adapter would silently drop; `BackendApplyTests` pins that for all
    /// three backends by populating exactly those fields before applying.
    ///
    /// A stored member rather than a computed `switch` (unlike
    /// `sessionValues`) so a test can build a synthetic descriptor with its
    /// own adapter — the same reason `makeConfig` and `connect` are closures.
    public let apply: @Sendable (FieldValues, inout StoredSession) -> Void
```

and wire it in the three literals:

```swift
        // sshDescriptor, after displaySummary:
        apply: { values, session in SSHFieldSchema.apply(values, to: &session) },
        // s3Descriptor:
        apply: { values, session in S3FieldSchema.apply(values, to: &session) },
        // webdavDescriptor:
        apply: { values, session in WebDAVFieldSchema.apply(values, to: &session) },
```

Any synthetic `BackendDescriptor(...)` a test builds must gain the parameter too — `swift build --build-tests` will name them.

- [ ] **Step 5: Run the tests**

Run: `swift test --filter BackendApply 2>&1 | tail -10`
Expected: PASS, 6 tests (three preservation + three parameterized round trips).

Then: `swift test 2>&1 | tail -5` — expected PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/macSCPCore Tests/macSCPCoreTests/BackendApplyTests.swift
git commit -m "feat(core): add the descriptor write adapter

apply(FieldValues, inout StoredSession) is the write counterpart to M22's
read-only sessionValues. It mutates in place rather than reconstructing —
a rebuilding adapter passes a round-trip test while silently dropping the
group, the login-set binding and the jump host, so every test here
populates exactly those before applying.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: One connect body (RISK — touches the TOFU path)

**Files:**
- Modify: `Sources/macSCPCore/Presentation/ConnectionViewModel.swift:432-607` (`connect`, `connectSSH`, `connectS3`, `connectWebDAV`, `validateS3Fields`), and the `Field` enum
- Modify: `Sources/MacSCPApp/ConnectionFormView.swift:116-140` (`failedFieldID`)
- Test: `Tests/macSCPCoreTests/ConnectionViewModelTests.swift` (adjust the 6 `field: .host`-style assertions)

**Interfaces:**
- Consumes: `BackendDescriptor.firstViolation(in:requireSecrets:)` (Task 3).
- Produces: `ConnectionViewModel.Field.schema(String)`; `Field` loses `.host`, `.port`, `.username`, `.password`, `.keyPath`.

**Before writing any code, read this:** the SSH connect path is security-critical. `connectSSH` builds the config, attaches the jump via `buildJumpConfig()`, and hands the host-key decider to `connector`. The collapsed body must keep **all three** properties: the jump is attached *after* the factory (the factory takes one secret and cannot resolve a second — pinned by `SSHFieldSchema.makeConfigLeavesTheJumpToTheCaller`), the decider is passed for every backend but consulted only by SSH, and `Self.failedState(for:jumpEnabled:jumpKeyPath:jumpAuthChoice:)` is what maps a thrown error to a localized message. Compare the new body against the old line by line before running anything.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/macSCPCoreTests/ConnectionViewModelTests.swift`:

```swift
/// The whole point of the collapse: one body, and S3/WebDAV now report WHICH
/// field failed instead of a bare `field: nil`.
@Test @MainActor func connectReportsTheOffendingS3Field() async {
    let vm = ConnectionViewModel(connector: { _, _ in MockRemoteFileSystem() })
    vm.kind = .s3
    vm.s3Endpoint = "https://s3.example.com"
    vm.s3Region = "eu-central-1"
    vm.s3Bucket = ""
    vm.s3AccessKeyID = "AKIA"
    vm.s3SecretAccessKey = "secret"
    #expect(await vm.connect() == nil)
    #expect(vm.state == .failed(
        message: CoreL10n.string("core.connect.s3FieldRequired"),
        field: .schema("S3Field.bucket")))
}

@Test @MainActor func connectReportsTheOffendingWebDAVField() async {
    let vm = ConnectionViewModel(connector: { _, _ in MockRemoteFileSystem() })
    vm.kind = .webdav
    vm.webdavBaseURL = ""
    vm.username = "tim"
    vm.password = "pw"
    #expect(await vm.connect() == nil)
    #expect(vm.state == .failed(
        message: CoreL10n.string("core.connect.webdavFieldRequired"),
        field: .schema("WebDAVField.baseURL")))
}

/// Under private-key auth the passphrase row is the one on screen, so a
/// key-path failure must outline the key path — the case the App used to
/// special-case by reading `authChoice` inside `failedFieldID`.
@Test @MainActor func connectOutlinesTheVisibleSecretRow() async {
    let vm = ConnectionViewModel(connector: { _, _ in MockRemoteFileSystem() })
    vm.host = "example.com"
    vm.username = "tim"
    vm.authChoice = .privateKey
    vm.keyPath = ""
    #expect(await vm.connect() == nil)
    #expect(vm.state == .failed(
        message: CoreL10n.string("core.connect.keyPathEmpty"),
        field: .schema("SSHField.keyPath")))
}
```

Then update the 6 existing assertions in this file that use `field: .host` / `.port` / `.username` / `.password` / `.keyPath` to the `.schema("SSHField.<id>")` form. Find them with:

```bash
grep -n 'field: \.\(host\|port\|username\|password\|keyPath\)' Tests/macSCPCoreTests/ConnectionViewModelTests.swift
```

Leave `field: .saveName` and every `field: .jump*` assertion exactly as they are — those are form rules, not schema fields, and they keep their cases.

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter ConnectionViewModel 2>&1 | tail -20`
Expected: FAIL — `type 'ConnectionViewModel.Field' has no member 'schema'`.

- [ ] **Step 3: Reshape the `Field` enum**

In `Sources/macSCPCore/Presentation/ConnectionViewModel.swift`, replace the `Field` enum with:

```swift
    /// Which form row to outline for a failure.
    ///
    /// Backend fields are addressed by their NAMESPACED `FieldValues` key
    /// (M23) rather than by a case each: the set of fields is data now, and an
    /// enum case per field would be exactly the per-protocol code this
    /// milestone removes — which is also why S3 and WebDAV rows never
    /// highlighted before, the App's key mapping hardcoded SSH's namespace.
    ///
    /// The remaining cases are FORM rules, not backend fields: the save name
    /// is form bookkeeping, and the jump block is a second login with no
    /// schema of its own.
    public enum Field: Equatable, Sendable {
        /// A backend field, e.g. `.schema("SSHField.host")`.
        case schema(String)
        case saveName
        /// Jump-host fields (M10c/T3) — highlighted while the jump block is
        /// enabled and one of its own values fails validation.
        case jumpHost
        case jumpPort
        case jumpUsername
        case jumpPassword
        case jumpKeyPath
        /// The jump-source session picker (M11a/T3) — highlighted when the
        /// jump is enabled, in "session" mode, and nothing is selected yet.
        case jumpSession
    }
```

- [ ] **Step 4: Collapse the three connect bodies into one**

Replace `connect()`, `connectSSH()`, `connectS3()`, `connectWebDAV()` and `validateS3Fields(requireSecret:)` with:

```swift
    /// Returns the connected file system or nil; errors land in `state`.
    /// Re-entrancy safe: calls made while `.connecting` are dropped, so a
    /// double-click doesn't open a second (orphaned) connection.
    ///
    /// One body for every protocol since M23. What used to be three
    /// hand-written validators is `descriptor.firstViolation`, which walks the
    /// VISIBLE fields — so SSH's "a password is required, but only under
    /// password auth, and never under agent auth" is the schema's
    /// `visibleWhen` rather than a `switch` here.
    ///
    /// Two things stay hand-written, because they are form rules rather than
    /// backend fields: the save name, and the jump block.
    public func connect() async -> (any RemoteFileSystem)? {
        guard state != .connecting else { return nil }
        defer { hostKeyPrompt = nil }

        if shouldSaveSession,
           saveName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            state = .failed(
                message: CoreL10n.string("core.connect.saveNameEmpty"), field: .saveName)
            return nil
        }
        let descriptor = BackendDescriptor.descriptor(for: kind)
        if let violation = descriptor.firstViolation(in: values, requireSecrets: true) {
            state = .failed(
                message: CoreL10n.string(violation.messageKey),
                field: .schema(violation.fieldKey))
            return nil
        }
        // Unconditional, not `if kind == .ssh`: `validateJump` returns nil
        // whenever the toggle is off, and the toggle is cleared by
        // `exitEditMode` whenever `kind` changes. A guard here would be a
        // protocol branch that decides nothing.
        if let jumpFailure = validateJump(requireSecret: true) {
            state = jumpFailure
            return nil
        }

        let config: ConnectionConfig
        do {
            config = try descriptor.makeConfig(values, resolvedSecret)
        } catch {
            state = Self.failedState(for: error)
            return nil
        }
        state = .connecting
        do {
            let fs = try await connector(attachingJump(to: config)) { [weak self] candidate in
                await self?.presentHostKeyPrompt(for: candidate) ?? false
            }
            state = .idle
            if case .ssh(let ssh) = config { lastConnectedConfig = ssh }
            return fs
        } catch {
            state = Self.failedState(
                for: error, jumpEnabled: jumpEnabled,
                jumpKeyPath: jumpKeyPath.trimmingCharacters(in: .whitespacesAndNewlines),
                jumpAuthChoice: jumpAuthChoice)
            return nil
        }
    }

    /// The secret the active backend's visible secret field currently holds.
    ///
    /// A QUERY, not a stored property: SSH means the passphrase under
    /// private-key auth, the password under password auth, and NOTHING under
    /// agent auth — where reading a Keychain slot that was never written is
    /// exactly the M10d bug. `visibleSecretField` answers all three.
    private var resolvedSecret: String {
        let descriptor = BackendDescriptor.descriptor(for: kind)
        let namespace = descriptor.fieldNamespace
        let field = descriptor.connectionSchema
            .visibleSecretField(in: values, namespace: namespace)
            ?? descriptor.credentialSchema
                .visibleSecretField(in: values, namespace: namespace)
        guard let field else { return "" }
        return values.raw["\(namespace).\(field.id)"] ?? ""
    }

    /// Attaches the jump hop to a freshly built config.
    ///
    /// Separate from `makeConfig` on purpose and pinned by
    /// `SSHFieldSchema.makeConfigLeavesTheJumpToTheCaller`: a jump host has a
    /// SECOND secret in its own Keychain slot, and a factory taking one secret
    /// structurally cannot resolve it. Doing this here is what keeps a
    /// bastion-only session from quietly dialling its target directly.
    ///
    /// Non-SSH configs pass through untouched — no other protocol has a hop.
    private func attachingJump(to config: ConnectionConfig) -> ConnectionConfig {
        guard case .ssh(let ssh) = config, let jump = buildJumpConfig() else { return config }
        // Re-running the initializer cannot throw here: every component came
        // out of an `SSHConnectionConfig` that already validated, and the jump
        // is validated by `validateJump` above.
        guard let withJump = try? SSHConnectionConfig(
            host: ssh.host, port: ssh.port, username: ssh.username,
            auth: ssh.auth, jump: jump) else { return config }
        return .ssh(withJump)
    }
```

**Two details the compiler will not catch:**

- `lastConnectedConfig` is assigned only in the `.ssh` case, as before. Nothing else ever set it.
- `Self.failedState(for:)` without the jump arguments is used for the *build* failure (a config the factory rejected, which cannot be a jump problem) and the four-argument form for the *connect* failure. That mirrors what the three old bodies did.

- [ ] **Step 5: Make the App's `failedFieldID` a pass-through**

In `Sources/MacSCPApp/ConnectionFormView.swift`, replace the body of `failedFieldID` (lines ~129-140) with:

```swift
    /// The namespaced key `SchemaFormView` matches its rows against.
    ///
    /// A pass-through since M23: the view model reports the failing field by
    /// its own key, so this no longer translates an enum case into an
    /// SSH-namespaced string — which is why S3 and WebDAV rows highlight now
    /// and did not before. The passphrase-versus-password special case is gone
    /// too: the validator walks the VISIBLE fields, so it names whichever
    /// secret row is actually on screen.
    private var failedFieldID: String? {
        guard case .schema(let key) = failedField else { return nil }
        return key
    }
```

The eight `.errorHighlight(failedField == .saveName)` / `== .jump*` call sites in this file are unchanged.

- [ ] **Step 6: Build and run the tests**

Run: `swift build 2>&1 | tail -20`
Expected: clean. If the App target names a deleted `Field` case, that call site was relying on SSH-only highlighting — replace it with the `.schema(...)` key, do not re-add the case.

Run: `swift test 2>&1 | tail -10`
Expected: PASS.

- [ ] **Step 7: Verify against the live SSH rig**

```bash
docker compose -f docker/test-server/compose.yml up -d
MACSCP_ITEST=1 swift test --filter Integration 2>&1 | tail -20
```

Expected: PASS. **This is the task's real gate** — it is the only thing that proves the collapsed connect path still opens a real SSH connection, still tunnels through a jump host, and still refuses a mismatched host key.

- [ ] **Step 8: Commit**

```bash
git add Sources Tests
git commit -m "refactor(core): one connect body for every protocol

connectSSH/connectS3/connectWebDAV and validateS3Fields collapse into
connect(), which asks the descriptor for the first broken rule instead of
hand-checking fields. SSH's auth-kind branching falls out of the schema's
visibleWhen conditions.

Field gains .schema(String) and loses its five SSH cases, so the App's
failedFieldID becomes a pass-through — and S3 and WebDAV form rows
highlight on error for the first time.

The jump is still attached after the factory, the host-key decider is
still passed to every backend and consulted only by SSH, and a mismatch
is still a hard stop.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: One edit-save body, and the end of `"unused"`

**Files:**
- Modify: `Sources/macSCPCore/Presentation/ConnectionViewModel.swift:932-1075` (`validateForEditSave` and its three private bodies), plus `beginEditing`/`exitEditMode` for the remembered original
- Test: `Tests/macSCPCoreTests/ConnectionViewModelTests.swift`

**Interfaces:**
- Consumes: `BackendDescriptor.firstViolation(in:requireSecrets:)` (Task 3), `BackendDescriptor.apply` (Task 4).
- Produces: `ConnectionViewModel.validateForEditSave() -> StoredSession?` — same signature, one body.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/macSCPCoreTests/ConnectionViewModelTests.swift`:

```swift
/// The defect this milestone dissolves at its root: every non-SSH session
/// stored the literal placeholder "unused" in host and username, which made
/// them all share the import duplicate key `unused|22|unused`.
@Test @MainActor func editSaveWritesNoPlaceholders() {
    let vm = ConnectionViewModel(connector: { _, _ in MockRemoteFileSystem() })
    vm.beginEditing(s3Session(name: "bucket"))
    vm.saveName = "bucket"
    vm.s3Endpoint = "https://s3.example.com"
    vm.s3Region = "eu-central-1"
    vm.s3Bucket = "archive"
    vm.s3AccessKeyID = "AKIA"
    let saved = vm.validateForEditSave()
    #expect(saved?.host != "unused")
    #expect(saved?.username != "unused")
    #expect(saved?.s3?.bucket == "archive")
}

/// An edit-save must carry forward everything the form does not show. The
/// three old bodies rebuilt the session from scratch, which is how a
/// set-backed S3 session silently lost its binding from M15 until M22.
@Test @MainActor func editSavePreservesWhatTheFormNeverShows() {
    let group = UUID(), set = UUID()
    let original = s3Session(name: "bucket", groupID: group, loginSetID: set)
    let vm = ConnectionViewModel(connector: { _, _ in MockRemoteFileSystem() })
    vm.beginEditing(original)
    vm.saveName = "bucket renamed"
    vm.s3Bucket = "archive"
    let saved = vm.validateForEditSave()
    #expect(saved?.id == original.id)
    #expect(saved?.name == "bucket renamed")
    #expect(saved?.groupID == group)
    #expect(saved?.loginSetID == set)
}

/// Edit mode leaves the secret blank to mean "keep the stored one". A
/// requireSecrets: true here would make every password session unsaveable
/// without retyping its password.
@Test @MainActor func editSaveAcceptsABlankSecret() {
    let vm = ConnectionViewModel(connector: { _, _ in MockRemoteFileSystem() })
    vm.beginEditing(sshSession(name: "prod", host: "example.com", username: "tim"))
    vm.saveName = "prod"
    vm.password = ""
    #expect(vm.validateForEditSave() != nil)
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter editSave 2>&1 | tail -20`
Expected: FAIL — `editSaveWritesNoPlaceholders` fails because `host == "unused"`.

- [ ] **Step 3: Remember the session being edited**

In `ConnectionViewModel`, add next to `existingJumpSecretID`:

```swift
    /// The session `beginEditing` was handed, kept so `validateForEditSave`
    /// can MUTATE it rather than rebuild it (M23).
    ///
    /// Rebuilding is what the three old bodies did, and it is why a
    /// set-backed S3 session lost its login-set binding on every unrelated
    /// edit between M15 and M22: a field the form does not render is a field a
    /// rebuild drops. Cleared by `exitEditMode`, so a stale original cannot
    /// outlive its edit.
    private var editingOriginal: StoredSession?
```

Set it at the top of `beginEditing(_:)`:

```swift
    public func beginEditing(_ stored: StoredSession) {
        editingOriginal = stored
        kind = stored.kind
```

and clear it in `exitEditMode()`, next to `mode = .new`:

```swift
        editingOriginal = nil
```

- [ ] **Step 4: Collapse the three edit-save bodies into one**

Replace `validateForEditSave()`, `validateForEditSaveSSH(sessionID:)`, `validateForEditSaveS3(sessionID:)` and `validateForEditSaveWebDAV(sessionID:)` with:

```swift
    /// Validates the form for saving an edited session and returns the updated
    /// `StoredSession`, or nil after publishing a `.failed` state.
    ///
    /// One body for every protocol since M23, and the place the `"unused"`
    /// placeholders died: the session is MUTATED through
    /// `descriptor.apply` rather than rebuilt, so a backend with no host and
    /// no user name simply leaves those fields alone instead of parking a
    /// literal there.
    ///
    /// The secret is deliberately NOT required here (`requireSecrets: false`),
    /// unlike `connect()`: edit mode leaves it blank to mean "keep the stored
    /// one", and requiring it would make every saved password session
    /// impossible to edit without retyping its password.
    public func validateForEditSave() -> StoredSession? {
        guard case .edit(let sessionID) = mode else { return nil }

        let trimmedName = saveName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            state = .failed(
                message: CoreL10n.string("core.connect.saveNameEmpty"), field: .saveName)
            return nil
        }
        let descriptor = BackendDescriptor.descriptor(for: kind)
        if let violation = descriptor.firstViolation(in: values, requireSecrets: false) {
            state = .failed(
                message: CoreL10n.string(violation.messageKey),
                field: .schema(violation.fieldKey))
            return nil
        }
        // requireSecret: false for the same reason as above — see
        // `validateJump`'s own doc comment.
        if let jumpFailure = validateJump(requireSecret: false) {
            state = jumpFailure
            return nil
        }

        // Mutating the ORIGINAL is what carries group, login-set binding and
        // the other backends' blocks forward. The fallback covers a caller
        // that set `.edit` without going through `beginEditing`; it rebuilds
        // only what it can, which is why nothing should rely on it.
        var session = editingOriginal ?? StoredSession(
            id: sessionID, name: trimmedName, host: "", username: "", kind: kind)
        session.name = trimmedName
        session.kind = kind
        session.groupID = selectedGroupID
        session.loginSetID = loginMode == .set ? selectedLoginSetID : nil
        session.jump = buildJumpSpec(existingSecretID: existingJumpSecretID)
        descriptor.apply(values, &session)

        state = .idle
        return session
    }
```

- [ ] **Step 5: Run the tests**

Run: `swift test 2>&1 | tail -15`
Expected: PASS. Two existing tests will need their expectations updated rather than their meaning:

- `validateForEditSaveWithS3KindBuildsStoredSessionWithSecretFreeConfig` and its WebDAV twin assert `saved?.host == "unused"`. Change those two lines to assert the placeholder is *absent* — the test's subject (a secret-free config) is unchanged.
- Any test that reaches `validateForEditSave()` without `beginEditing` must call `beginEditing` first. That is not a workaround: an edit-save with no session to edit was always meaningless, and the fallback exists only so it degrades rather than traps.

- [ ] **Step 6: Prove the placeholder is gone from the whole tree**

```bash
grep -rn --include='*.swift' '"unused"' Sources
```

Expected: **no matches in `Sources`.** Test fixtures may still use `"unused"` as a *username* where the test is about a login set supplying the real one — that is a value a test names, not a placeholder the app writes.

- [ ] **Step 7: Commit**

```bash
git add Sources/macSCPCore Tests/macSCPCoreTests/ConnectionViewModelTests.swift
git commit -m "refactor(core): one edit-save body, and no more \"unused\"

validateForEditSaveSSH/S3/WebDAV collapse into validateForEditSave, which
mutates the session beginEditing remembered instead of rebuilding it. A
backend with no host and no user name now leaves those fields alone rather
than parking the literal \"unused\" in them — the placeholder that made
every non-SSH session share one import duplicate key.

Mutating rather than rebuilding is also what carries the group and the
login-set binding forward; rebuilding is how a set-backed S3 session lost
its binding on every unrelated edit between M15 and M22.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: One prefill path, in Core and in the App

**Files:**
- Modify: `Sources/macSCPCore/Presentation/ConnectionViewModel.swift:753-839` (`beginEditing`)
- Modify: `Sources/macSCPCore/Presentation/SessionListViewModel.swift` (`save(...)`, and the S3/WebDAV branches at ~736 and ~761)
- Modify: `Sources/MacSCPApp/ContentView.swift:2382-2440` (the three save branches) and `:2544-2700` (the prefill branches)
- Test: `Tests/macSCPCoreTests/ConnectionViewModelTests.swift`, `Tests/macSCPCoreTests/SessionListViewModelTests.swift`

**Interfaces:**
- Consumes: `BackendDescriptor.sessionValues(_:)` (M22), `BackendDescriptor.apply` (Task 4), `BackendDescriptor.defaultValues` (M22).
- Produces: `SessionListViewModel.save(name:values:password:kind:groupID:loginSetID:jump:jumpSecret:) -> StoredSession?` — replaces the flat-field signature.

- [ ] **Step 1: Write the failing test**

Add to `Tests/macSCPCoreTests/ConnectionViewModelTests.swift`:

```swift
/// `beginEditing` must not leave one protocol's fields visible in another's
/// form — the sticky-toggle lesson the S3 and WebDAV `else` branches spelled
/// out by hand. Resetting to the descriptor's defaults says it once.
@Test @MainActor func beginEditingLeavesNoFieldsFromThePreviousSession() {
    let vm = ConnectionViewModel(connector: { _, _ in MockRemoteFileSystem() })
    vm.beginEditing(s3Session(
        name: "bucket",
        config: StoredS3Config(
            accessKeyID: "AKIA", region: "eu-central-1",
            endpoint: "https://s3.example.com", bucket: "archive",
            usePathStyle: true)))
    #expect(vm.s3Bucket == "archive")

    vm.beginEditing(sshSession(name: "prod", host: "example.com", username: "tim"))
    #expect(vm.kind == .ssh)
    #expect(vm.host == "example.com")
    #expect(vm.s3Bucket == "")
    #expect(vm.s3UsePathStyle == false)
}

/// WebDAV's user name lives on its own block, and the secret is NEVER read
/// from the Keychain during a prefill.
@Test @MainActor func beginEditingFillsWebDAVFromItsOwnBlock() {
    let vm = ConnectionViewModel(connector: { _, _ in MockRemoteFileSystem() })
    vm.beginEditing(webdavSession(
        name: "cloud",
        config: StoredWebDAVConfig(
            baseURL: "https://nas.example.com/dav",
            username: "tim", useNextcloudPath: true)))
    #expect(vm.kind == .webdav)
    #expect(vm.webdavBaseURL == "https://nas.example.com/dav")
    #expect(vm.username == "tim")
    #expect(vm.webdavUseNextcloudPath == true)
    #expect(vm.password == "")
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter beginEditing 2>&1 | tail -20`
Expected: `beginEditingLeavesNoFieldsFromThePreviousSession` fails — the current `else` branches clear the S3 strings but the sequencing leaves `kind` and `values` inconsistent for a fixture built by the helper.

- [ ] **Step 3: Collapse `beginEditing`**

Replace the body from `kind = stored.kind` through the end of the WebDAV `else` branch (leaving the login-set and jump blocks that follow untouched) with:

```swift
    public func beginEditing(_ stored: StoredSession) {
        editingOriginal = stored
        kind = stored.kind
        // One reset plus one fill, for every protocol (M23). Starting from the
        // descriptor's defaults is what the hand-written `else` branches used
        // to do field by field: a previous S3 edit's bucket must not survive
        // into this (possibly SSH) session's form, because `kind` is itself a
        // mode switch.
        let descriptor = BackendDescriptor.descriptor(for: kind)
        values = descriptor.defaultValues
        values.merge(descriptor.sessionValues(stored))
        // The secret is deliberately NEVER loaded from the Keychain: an empty
        // secret at save time means "leave unchanged" (see
        // `validateForEditSave`). `defaultValues` above already left every
        // secret field blank, so this is the assertion, not the action.
        password = ""
        saveName = stored.name
        selectedGroupID = stored.groupID
```

Everything from `loginMode = stored.loginSetID != nil ? .set : .manual` onwards stays exactly as it is.

**Check while doing this:** `sessionValues` returns `FieldValues()` for a session whose `kind` says one thing but whose block is missing. Merging an empty bag onto the defaults leaves a blank form — which is the right answer for inconsistent data, and better than the old `?? ""` fallbacks that silently produced a half-filled one.

- [ ] **Step 4: Reshape `SessionListViewModel.save`**

Replace the signature and the two assignment blocks:

```swift
    /// Creates or updates a session by NAME, then stores its secret.
    ///
    /// Takes the form's `FieldValues` rather than the flat host/port/username
    /// triple (M23): the backend's own adapter writes its own fields, so this
    /// method no longer needs to know that S3 has a bucket and SSH has a port
    /// — nor to park `"unused"` in fields a backend does not have.
    public func save(
        name: String, values: FieldValues, password: String,
        kind: ConnectionKind = .ssh,
        groupID: UUID? = nil, loginSetID: UUID? = nil,
        jump: StoredSession.JumpSpec? = nil, jumpSecret: String? = nil
    ) -> StoredSession? {
        let descriptor = BackendDescriptor.descriptor(for: kind)
        var previousJump: StoredSession.JumpSpec?
        var session: StoredSession
        if let existing = sessions.first(where: { $0.name == name }) {
            previousJump = existing.jump
            session = existing
        } else {
            session = StoredSession(id: UUID(), name: name, host: "", username: "", kind: kind)
        }
        session.name = name
        session.kind = kind
        session.groupID = groupID
        session.loginSetID = loginSetID
        session.jump = jump
        descriptor.apply(values, &session)

        do {
            try store.upsert(session)
            if loginSetID == nil {
                // The auth kind lives in the values now; an agent login stores
                // no secret at all and its leftover manual slot is cleaned up.
                let isAgent = values[SSHField.authKind]
                    == StoredSession.AuthKind.agent.rawValue
                if kind == .ssh && isAgent {
                    try? secrets.deletePassword(for: session.id)
                } else {
                    try secrets.savePassword(password, for: session.id)
                }
            }
```

The rest of the body — the jump-secret block, `cleanOrphanedJumpSlot`, `reload()`, the error path — is unchanged.

**Note the one remaining `kind == .ssh`:** it guards a read of `SSHField.authKind`, which is meaningless for S3 and WebDAV. It is not a protocol branch in the sense this milestone removes — it is "does this backend have an auth kind at all". Phase 2 folds it into `descriptor.requiresSecret(values)`, which already answers exactly this question; leave it here with a comment saying so, and do not invent a second mechanism now.

- [ ] **Step 5: Collapse the App's three save branches**

In `Sources/MacSCPApp/ContentView.swift`, replace the `if form.kind == .s3 { … } else if form.kind == .webdav { … } else { … }` block (lines ~2394-2440 plus its `else`) with a single call:

```swift
            let stored = sessionListViewModel.save(
                name: form.saveName.trimmingCharacters(in: .whitespacesAndNewlines),
                values: form.values,
                password: form.password,
                kind: form.kind,
                groupID: form.selectedGroupID,
                loginSetID: form.loginMode == .set ? form.selectedLoginSetID : newSetID,
                jump: form.buildJumpSpecForSave(),
                jumpSecret: form.jumpPassword)
```

**Read the `else` branch before deleting it** and carry over anything it does that the three lines above do not — in particular how it derives the jump spec and the jump secret. If it calls a different helper than `buildJumpSpecForSave()`, use that name; the point is one call, not a specific spelling.

Then replace the prefill branches at ~2544-2700 (`form.host = stored.host` through the WebDAV `else if`) with `form.beginEditing(stored)` if the surrounding path is an edit, or with the same `defaultValues` + `sessionValues` merge if it is a connect-from-sidebar fill. Both spellings must end with the same two lines the branches had: the login-mode assignment and the jump prefill.

- [ ] **Step 6: Build and run everything**

Run: `swift build 2>&1 | tail -20` — expected clean.
Run: `swift test 2>&1 | tail -10` — expected PASS.

`SessionListViewModelTests.swift` has 17 fixtures and several direct `save(...)` calls; update those call sites to the `values:` form using `BackendDescriptor.descriptor(for:).sessionValues(...)` or a hand-built `FieldValues`, whichever the test's subject makes clearer.

- [ ] **Step 7: Commit**

```bash
git add Sources Tests
git commit -m "refactor: one prefill and one save path for every protocol

beginEditing resets to the descriptor's defaults and merges its
sessionValues, which is what the hand-written S3 and WebDAV else-branches
did field by field. SessionListViewModel.save takes FieldValues instead of
a flat host/port/username triple and lets the backend's adapter write its
own fields, so ContentView's three save branches become one call.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 8: The format migration (RISK — this is people's saved connections)

**Files:**
- Create: `Sources/macSCPCore/Sessions/StoredSSHConfig.swift`, `Sources/macSCPCore/Sessions/LegacyStoredSession.swift`, `Tests/macSCPCoreTests/Fixtures/legacy-sessions-pre-m23.json`
- Modify: `Sources/macSCPCore/Sessions/StoredSession.swift`, `Sources/macSCPCore/Sessions/SessionStore.swift`, `Tests/macSCPCoreTests/SessionFixtures.swift`
- Modify: every remaining reader of `session.host`/`.port`/`.username`/`.authKind`/`.keyPath`/`.jump` (68 code lines in `Sources`, 11 in `Tests`)
- Test: `Tests/macSCPCoreTests/SessionStoreMigrationTests.swift` (new file)

**Interfaces:**
- Produces: `StoredSSHConfig`; `StoredSession.ssh: StoredSSHConfig?`; `StoredSession` loses `host`, `port`, `username`, `authKind`, `keyPath`, `jump` at the top level.

**Before starting:** re-read the spec's "What is achievable" section. The new version writes **`sessions-v2.json`** and leaves `sessions.json` untouched. A downgrade must not crash; the old file is the migration-moment backup. After the migration the two diverge, and that is the accepted trade.

- [ ] **Step 1: Write the frozen legacy fixture**

`Tests/macSCPCoreTests/Fixtures/legacy-sessions-pre-m23.json` — today's exact on-disk shape, with one session of each kind and a jump host and a group:

```json
{
  "groups" : [
    { "id" : "11111111-1111-1111-1111-111111111111", "name" : "Production" }
  ],
  "sessions" : [
    {
      "authKind" : "privateKey",
      "groupID" : "11111111-1111-1111-1111-111111111111",
      "host" : "prod.example.com",
      "id" : "22222222-2222-2222-2222-222222222222",
      "jump" : {
        "authKind" : "password",
        "host" : "bastion.example.com",
        "port" : 2022,
        "secretID" : "33333333-3333-3333-3333-333333333333",
        "username" : "hop"
      },
      "keyPath" : "/keys/prod",
      "kind" : "ssh",
      "name" : "Prod",
      "port" : 2222,
      "username" : "deploy"
    },
    {
      "authKind" : "password",
      "host" : "unused",
      "id" : "44444444-4444-4444-4444-444444444444",
      "kind" : "s3",
      "loginSetID" : "55555555-5555-5555-5555-555555555555",
      "name" : "Archive",
      "port" : 22,
      "s3" : {
        "accessKeyID" : "AKIAEXAMPLE",
        "bucket" : "archive",
        "endpoint" : "https://s3.example.com",
        "region" : "eu-central-1",
        "usePathStyle" : true
      },
      "username" : "unused"
    },
    {
      "authKind" : "password",
      "host" : "unused",
      "id" : "66666666-6666-6666-6666-666666666666",
      "kind" : "webdav",
      "name" : "Cloud",
      "port" : 22,
      "username" : "unused",
      "webdav" : {
        "baseURL" : "https://cloud.example.com/remote.php/dav",
        "useNextcloudPath" : true,
        "username" : "tim"
      }
    }
  ]
}
```

**This file is frozen.** It must never be regenerated from the current model — the moment it is, it stops being evidence.

- [ ] **Step 2: Write the failing migration test**

`Tests/macSCPCoreTests/SessionStoreMigrationTests.swift`:

```swift
import Foundation
import Testing
@testable import macSCPCore

/// The only test that proves nobody loses their connections, and the only one
/// reasoning cannot replace.
@Suite struct SessionStoreMigrationTests {
    /// Addressed by `#filePath`, NOT `Bundle.module`: `Package.swift` excludes
    /// `Fixtures` from the test target's resources, because these files must
    /// be copied to disk under the names the stores look for rather than
    /// bundled. Same mechanism as `LegacyStoreCompatibilityTests`.
    private func stagedDirectory() throws -> URL {
        let fixtures = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-m23-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: fixtures.appendingPathComponent("legacy-sessions-pre-m23.json"),
            to: directory.appendingPathComponent("sessions.json"))
        return directory
    }

    @Test func everySSHFieldSurvivesTheMigration() throws {
        let store = SessionStore(directory: try stagedDirectory())
        let prod = try #require(try store.all().first { $0.name == "Prod" })
        #expect(prod.ssh?.host == "prod.example.com")
        #expect(prod.ssh?.port == 2222)
        #expect(prod.ssh?.username == "deploy")
        #expect(prod.ssh?.authKind == .privateKey)
        #expect(prod.ssh?.keyPath == "/keys/prod")
        #expect(prod.groupID == UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
    }

    @Test func theJumpHostSurvivesWithItsOwnSecretSlot() throws {
        let store = SessionStore(directory: try stagedDirectory())
        let prod = try #require(try store.all().first { $0.name == "Prod" })
        let jump = try #require(prod.ssh?.jump)
        #expect(jump.host == "bastion.example.com")
        #expect(jump.port == 2022)
        #expect(jump.username == "hop")
        // The Keychain slot is the one thing a regenerated id would silently
        // orphan, taking the stored jump password with it.
        #expect(jump.secretID == UUID(uuidString: "33333333-3333-3333-3333-333333333333"))
    }

    @Test func theS3AndWebDAVBlocksSurviveAndTheirPlaceholdersDoNot() throws {
        let store = SessionStore(directory: try stagedDirectory())
        let archive = try #require(try store.all().first { $0.name == "Archive" })
        #expect(archive.s3?.bucket == "archive")
        #expect(archive.s3?.usePathStyle == true)
        #expect(archive.loginSetID == UUID(uuidString: "55555555-5555-5555-5555-555555555555"))
        // A non-SSH session gets NO ssh block — that is the whole point.
        #expect(archive.ssh == nil)

        let cloud = try #require(try store.all().first { $0.name == "Cloud" })
        #expect(cloud.webdav?.username == "tim")
        #expect(cloud.webdav?.useNextcloudPath == true)
        #expect(cloud.ssh == nil)
    }

    @Test func groupsSurviveTheMigration() throws {
        let store = SessionStore(directory: try stagedDirectory())
        #expect(try store.allGroups().map(\.name) == ["Production"])
    }

    /// A downgrade must not crash. The old file stays exactly where the old
    /// version looks for it, byte for byte.
    @Test func theOldFileIsLeftUntouched() throws {
        let directory = try stagedDirectory()
        let old = directory.appendingPathComponent("sessions.json")
        let before = try Data(contentsOf: old)
        _ = try SessionStore(directory: directory).all()
        #expect(try Data(contentsOf: old) == before)
        #expect(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("sessions-v2.json")
                .path(percentEncoded: false)))
    }

    /// Migrating twice must not double anything, and the second read must come
    /// from v2 rather than re-running the upgrade.
    @Test func migrationIsIdempotent() throws {
        let directory = try stagedDirectory()
        let store = SessionStore(directory: directory)
        #expect(try store.all().count == 3)
        #expect(try store.all().count == 3)
    }
}
```

**`Package.swift` needs no change.** The test target already declares `exclude: ["Fixtures"]` precisely so these files are *not* bundled; dropping the new fixture into the existing directory is the whole wiring.

**`LegacyStoreCompatibilityTests` is this test's M22 twin and will exercise the same migration path** — it seeds `sessions.json` from `legacy-session-pre-m22.json` and reads it through the real `SessionStore`. After this task that read goes through `migrateFromLegacy()`. Its assertions on `.host`/`.username` keep working via the Step 5 conveniences. If it goes red, the migration is wrong — do not adjust the test to match the code.

- [ ] **Step 3: Run it to verify it fails**

Run: `swift test --filter SessionStoreMigration 2>&1 | tail -20`
Expected: FAIL — `value of type 'StoredSession' has no member 'ssh'`.

- [ ] **Step 4: Add `StoredSSHConfig`**

`Sources/macSCPCore/Sessions/StoredSSHConfig.swift`:

```swift
import Foundation

/// SSH's persisted, SECRET-FREE parameters (M23) — the sibling of
/// `StoredS3Config` and `StoredWebDAVConfig`.
///
/// These lived at the top level of `StoredSession` until M23, where they were
/// meaningless on every S3 and WebDAV session and had to be filled with the
/// literal `"unused"`. The password and the key passphrase are NOT here: they
/// live in the Keychain under the session's id.
public struct StoredSSHConfig: Codable, Equatable, Sendable {
    public var host: String
    public var port: Int
    public var username: String
    public var authKind: StoredSession.AuthKind
    /// Path to the private key (only set when authKind == .privateKey).
    public var keyPath: String?
    /// The jump host hop configured for this session, if any (M10c). Lives
    /// here rather than beside `kind` because a hop is an SSH concept: no
    /// other protocol tunnels.
    public var jump: StoredSession.JumpSpec?

    public init(
        host: String, port: Int = 22, username: String,
        authKind: StoredSession.AuthKind = .password,
        keyPath: String? = nil, jump: StoredSession.JumpSpec? = nil
    ) {
        self.host = host; self.port = port; self.username = username
        self.authKind = authKind; self.keyPath = keyPath; self.jump = jump
    }
}
```

- [ ] **Step 5: Reshape `StoredSession`**

Rewrite `Sources/macSCPCore/Sessions/StoredSession.swift` so the struct keeps `id`, `name`, `groupID`, `loginSetID`, `kind`, `s3`, `webdav`, `JumpSpec` and `AuthKind`, drops the six flat fields, and gains `ssh: StoredSSHConfig?`. Keep the explicit `init(from decoder:)` — `kind` still needs its `?? .ssh` default for a v2 file written by an older build of this same milestone.

Add convenience accessors so the 68 readers change shape rather than logic:

```swift
    /// The SSH host, or "" for a session that has no SSH block.
    ///
    /// Read-only conveniences over `ssh` (M23), kept so the callers that
    /// legitimately want "the host, if there is one" — the sidebar tooltip,
    /// the audit trail, `SSHCommandBuilder` — read one property instead of
    /// unwrapping. Anything that WRITES must go through `ssh` directly, so
    /// that writing to a session with no SSH block is a compile error rather
    /// than a silent no-op.
    public var host: String { ssh?.host ?? "" }
    public var port: Int { ssh?.port ?? 22 }
    public var username: String { ssh?.username ?? "" }
    public var authKind: AuthKind { ssh?.authKind ?? .password }
    public var keyPath: String? { ssh?.keyPath }
    public var jump: JumpSpec? { ssh?.jump }
```

**This is the decision that makes the 68-reader sweep tractable** — and it is also a trap if it stays permanent, because `session.host` reading `""` for an S3 session is the `"unused"` placeholder wearing a different hat. Mark them:

```swift
    // DEPRECATION INTENT: these exist to keep M23 Phase 1 reviewable. Phase 3
    // removes the ones export/import uses; anything still reading them after
    // that is a caller that should be asking the descriptor's `displaySummary`
    // or `sessionValues` instead.
```

- [ ] **Step 6: Add the legacy decoder**

`Sources/macSCPCore/Sessions/LegacyStoredSession.swift`:

```swift
import Foundation

/// The pre-M23 on-disk shape of a session: SSH's fields flat at the top level,
/// meaningless on S3 and WebDAV sessions, where they held `"unused"`.
///
/// DECODE ONLY. Nothing writes this shape any more — `SessionStore` reads it
/// once from `sessions.json` and writes the result to `sessions-v2.json`,
/// leaving the old file untouched as the migration-moment backup.
struct LegacyStoredSession: Decodable {
    let id: UUID
    let name: String
    let host: String
    let port: Int
    let username: String
    let authKind: StoredSession.AuthKind
    let keyPath: String?
    let groupID: UUID?
    let loginSetID: UUID?
    let jump: StoredSession.JumpSpec?
    let kind: ConnectionKind?
    let s3: StoredS3Config?
    let webdav: StoredWebDAVConfig?

    /// A session's `kind` decides whether the flat fields meant anything. For
    /// S3 and WebDAV they were placeholders, and carrying them into an `ssh`
    /// block would preserve exactly the defect this milestone removes.
    func upgraded() -> StoredSession {
        let resolvedKind = kind ?? .ssh
        var session = StoredSession(
            id: id, name: name, groupID: groupID,
            loginSetID: loginSetID, kind: resolvedKind,
            s3: s3, webdav: webdav)
        if resolvedKind == .ssh {
            session.ssh = StoredSSHConfig(
                host: host, port: port, username: username,
                authKind: authKind, keyPath: keyPath, jump: jump)
        }
        return session
    }
}
```

- [ ] **Step 7: Teach `SessionStore` the migration**

In `Sources/macSCPCore/Sessions/SessionStore.swift`:

```swift
    private var fileURL: URL {
        directory.appendingPathComponent("sessions-v2.json")
    }

    /// The pre-M23 file. Read once, then left alone forever.
    ///
    /// A version key inside the file would have been the tidier design and is
    /// not available: macSCP 1.0 is already shipped, knows nothing about one,
    /// and aborts on the missing required `host`. A version number helps
    /// FUTURE readers, never past ones — so the new format gets a new name,
    /// and a downgrade finds its own file exactly where it left it.
    ///
    /// The price, stated where the code is: after the migration the two files
    /// diverge. A connection created here is invisible to an older build.
    private var legacyFileURL: URL {
        directory.appendingPathComponent("sessions.json")
    }

    private struct StoreFile: Codable {
        var groups: [StoredGroup] = []
        var sessions: [StoredSession] = []
    }

    private struct LegacyStoreFile: Decodable {
        var groups: [StoredGroup] = []
        var sessions: [LegacyStoredSession] = []
    }

    private func load() throws -> StoreFile {
        var file: StoreFile
        if FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) {
            file = try JSONDecoder().decode(StoreFile.self, from: Data(contentsOf: fileURL))
        } else if let migrated = try migrateFromLegacy() {
            file = migrated
        } else {
            return StoreFile()
        }
        // Defensive: a groupID whose group no longer exists behaves like nil.
        let knownIDs = Set(file.groups.map(\.id))
        for index in file.sessions.indices {
            guard let groupID = file.sessions[index].groupID,
                  !knownIDs.contains(groupID) else { continue }
            file.sessions[index].groupID = nil
        }
        return file
    }

    /// Reads the pre-M23 file, writes its upgrade to the new one, and returns
    /// it. Returns nil when there is nothing to migrate.
    ///
    /// The legacy file supported two shapes — the current container and an
    /// even older bare `[StoredSession]` array — and both are still read here,
    /// because an installation that never opened a version with groups still
    /// has the array on disk.
    private func migrateFromLegacy() throws -> StoreFile? {
        let path = legacyFileURL.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let data = try Data(contentsOf: legacyFileURL)
        let legacy: LegacyStoreFile
        if let container = try? JSONDecoder().decode(LegacyStoreFile.self, from: data) {
            legacy = container
        } else {
            legacy = LegacyStoreFile(
                groups: [],
                sessions: try JSONDecoder().decode([LegacyStoredSession].self, from: data))
        }
        let migrated = StoreFile(
            groups: legacy.groups, sessions: legacy.sessions.map { $0.upgraded() })
        try persist(migrated)
        return migrated
    }
```

`persist(_:)` is unchanged — it already writes to `fileURL`, which now names the v2 file.

- [ ] **Step 8: Sweep the readers**

```bash
swift build 2>&1 | grep -E 'error:' | head -40
```

Work through the errors. Every one is a *writer* of a flat field, because the read conveniences from Step 5 cover the readers. Writers become `session.ssh?.host = …` or, better, go through `descriptor.apply`.

**Two call sites need judgement rather than a mechanical fix:**

- `SessionListViewModel` around lines 211-225 and 700-710 builds a bastion login from `session.username`/`.authKind`/`.keyPath`. For an SSH session the conveniences give the right answer; for a session-mode jump pointing at a non-SSH session they now give `""` instead of `"unused"`. Check what `JumpSessionEligibility` already refuses — if it already refuses non-SSH jump targets, add a test pinning that, and leave the conveniences.
- `SessionImportPlanner.duplicateKey` was made kind-aware before this milestone. Re-read it and confirm it still is; the migration must not resurrect a shared key.

- [ ] **Step 9: Update the fixture helper**

In `Tests/macSCPCoreTests/SessionFixtures.swift`, change the three bodies — and **only** the bodies. If a signature has to change, something is wrong with Task 1's design and it is worth stopping to understand why.

```swift
func sshSession(...) -> StoredSession {
    var session = StoredSession(id: id, name: name, groupID: groupID,
                                loginSetID: loginSetID, kind: .ssh)
    session.ssh = StoredSSHConfig(
        host: host, port: port, username: username,
        authKind: authKind, keyPath: keyPath, jump: jump)
    return session
}

func s3Session(...) -> StoredSession {
    StoredSession(id: id, name: name, groupID: groupID,
                  loginSetID: loginSetID, kind: .s3, s3: config)
}

func webdavSession(...) -> StoredSession {
    StoredSession(id: id, name: name, groupID: groupID,
                  loginSetID: loginSetID, kind: .webdav, webdav: config)
}
```

- [ ] **Step 10: Run everything**

```bash
swift test 2>&1 | tail -15
```

Expected: PASS. `StoredSessionCompatTests` and `StoredSessionTests` — the two files Task 1 deliberately left alone — will need real edits here, because they are *about* the shape that just changed. Rewrite their expectations to the new shape; do not delete a test.

Then the gated suites:

```bash
docker compose -f docker/test-server/compose.yml up -d
MACSCP_ITEST=1 swift test 2>&1 | tail -10
MACSCP_KEYCHAIN=1 swift test --filter Keychain 2>&1 | tail -10
```

- [ ] **Step 11: Commit**

```bash
git add Sources Tests
git commit -m "feat(core): move SSH's fields into their own stored block

StoredSession loses host/port/username/authKind/keyPath/jump from the top
level and gains ssh: StoredSSHConfig?, symmetric with s3 and webdav. A
session with no SSH block simply has none, which is what ends the
\"unused\" placeholder at the storage layer too.

The new shape is written to sessions-v2.json and sessions.json is left
untouched: a version key inside the file cannot help, since macSCP 1.0 is
shipped and aborts on the missing required host. A downgrade therefore
finds its own file rather than crashing — at the cost of the two files
diverging afterwards, which belongs in the release notes.

A frozen pre-M23 fixture proves every field, the jump host's own Keychain
slot and the group assignment survive.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 9: Phase close — prove the criteria, then review

**Files:** none by default. Anything this task changes is a fix it found.

- [ ] **Step 1: Prove success criterion 1 mechanically**

The claim is "adding a fourth `ConnectionKind` requires no edit to these five files". Check what is actually left:

```bash
grep -nE 'case \.ssh|case \.s3|case \.webdav|kind == \.(ssh|s3|webdav)' \
  Sources/macSCPCore/Presentation/ConnectionViewModel.swift \
  Sources/MacSCPApp/ContentView.swift \
  Sources/macSCPCore/Presentation/SessionListViewModel.swift \
  Sources/macSCPCore/Sessions/SessionImportPlanner.swift \
  Sources/MacSCPApp/ConnectionFormView.swift \
  | grep -v '^\S*: *//'
```

Every surviving line must be **either** something Phase 2 or Phase 3 explicitly owns (the import planner is Phase 3; `StoredSessionConnectionConfig` is Phase 2), **or** a capability question rather than a protocol question (`capabilities.supportsShell`). Write the surviving list into the phase's section of the ledger with one line each saying which it is. A line you cannot classify is a finding, not a footnote.

- [ ] **Step 2: Prove criterion 2**

```bash
grep -rn --include='*.swift' '"unused"' Sources
```

Expected: no matches.

- [ ] **Step 3: Prove criterion 5 — no test was deleted**

```bash
git diff --stat develop...HEAD -- Tests
```

Read the deletions. A test that disappeared must have been *relocated*, and you must be able to name where. M22's credential-schema move is the precedent: tests moved files, none vanished.

- [ ] **Step 4: Run the full matrix**

```bash
swift build 2>&1 | tail -5
swift test 2>&1 | tail -5
docker compose -f docker/test-server/compose.yml up -d
MACSCP_ITEST=1 swift test 2>&1 | tail -5
MACSCP_KEYCHAIN=1 swift test 2>&1 | tail -5
for lang in en de fr pl; do
  plutil -lint "Sources/macSCPCore/Resources/$lang.lproj/Localizable.strings"
done
```

All green, all four catalogs clean.

- [ ] **Step 5: Whole-phase review**

Dispatch a fresh reviewer over `git diff develop...HEAD` with the spec and this plan as context. The three questions that matter most, because they are where a plausible-looking change does real damage:

1. **The connect path.** Compare the collapsed `connect()` against the three bodies it replaced, line by line. Is the jump still attached after the factory? Is the host-key decider still passed to every backend? Is a fingerprint mismatch still a hard stop with no decider consulted?
2. **The migration.** Can any pre-M23 session lose a field? Specifically: a jump host's `secretID` (losing it orphans the stored jump password), a `groupID`, a `loginSetID`, or an S3 `usePathStyle`.
3. **The conveniences.** `session.host` now returns `""` for an S3 session. Find every caller that treats that as a real host rather than as "no host" — that is `"unused"` with a new spelling, and it is exactly what the milestone set out to remove.

- [ ] **Step 6: Record the phase in the ledger and commit**

Append the surviving-branch list from Step 1, the review findings and their resolutions to the milestone's `progress.md`. Then:

```bash
git add docs
git commit -m "docs(m23): record the phase 1 close — surviving branches and review

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

**Do not push.** The coordinator pushes per milestone after the final whole-branch review.

---

## Self-review

**Spec coverage.** Every Phase 1 element in the spec maps to a task: the two field properties → Task 2; the Core validator → Task 3; the write adapter → Task 4; `connect()`/`validateForEditSave()`/`beginEditing()` collapsing → Tasks 5-7; the `ContentView` save/fill paths and `ConnectionFormView`'s secret ternary → Tasks 5 and 7; the format migration → Task 8; the fixture-helper step the spec's measurement section added → Task 1. The three testing shapes the spec names — completeness per backend, round trip per backend, the frozen legacy fixture — are Tasks 2, 4 and 8 respectively. Success criteria 1, 2 and 5 are proven mechanically in Task 9; criterion 3 is Task 8's fixture; criterion 4 belongs to Phase 2 and is not claimed here.

**Deliberate deviation from the spec.** The spec orders the format migration alongside the write adapter. This plan puts it last among the code tasks, because after Tasks 5-7 almost nothing constructs a `StoredSession` directly — which shrinks the blast radius of the type change from "every validator" to "three adapters plus one fixture helper". Same end state, smaller diff to review at the riskiest moment.

**Naming.** The spec writes the validator's result as `(messageKey, fieldID)`. This plan calls the second element `fieldKey` and returns the **namespaced** key, because that is the string `FieldValues.raw` and `SchemaFormView.failedFieldID` both use; `fieldID` would have invited passing a bare `"host"` that matches nothing.

**Known soft spots, named rather than hidden.** Task 7 Step 5 tells the implementer to read `ContentView`'s `else` branch before deleting it rather than transcribing its replacement — that file is 3,544 lines and its jump-spec derivation is not quoted here. Task 8 Step 8 leaves two call sites to judgement with the question spelled out instead of the answer. Both are places where a confidently wrong instruction would be worse than an honest one.
