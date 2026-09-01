# M24 — Protocol-Correct Logins Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close two data-loss resp. misconfiguration paths that arise because
an SSH-shaped layer lets protocol-foreign sessions through:
`LoginMergePlanner` (deletes S3/WebDAV secrets) and `JumpSessionEligibility`
(offers a bucket as a bastion).

**Architecture:** The merge planner derives its grouping key from the
backend's `credentialSchema` instead of from SSH fields; a new
`SecretRole` declaration separates "the secret **is** the login" from "the
secret **unlocks** a login". The jump gap is closed at the resolver, not
just in the picker — a picker filter only protects new data.

**Tech Stack:** Swift 6 (`.swiftLanguageMode(.v5)`), SwiftPM, macOS 15+,
Swift Testing (`@Test`/`#expect`).

**Spec:** `docs/superpowers/specs/2026-08-08-m24-protocol-correct-logins-design.md`

## Global Constraints

- **Code and comments: English only.** Identifiers, doc comments,
  inline comments, test names, `reason:` strings. No German in source files.
- **Commit messages: English, Conventional Commits** (enforced by CI).
  Footer on every commit: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- **Commit/push only on explicit request.** No `scripts/release`.
- **A secret value must never be logged, printed, or embedded in an error.**
  Secrets live exclusively in the Keychain (`SecretStore`); JSON stores
  never contain any.
- **Never commit key material.**
- **App UI is localized**, four catalogs with identical key sets:
  `Sources/MacSCPApp/Resources/{en,de,fr,pl}.lproj/Localizable.strings`.
  `LocalizableStringsTests` enforces parity. **CLI output is not
  localized.**
- **Do not launch the GUI app.**
- Tests: `swift test`. Gated: `MACSCP_ITEST=1` (Docker rig) and
  `MACSCP_KEYCHAIN=1` (real keychain).
- Build sessions in tests **always** via the fixtures from
  `Tests/macSCPCoreTests/SessionFixtures.swift` (`sshSession`,
  `s3Session`, `webdavSession`) — never `StoredSession` directly.

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `Sources/macSCPCore/Capabilities/FieldVocabulary.swift` | declare `SecretRole` | 1 |
| `Sources/macSCPCore/Capabilities/ConnectionFieldSchema.swift` | `ConnectionField.secretRole` field | 1 |
| `Sources/macSCPCore/{SSH,S3,WebDAV}/*FieldSchema.swift` | declare a role per secret field | 1 |
| `Sources/macSCPCore/Sessions/LoginMergePlanner.swift` | key from the schema; candidate shape | 2 |
| `Sources/MacSCPApp/LoginSetsSheet.swift` | three read sites onto `displayLabel` | 2, 3 |
| `Sources/macSCPCore/Presentation/SessionListViewModel.swift` | generic `applyMerge` + guard; `suggestedSetName`; `delete` guard | 3, 5 |
| `Sources/macSCPCore/Sessions/JumpSessionEligibility.swift` | `kind` filter | 4 |
| `Sources/macSCPCore/Sessions/LoginResolver.swift` | hard guard + new error case | 4 |
| `Sources/MacSCPApp/{ContentView,ConnectionFormView}.swift` | three `catch` arms | 4 |
| `Sources/MacSCPApp/Resources/*.lproj/Localizable.strings` | one new key × 4 | 4 |

**On test files:** New tests belong in the existing suite for the type they
test (`LoginMergePlannerTests`, `JumpSessionEligibilityTests`,
`LoginResolverTests`, `SessionListViewModelTests`, `BackendDescriptorTests`).
Do not create a new test file.

---

## Why the tests here stand as a table and not as code

M23 found ten defects that sat **in the plan** and not in the
implementation; the pattern was stable enough to name: *test code written by
the plan author and never run is the least reliable part of a plan.*
Production code therefore stands below verbatim, while tests instead stand as
a table of (name, setup, expectation) plus a pointer to the file whose shape
is to be copied. Whoever writes the test also runs it.

---

## Task 1: Declare `SecretRole`

**Files:**
- Modify: `Sources/macSCPCore/Capabilities/FieldVocabulary.swift` (new enum at the end, next to `FieldIdentity`)
- Modify: `Sources/macSCPCore/Capabilities/ConnectionFieldSchema.swift:4-83` (`ConnectionField`)
- Modify: `Sources/macSCPCore/SSH/SSHFieldSchema.swift:156-168` (`password`, `passphrase`)
- Modify: `Sources/macSCPCore/S3/S3FieldSchema.swift:86-90` (`secretAccessKey`)
- Modify: `Sources/macSCPCore/WebDAV/WebDAVFieldSchema.swift:72-74` (`password`)
- Test: `Tests/macSCPCoreTests/BackendDescriptorTests.swift`

**Interfaces:**
- Produces: `SecretRole` with the cases `.credential` and `.passphrase`;
  `ConnectionField.secretRole: SecretRole?` (default `nil`), set via the
  new init parameter `secretRole: SecretRole? = nil` **as the last
  parameter**, so no existing call site needs to change.

- [ ] **Step 1: Create `SecretRole`**

At the end of `FieldVocabulary.swift`:

```swift
/// What a secret field's value MEANS for the identity of a login (M24) — the
/// answer to "do these two sessions log in as the same principal?", which
/// `LoginMergePlanner` asks before offering to fold them into one login set.
///
/// Two cases, because there are two real behaviours. A password and an S3
/// secret access key ARE the credential: two logins with different ones are
/// different logins, and merging them would bind both to a set that can only
/// carry one — destroying the other's Keychain entry. An SSH passphrase is
/// not: it unlocks a key file that another field (`keyPath`) already names, so
/// two sessions on the same key file are the same login whether or not either
/// happens to have the passphrase stored.
///
/// NOT derivable from `isRequired`, which was the first thing tried. That
/// gives the right answer for SSH and S3 and the WRONG one for WebDAV, whose
/// password is optional since M23 so that anonymous shares work — a WebDAV
/// password would then leave the identity key, and two sessions with the same
/// user name and DIFFERENT passwords would collide.
public enum SecretRole: Sendable, Equatable {
    /// The secret is the credential itself.
    case credential
    /// The secret unlocks a credential named by another field.
    case passphrase
}
```

- [ ] **Step 2: `ConnectionField` carries the role**

In `ConnectionFieldSchema.swift`, after the `identity` property:

```swift
    /// For a `.secret` field: whether its value takes part in a login's
    /// identity (M24). Meaningless — and never set — on any other kind.
    ///
    /// Optional in the type, mandatory in practice, exactly like
    /// `invalidMessageKey`: `everySecretFieldDeclaresItsRole` fails the build
    /// for a secret field without one. The readers treat a missing role as
    /// `.credential`, which is the SAFE direction — the secret then enters the
    /// identity key, and two logins that differ in it are kept apart rather
    /// than merged.
    public let secretRole: SecretRole?
```

Add and assign the init parameter **as the last one**:

```swift
    public init(id: String, labelKey: String, labelDefault: String,
                kind: Kind, visibleWhen: FieldCondition? = nil,
                isRequired: Bool = false, format: FieldFormat? = nil,
                invalidMessageKey: String? = nil, identity: FieldIdentity? = nil,
                secretRole: SecretRole? = nil) {
        self.id = id; self.labelKey = labelKey; self.labelDefault = labelDefault
        self.kind = kind; self.visibleWhen = visibleWhen; self.isRequired = isRequired
        self.format = format; self.invalidMessageKey = invalidMessageKey
        self.identity = identity; self.secretRole = secretRole
    }
```

- [ ] **Step 3: Write the guard (red)**

In `Tests/macSCPCoreTests/BackendDescriptorTests.swift`, right after
`everyBackendDeclaresANonSecretIdentity` (lines 109–123) — copy its shape:
loop over `ConnectionKind.allCases`, `#expect` with a
`Comment(rawValue:)` rationale.

| Test | Setup | Expectation |
|---|---|---|
| `everySecretFieldDeclaresItsRole` | for each `kind` walk both schemas (`connectionSchema.fields + credentialSchema.fields`) | every field with `isSecret == true` has `secretRole != nil`; the rationale names `kind` and `field.id` and says that a missing value reads as `.credential` |
| `noNonSecretFieldDeclaresASecretRole` | same loop | every field with `isSecret == false` has `secretRole == nil` — prevents a role on a field that is never read as a secret |

- [ ] **Step 4: Confirm red**

Run: `swift test --filter BackendDescriptor`
Expected: `everySecretFieldDeclaresItsRole` fails (four fields without a role).

- [ ] **Step 5: Declare the four roles**

Each as the last argument of the affected `ConnectionField(...)`:

- `SSHField.password` → `secretRole: .credential`
- `SSHField.passphrase` → `secretRole: .passphrase`
- `S3Field.secretAccessKey` → `secretRole: .credential`
- `WebDAVField.password` → `secretRole: .credential`

Add a sentence to the existing comment on `SSHField.passphrase` ("The passphrase stays
OPTIONAL…"): the role says the passphrase does not identify the
login — the key file does, via `keyPath`.

- [ ] **Step 6: Confirm green**

Run: `swift test --filter BackendDescriptor`
Expected: PASS. Then `swift build` (including the App target) with no new warnings.

- [ ] **Step 7: Commit**

```bash
git add Sources/macSCPCore Tests/macSCPCoreTests/BackendDescriptorTests.swift
git commit -m "feat(core): declare what a secret field means for login identity"
```

---

## Task 2: Merge key from the schema

**Files:**
- Modify: `Sources/macSCPCore/Sessions/LoginMergePlanner.swift` (whole file)
- Modify: `Sources/MacSCPApp/LoginSetsSheet.swift:515-535` (banner) and `:541-553` (confirmation text)
- Test: `Tests/macSCPCoreTests/LoginMergePlannerTests.swift`

**Interfaces:**
- Consumes: `ConnectionField.secretRole` from Task 1.
- Produces: `LoginMergeCandidate(kind: ConnectionKind, values: FieldValues,
  displayLabel: String, sessionIDs: [UUID])`. `LoginMergePlanner.candidates(
  sessions:ignoredGroups:secrets:)` keeps its signature.

**Why App and Core in ONE task:** the candidate shape is `public` and is
read by `LoginSetsSheet`. Committed separately, `swift build` would be red
between the two tasks — house rule is a clean build including the
App target at the end of every task.

- [ ] **Step 1: Translate the existing SSH tests (red)**

Only re-read the three properties that dropped away, **change nothing about
inputs, `sessionIDs`, or the candidate count**:

| before | after |
|---|---|
| `candidate.username == "deploy"` | `candidate.displayLabel == "deploy"` |
| `candidate.authKind == .privateKey` | `candidate.values[SSHField.authKind] == "privateKey"` |
| `candidate.keyPath == "/k1"` | `candidate.values[SSHField.keyPath] == "/k1"` |

Should anything beyond that need touching, that is a **finding** and
belongs in the task report, not silently written away (spec, criterion 4).

- [ ] **Step 2: Write the new tests (red)**

Append to `LoginMergePlannerTests`. Copy the shape of the existing tests:
`InMemorySecretStore`, sessions via the fixtures, `#expect` on
`candidates.count` and `sessionIDs`.

| Test | Setup | Expectation |
|---|---|---|
| `twoS3SessionsSharingACredentialPairAreOneCandidate` | two `s3Session`, identical `StoredS3Config` except for `bucket`, **the same** secret under both session IDs | one candidate, `kind == .s3`, `sessionIDs == [a.id, b.id]`, `displayLabel == "AKIA"`, `values[S3Field.accessKeyID] == "AKIA"` |
| `twoS3SessionsWithDifferentSecretsAreNotACandidate` | as above, but **different** secrets | `candidates.isEmpty` |
| `twoS3SessionsWithDifferentAccessKeyIDsAreNotACandidate` | same secret, different `accessKeyID` | `candidates.isEmpty` |
| `twoWebDAVSessionsWithDifferentPasswordsAreNotACandidate` | two `webdavSession`, same `username`, different secrets | `candidates.isEmpty` — **the test the `isRequired` derivation would not have passed** |
| `twoWebDAVSessionsSharingAPasswordAreOneCandidate` | same `username`, same secret | one candidate, `kind == .webdav`, `displayLabel` == the user name |

`webdavSession` has **no** `username:` parameter — the user name comes
via `config: StoredWebDAVConfig(baseURL:username:useNextcloudPath:)`. The same
applies to S3: `s3Session(config: StoredS3Config(...))`.
| `anS3AndAnSSHSessionNeverShareACandidate` | one `sshSession` and one `s3Session`, **the same** secret under both IDs | `candidates.isEmpty` — `kind` sits in the key |
| `privateKeySessionsGroupWithoutReadingTheKeychain` | two `sshSession` with `authKind: .privateKey`, the same `keyPath`, and a `SecretStore` whose `password(for:)` fails the test | one candidate; the store was never read. **Copy the shape from** the read-hostile store `agentSetResolvesWithoutKeychainRead` uses in `LoginResolverTests` (a matching test double already sits at the end of `LoginMergePlannerTests.swift`) |
| `anonymousWebDAVSessionsAreNeverACandidate` | two `webdavSession` with an empty `username` and **no** Keychain entry | `candidates.isEmpty` |

- [ ] **Step 3: Confirm red**

Run: `swift test --filter LoginMergePlanner`
Expected: compile errors (the new properties do not exist) — that is the
red state for this task.

- [ ] **Step 4: Rewrite the candidate and the planner**

Replace `LoginMergePlanner.swift` in full:

```swift
import Foundation

/// A group of manual sessions that log in as the same principal (M10b spec §4,
/// generalized to every protocol in M24) — the "merge into one set?"
/// suggestion the UI banners.
public struct LoginMergeCandidate: Equatable, Sendable {
    /// Every session in the group has this kind, and the set a merge creates
    /// gets it. Part of the grouping key, so a group is never mixed.
    public var kind: ConnectionKind
    /// The credential values the group shares, in the backend's own field
    /// vocabulary — the visible non-secret credential fields, and NOTHING
    /// else. Never the secret: this value is handed to the UI and to
    /// `BackendDescriptor.loginSet(id:name:from:)`, and a secret has no
    /// business in either.
    public var values: FieldValues
    /// What to call this login on screen — the first visible non-secret
    /// credential field's value. The user name for SSH and WebDAV, the access
    /// key ID for S3.
    public var displayLabel: String
    public var sessionIDs: [UUID]

    public init(
        kind: ConnectionKind, values: FieldValues, displayLabel: String, sessionIDs: [UUID]
    ) {
        self.kind = kind
        self.values = values
        self.displayLabel = displayLabel
        self.sessionIDs = sessionIDs
    }
}

/// Grouping key: two sessions merge only if every part here matches.
///
/// `fields` holds the visible NON-SECRET credential fields by namespaced key.
/// Which fields those are is the backend's answer, not this file's — SSH shows
/// `keyPath` only under private-key auth, so the same code produces the
/// pre-M24 SSH key without naming SSH.
private struct LoginGroupKey: Hashable {
    var kind: ConnectionKind
    var fields: [String: String]
    var secret: String?
}

/// Pure equality detection over MANUAL sessions (loginSetID == nil).
/// Secret values are compared in memory only and never leave this function.
public enum LoginMergePlanner {
    public static func candidates(
        sessions: [StoredSession], ignoredGroups: [Set<UUID>], secrets: any SecretStore
    ) -> [LoginMergeCandidate] {
        // `order` tracks first-seen order of each key so ties fall back to
        // input order deterministically; `groups` accumulates session ids in
        // the order sessions were encountered.
        var order: [LoginGroupKey] = []
        var groups: [LoginGroupKey: [UUID]] = [:]
        var labels: [LoginGroupKey: String] = [:]
        var credentials: [LoginGroupKey: FieldValues] = [:]

        for session in sessions where session.loginSetID == nil {
            let descriptor = BackendDescriptor.descriptor(for: session.kind)
            // A session whose kind claims a block it does not carry is broken
            // stored data. It has no credentials to compare, and reading
            // through `StoredSession`'s SSH fallbacks would group it on
            // ""/.password — the placeholder M23 removed, in a new place.
            guard descriptor.hasStoredConfiguration(session) else { continue }

            let namespace = descriptor.fieldNamespace
            let storedValues = descriptor.sessionValues(session)
            let visible = descriptor.credentialSchema.visibleFields(
                in: storedValues, namespace: namespace)

            var fields: [String: String] = [:]
            var values = FieldValues()
            var label: String?
            for field in visible where !field.isSecret {
                let key = "\(namespace).\(field.id)"
                // Compared VERBATIM, like every part of this key: this asks
                // whether two logins are the same, and a user name differing
                // in case or padding is a different user name. (Distinct from
                // `FieldIdentity`, which answers "same CONNECTION?" for import
                // dedup and which `authKind` does not even carry.)
                let raw = storedValues.raw[key] ?? ""
                fields[key] = raw
                values.setRaw(key, to: raw)
                if label == nil { label = raw }
            }

            var secret: String?
            if let secretField = visible.first(where: \.isSecret) {
                // `.passphrase` unlocks a key file `keyPath` already put in
                // the key, so it neither enters the key nor justifies a
                // Keychain read. A missing role reads as `.credential`: the
                // safe direction, keeping logins apart rather than merging
                // them. And a secret-less session under `.credential` has
                // nothing to compare, so it cannot take part at all -- which
                // is the pre-M24 SSH rule, now applied to every backend.
                if secretField.secretRole != .passphrase {
                    guard let stored = (try? secrets.password(for: session.id)) ?? nil else {
                        continue
                    }
                    secret = stored
                }
            }

            let key = LoginGroupKey(kind: session.kind, fields: fields, secret: secret)
            if groups[key] == nil {
                order.append(key)
                labels[key] = label ?? ""
                credentials[key] = values
            }
            groups[key, default: []].append(session.id)
        }

        let candidates: [LoginMergeCandidate] = order.compactMap { key in
            guard let sessionIDs = groups[key], sessionIDs.count >= 2 else { return nil }
            let idSet = Set(sessionIDs)
            // A candidate that's already fully covered by a previously
            // ignored group (same ids, or a superset) stays suppressed until
            // a new member makes it no longer a subset.
            if ignoredGroups.contains(where: { idSet.isSubset(of: $0) }) { return nil }
            return LoginMergeCandidate(
                kind: key.kind, values: credentials[key] ?? FieldValues(),
                displayLabel: labels[key] ?? "", sessionIDs: sessionIDs)
        }

        return candidates.sorted { a, b in
            let labelOrder = a.displayLabel.localizedCaseInsensitiveCompare(b.displayLabel)
            if labelOrder != .orderedSame { return labelOrder == .orderedAscending }
            // Two protocols can produce the same label; without this the order
            // between them would depend on input order alone.
            if a.kind != b.kind { return a.kind.rawValue < b.kind.rawValue }
            return a.sessionIDs.count < b.sessionIDs.count
        }
    }
}
```

- [ ] **Step 5: Follow through on the App read sites**

In `LoginSetsSheet.swift`: `candidate.username` → `candidate.displayLabel` in
the banner (`mergeBanner`) and `mergeCandidate.username` → `mergeCandidate.displayLabel`
in `mergeConfirmMessage` and `applyMerge()`. The call
`suggestedSetName(forUsername:)` stays unchanged in this task and gets
`displayLabel` passed in; it is renamed in Task 3.

Leave the banner text unchanged: "%lld connections use the same login "%@"." still
holds verbatim for every protocol.

- [ ] **Step 6: Confirm green**

Run: `swift test --filter LoginMergePlanner`
Expected: PASS.
Run: `swift build`
Expected: clean, including the App target.

- [ ] **Step 7: Rewrite the characterization test into a commitment**

`nonSSHSessionsSharingASecretAreStillOfferedAsAMergeCandidate` in
`LoginMergePlannerTests.swift` is now wrong. **Do not delete** — rewrite
into `twoS3SessionsSharingACredentialPairMergeIntoAnS3Set` (or already lay
it out that way in Step 2 and here just remove the old one, if it is fully
subsumed in substance). The doc comment henceforth states what now holds and
names M24 as the point where it changed.

- [ ] **Step 8: Commit**

```bash
git add Sources/macSCPCore/Sessions/LoginMergePlanner.swift Sources/MacSCPApp/LoginSetsSheet.swift Tests/macSCPCoreTests/LoginMergePlannerTests.swift
git commit -m "fix(core): derive the merge key from the credential schema"
```

---

## Task 3: `applyMerge` builds a set of the right protocol

**Files:**
- Modify: `Sources/macSCPCore/Presentation/SessionListViewModel.swift:597-644` (`applyMerge`) and `:651-659` (`suggestedSetName`)
- Modify: `Sources/MacSCPApp/LoginSetsSheet.swift` (calls to `suggestedSetName`)
- Test: `Tests/macSCPCoreTests/SessionListViewModelTests.swift`

**Interfaces:**
- Consumes: `LoginMergeCandidate` from Task 2.
- Produces: `suggestedSetName(forLabel:) -> String` (renamed from
  `forUsername:`); `applyMerge(_:name:) -> LoginSet?` unchanged in
  signature.

- [ ] **Step 1: Write the tests (red)**

Append to `SessionListViewModelTests`; copy the shape of the existing
merge tests (around line 1880).

| Test | Setup | Expectation |
|---|---|---|
| `mergingTwoS3SessionsCreatesAnS3SetCarryingTheAccessKeyID` | two `s3Session` with the same `accessKeyID` and the same secret, stored; `mergeCandidates().first!` → `applyMerge(_:name: "acct")` | the returned set has `kind == .s3` and carries the `accessKeyID`; both sessions point at it via `loginSetID` |
| `mergingCarriesTheSecretOntoTheSetBeforeDeletingTheSessionSlots` | as above | under `set.id` sits exactly the shared secret; under both session IDs sits none anymore |
| `applyMergeRefusesACandidateWhoseSessionsAreOfMixedKind` | build a `LoginMergeCandidate` **by hand**: `kind: .s3`, but `sessionIDs` = one S3 **and** one SSH session | returns `nil`; **no** set created (`loginSets` unchanged), **no** secret deleted, both sessions unchanged. The guard is unreachable through the planner — hence the candidate is built directly |

- [ ] **Step 2: Confirm red**

Run: `swift test --filter SessionListViewModel`
Expected: the three new tests fail (`applyMerge` builds a `.ssh` set).

- [ ] **Step 3: Rebuild `applyMerge`**

Replace the body up to and including set creation; **everything from the
secret transport onward stays verbatim, as is** (source, rollback, deleting
the session slots — this part was never the problem):

```swift
    public func applyMerge(_ candidate: LoginMergeCandidate, name: String) -> LoginSet? {
        let groupSessions = candidate.sessionIDs.compactMap { id in
            sessions.first { $0.id == id }
        }
        guard let first = groupSessions.first else { return nil }
        // Defense in depth (M24). `LoginMergePlanner` puts the kind in its
        // grouping key, so a mixed group cannot come from there -- but this
        // function DELETES Keychain entries, and a candidate reaches it as a
        // plain value that anything could have built. Refusing here costs
        // nothing and turns "the planner guarantees it" from a comment into a
        // fact. Refusing means changing nothing at all: no set, no rewiring,
        // no deletion, so the banner simply stays.
        guard groupSessions.allSatisfy({ $0.kind == candidate.kind }) else { return nil }

        let descriptor = BackendDescriptor.descriptor(for: candidate.kind)
        let set = descriptor.loginSet(id: UUID(), name: name, from: candidate.values)
        do {
            try loginSetStore.upsert(set)
        } catch {
```

- [ ] **Step 4: Rename `suggestedSetName`**

`forUsername username: String` → `forLabel label: String`, body unchanged
(only rename the local variable). Doc comment: the name comes from the
candidate's `displayLabel` and for S3 is an access key ID, not a
user name. Follow through on both call sites in `LoginSetsSheet.swift`.

- [ ] **Step 5: Confirm green**

Run: `swift test --filter SessionListViewModel`
Expected: PASS.
Run: `swift build`
Expected: clean, including the App target.

- [ ] **Step 6: Commit**

```bash
git add Sources/macSCPCore/Presentation/SessionListViewModel.swift Sources/MacSCPApp/LoginSetsSheet.swift Tests/macSCPCoreTests/SessionListViewModelTests.swift
git commit -m "fix(core): merge into a login set of the candidate's own protocol"
```

---

## Task 4: The jump-host guard

**Files:**
- Modify: `Sources/macSCPCore/Sessions/JumpSessionEligibility.swift:9-15`
- Modify: `Sources/macSCPCore/Sessions/LoginResolver.swift:5-18` (error case) and `:183-213` (`resolveJump`)
- Modify: `Sources/MacSCPApp/ContentView.swift:2166` and `:2614` (one `catch` arm each)
- Modify: `Sources/MacSCPApp/ConnectionFormView.swift:231` (one `catch` arm)
- Modify: `Sources/MacSCPApp/Resources/{en,de,fr,pl}.lproj/Localizable.strings`
- Test: `Tests/macSCPCoreTests/JumpSessionEligibilityTests.swift`, `Tests/macSCPCoreTests/LoginResolverTests.swift`

**Interfaces:**
- Produces: `LoginResolveError.jumpSessionNotSSH`.

- [ ] **Step 1: Write the tests (red)**

| Test | File | Setup | Expectation |
|---|---|---|---|
| `onlySSHSessionsAreOfferedAsJumpHosts` | `JumpSessionEligibilityTests` | one `sshSession` and one `s3Session` | `eligible == [ssh]`. **This is the rewritten** `nonSSHSessionsAreStillOfferedAsJumpHosts` — do not delete, rewrite, turn the doc comment to the new commitment |
| `resolveJumpRefusesANonSSHReferencedSession` | `LoginResolverTests` | `JumpSpec` with `sessionID` = the ID of an `s3Session`, that one in `sessions` | throws `LoginResolveError.jumpSessionNotSSH` |
| `resolveJumpStillRefusesAMissingSessionFirst` | `LoginResolverTests` | `sessionID` points at an ID **not** contained in `sessions` | throws `.missingJumpSession`, not `.jumpSessionNotSSH` — pins the guard order |
| `resolveJumpAcceptsAnSSHReferencedSession` | `LoginResolverTests` | existing positive case | stays green unchanged (regression clamp) |

Copy the `JumpSpec` construction shape from the existing `resolveJump`
tests in `LoginResolverTests`.

- [ ] **Step 2: Confirm red**

Run: `swift test --filter "JumpSessionEligibility|LoginResolver"`
Expected: the first two new tests fail.

- [ ] **Step 3: Create the error case**

In `LoginResolver.swift`, in `LoginResolveError` after `jumpChainNotSupported`:

```swift
    /// A jump's `sessionID` points at a session that is not an SSH
    /// connection. Only SSH tunnels: an object-storage or WebDAV session has
    /// no host to dial through, and reading one's host/port yields
    /// `StoredSession`'s SSH fallbacks ("" and 22) — a bastion nobody can
    /// reach, offered without complaint.
    ///
    /// Distinct from `kindMismatch`, which is about a session and its LOGIN
    /// SET disagreeing. Naming that one here would report the wrong cause.
    case jumpSessionNotSSH
```

- [ ] **Step 4: Filter the picker**

```swift
        sessions
            .filter { $0.kind == .ssh && $0.id != editingSessionID && $0.jump == nil }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
```

Add the `kind` rationale to the type's doc comment (only SSH tunnels) and
note that the filter alone is not enough — the guard in the resolver
already covers references already stored.

- [ ] **Step 5: Set the guard**

In `resolveJump(spec:sets:secrets:sessions:referencingSessionID:)`, **after**
the `missingJumpSession` guard and **before** the chain guard:

```swift
        // The kind check comes before the chain check because it is the more
        // fundamental objection: a bucket is not a bastion whether or not it
        // also happens to carry a jump. `JumpSessionEligibility` keeps new
        // configurations from getting here; this covers the ones already on
        // disk, which no picker filter can reach.
        guard referenced.kind == .ssh else {
            throw LoginResolveError.jumpSessionNotSSH
        }
```

- [ ] **Step 6: The three `catch` sites and the L10n**

New key `form.jump.session.notSSH`, English default:
`"Only SSH connections can be used as a jump host."` The key must sit in
**all four** catalogs (DE/FR/PL translated).

In `ContentView.swift` at both sites, insert an arm after
`catch LoginResolveError.jumpChainNotSupported`, following the shape
of the neighboring arms (`form.showFailure(message:field: .jumpSession)`).

In `ConnectionFormView.swift` insert an arm before the generic `catch` —
**without it the new error would fall into the fallback** "The connection used as jump
host no longer exists.", which would say the untrue thing here.

- [ ] **Step 7: Confirm green**

Run: `swift test --filter "JumpSessionEligibility|LoginResolver"`
Expected: PASS.
Run: `swift test --filter Localizable`
Expected: PASS (parity across all four catalogs).
Run: `swift build`
Expected: clean, including the App target.

- [ ] **Step 8: Commit**

```bash
git add Sources/macSCPCore Sources/MacSCPApp Tests/macSCPCoreTests
git commit -m "fix(core): refuse a non-SSH session as a jump host"
```

---

## Task 5: `delete` does not write a placeholder host

**Files:**
- Modify: `Sources/macSCPCore/Presentation/SessionListViewModel.swift:230-278`
- Test: `Tests/macSCPCoreTests/SessionListViewModelTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks. `JumpRestoreResult` stays unchanged.

- [ ] **Step 1: Write the tests (red)**

| Test | Setup | Expectation |
|---|---|---|
| `deletingANonSSHBastionRestoresNothing` | an `s3Session` as bastion, an `sshSession` with `jump.sessionID` pointing at it; both stored; `delete(bucket)` | `result.restored == 0`; the referencing session's `JumpSpec` is **unchanged** (`sessionID` still there, `host` is **not** `""`); the S3 session is deleted |
| `deletingAnSSHBastionStillRestores` | existing positive case | stays green unchanged — the regression clamp for the guard |

- [ ] **Step 2: Confirm red**

Run: `swift test --filter SessionListViewModel`
Expected: `deletingANonSSHBastionRestoresNothing` fails (`host` is `""`).

- [ ] **Step 3: Set the guard**

In `delete(_:)`, right after `let affected = sessionsUsingAsJump(session.id)`:

```swift
        // Restoration copies the deleted session's host, port and login into
        // every jump that referenced it. Only an SSH session HAS those: for
        // any other kind `session.host`/`session.port` are `StoredSession`'s
        // SSH fallbacks, and copying them writes a bastion nobody can dial
        // into someone else's configuration, looking configured.
        //
        // Leaving the reference dangling instead is the honest outcome: the
        // next connect reports `.missingJumpSession` -- "the connection used
        // as jump host no longer exists" -- which is true and actionable.
        // Such a reference can only exist in data written before M24; the
        // picker no longer offers one and `LoginResolver.resolveJump` now
        // refuses one.
        let affected = session.kind == .ssh ? sessionsUsingAsJump(session.id) : []
```

(Replace the existing line, do not put a second one beside it.)

- [ ] **Step 4: Confirm green**

Run: `swift test --filter SessionListViewModel`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/macSCPCore/Presentation/SessionListViewModel.swift Tests/macSCPCoreTests/SessionListViewModelTests.swift
git commit -m "fix(core): do not restore a jump from a non-SSH bastion"
```

---

## Task 6: Milestone close

**Files:**
- Create: `docs/superpowers/specs/2026-08-08-m24-closeout.md`
- Modify: possibly `Sources/macSCPCore/Sessions/StoredSession.swift` (see Step 4)

- [ ] **Step 1: The full suite**

```bash
swift build
swift test
```
Expected: clean, no new warnings; test count **above** the pre-M24 baseline
(1571) — no net loss of test functions. Note the number.

- [ ] **Step 2: The gated suites**

Start the rig from the **main checkout**, never from a worktree:

```bash
docker compose -f docker/test-server/compose.yml up -d
```

Then:
```bash
MACSCP_ITEST=1 swift test
MACSCP_KEYCHAIN=1 swift test --filter Keychain
```
Expected: both green. If a run stalls at 0% CPU, that is the hang known
since M20 — abort and restart, note it in the report, do **not**
count it as an M24 finding.

- [ ] **Step 3: The catalogs**

```bash
for f in Sources/MacSCPApp/Resources/*.lproj/Localizable.strings Sources/macSCPCore/Resources/*.lproj/Localizable.strings; do plutil -lint "$f"; done
```
Expected: `OK` for every file.

- [ ] **Step 4: Check the four accessors (result open)**

```bash
grep -rn "\.host\b\|\.port\b\|\.username\b\|\.authKind\b" Sources/ --include=*.swift | grep -v "SSHFieldSchema\|StoredSSHConfig\|ssh\?\."
```

Judge every remaining reader of `StoredSession.host`/`port`/`username`/`authKind`
by whether it is SSH-guarded. **If all are guarded, delete the four
accessors** and run the suite again. If they are not, list the
unguarded readers **by name** in the closing report and leave the
accessors in place. Either is a valid outcome — the spec explicitly
says nothing was committed here.

- [ ] **Step 5: Write the closing report**

`docs/superpowers/specs/2026-08-08-m24-closeout.md`, copy the shape of
`2026-08-07-m23-closeout.md`. Must contain:

- Closing verification (test counts, gated runs, catalogs)
- The eight success criteria from the spec, each with its result — each with the evidence,
  not with a claim
- The result of Step 4
- The three release-notes points from the spec, augmented with anything that
  came up during implementation
- Every finding from Task 2, Step 1 (impermissible test adjustments)
- What remains open: the test-suite hang, orphaned jump Keychain slots, the
  eight dead form shims

- [ ] **Step 6: Commit**

```bash
git add docs/superpowers/specs/2026-08-08-m24-closeout.md
git commit -m "docs(m24): record the milestone close"
```

- [ ] **Step 7: Do NOT push**

Push happens only on explicit order from the maintainer.
Note in the report how many commits sit unpushed on `develop`.

---

## Plan self-review

**Spec coverage.** All eight success criteria have a task: 1 → T3, 2 →
T2, 3 → T3, 4 → T2/Step 1, 5 → T2 (`privateKeySessionsGroupWithoutReadingTheKeychain`),
6 → T4, 7 → T5, 8 → T2/Step 7 and T4/Step 1. `SecretRole` → T1. The
non-migration is an omission and needs no task; that it is
intentional stands in the comment from T5/Step 3.

**Type consistency.** `LoginMergeCandidate` is defined in T2 with
`(kind:values:displayLabel:sessionIDs:)` and is read in T3
(`candidate.values`, `candidate.kind`) and in T2/Step 5
(`candidate.displayLabel`) exactly the same way. `suggestedSetName(forLabel:)` is
renamed in T3 and called only there. `SecretRole` is defined in T1 and
read in T2 as `secretField.secretRole != .passphrase`.

**One deliberate deviation from the skill's prescription:** test code stands
as a table instead of as source, with a pointer to the shape to copy. Rationale
above in its own section.
