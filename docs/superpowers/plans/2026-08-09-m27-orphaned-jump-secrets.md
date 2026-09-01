# M27 — Orphaned Jump Secrets: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the Keychain entries the M23 migration left behind —
triggered by the user, without ever touching anything live.

**Architecture:** A Core type `LegacyJumpSecretSweep` reads the preserved
`sessions.json` through a new, read-only-only access on `SessionStore`,
subtracts everything still claimed today, and deletes the rest via the
existing `SecretStore.deletePassword`. The App gets a button in Settings ›
Manage Data.

**Tech Stack:** Swift 6, `.swiftLanguageMode(.v5)`, SwiftPM, macOS 15+,
Swift Testing, SwiftUI.

Spec: `../specs/2026-08-09-m27-orphaned-jump-secrets-design.md`

## Global Constraints

- **Code, comments, identifiers, test names: English only.** Internal docs
  German.
- **A secret value is never printed, logged, or embedded in an error — not
  even in a test failure message.** The sweep **never** calls
  `password(for:)`.
- **No `try? … ?? []` on any path of this milestone.** Every read error
  aborts.
- **The sweep does not touch ViewModel state**, only the stores.
- The legacy file is **read and not modified**.
- The `SecretStore` protocol gets **no** new member.
- App UI across all four catalogs en/de/fr/pl with identical key sets;
  the CLI is English and is not touched.
- Conventional Commits, English message, footer on every commit:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- **Do not push.** Do not start the GUI. Do not run `scripts/release`.
- Test-count baseline: **1619**.

---

### Task 1: The read access to the legacy file

**Files:**
- Modify: `Sources/macSCPCore/Sessions/SessionStore.swift`
- Test: `Tests/macSCPCoreTests/SessionStoreTests.swift`

**Interfaces:**
- Produces: `SessionStore.legacyJumpSecretIDs() throws -> [UUID]` — every
  `jump.secretID` from `sessions.json`, in file order, duplicates removed.
  Empty array if the file is missing. **Throws** if it is present and not
  readable/decodable.

- [ ] **Step 1: Write the tests**

In `SessionStoreTests`, in the style of the existing hand-written fixtures
(see `blocklessSSHFixture` and the rationale above it for why they are hand-written):

```swift
/// The sweep's candidate source. A jump's `secretID` is the only thing M23
/// left behind, so this reads exactly that -- and nothing else about the
/// legacy shape leaks out of the store.
@Test func legacyJumpSecretIDsReadsEveryJumpFromTheOldFile() throws {
    let dir = try makeTempDirectory()
    let a = UUID(), b = UUID()
    try legacyFixture(withJumpSecretIDs: [a, b]).write(
        to: dir.appendingPathComponent("sessions.json"))
    let store = SessionStore(directory: dir)
    #expect(try store.legacyJumpSecretIDs() == [a, b])
}

@Test func legacyJumpSecretIDsIsEmptyWhenTheOldFileIsGone() throws {
    let store = SessionStore(directory: try makeTempDirectory())
    #expect(try store.legacyJumpSecretIDs().isEmpty)
}

/// An unreadable file must NOT read as "no candidates". Everything in M27
/// hangs on this: a silent empty result here is the one shape that cannot
/// be distinguished from a clean install.
@Test func legacyJumpSecretIDsThrowsOnAnUnreadableFile() throws {
    let dir = try makeTempDirectory()
    try Data("{ not json".utf8).write(
        to: dir.appendingPathComponent("sessions.json"))
    let store = SessionStore(directory: dir)
    #expect(throws: (any Error).self) { try store.legacyJumpSecretIDs() }
}

/// A session without a jump contributes nothing, and the same secretID
/// appearing twice contributes once.
@Test func legacyJumpSecretIDsSkipsJumplessRecordsAndDeduplicates() throws {
    let dir = try makeTempDirectory()
    let a = UUID()
    try legacyFixture(withJumpSecretIDs: [a, nil, a]).write(
        to: dir.appendingPathComponent("sessions.json"))
    let store = SessionStore(directory: dir)
    #expect(try store.legacyJumpSecretIDs() == [a])
}

/// M23 keeps sessions.json as the downgrade snapshot. Reading it must not
/// touch it.
@Test func readingLegacyJumpSecretIDsLeavesTheFileByteIdentical() throws {
    let dir = try makeTempDirectory()
    let url = dir.appendingPathComponent("sessions.json")
    try legacyFixture(withJumpSecretIDs: [UUID()]).write(to: url)
    let before = try Data(contentsOf: url)
    _ = try SessionStore(directory: dir).legacyJumpSecretIDs()
    #expect(try Data(contentsOf: url) == before)
}
```

The fixture helper, right beside it in the same file — hand-written because
no write path in the app produces the legacy shape any more:

```swift
/// A pre-M23 `sessions.json`. Hand-written for the same reason the blockless
/// fixtures above are: nothing in the app writes this shape any more.
/// `nil` in the array means a session without a jump.
private func legacyFixture(withJumpSecretIDs ids: [UUID?]) -> Data {
    let records = ids.enumerated().map { index, secretID -> String in
        let jump = secretID.map {
            """
            ,"jump":{"host":"bastion.example.com","port":22,\
            "username":"tim","authKind":"password","secretID":"\($0.uuidString)"}
            """
        } ?? ""
        return """
        {"id":"\(UUID().uuidString)","name":"legacy-\(index)",\
        "host":"example.com","port":22,"username":"tim",\
        "authKind":"password"\(jump)}
        """
    }
    return Data("[\(records.joined(separator: ","))]".utf8)
}
```

- [ ] **Step 2: See it fail**

```bash
swift test --filter legacyJumpSecretIDs
```
Expected: FAIL, `value of type 'SessionStore' has no member 'legacyJumpSecretIDs'`.

- [ ] **Step 3: Implement**

In `SessionStore`, next to `migrateFromLegacy()`:

> **Correction 2026-08-09 (Task 1 review, Critical).** The sample code below
> was wrong: `sessions.json` has **two** legacy shapes, and
> `migrateFromLegacy()` handles both — first the container
> `{"groups":…,"sessions":…}` via `try?`, then as a fallback the bare array
> via a hard `try`. Decoding only the array would make the access **throw**
> on every installation with groups — that is, since before 1.0. The
> implementation mirrors `migrateFromLegacy()`. **The property that carries
> the weight here:** the `try?` on the container is only harmless because the
> array attempt after it is a hard `try`; if both were optional, "not
> readable" would collapse back into "no candidates".

```swift
/// Every jump `secretID` in the preserved pre-M23 `sessions.json`, in file
/// order, without duplicates -- the candidate set for M27's sweep.
///
/// This is the only reader of the legacy file besides `migrateFromLegacy`,
/// and it is deliberately narrow: it hands out `secretID`s and nothing else,
/// so the legacy shape does not leak back into the app. The file is read and
/// left alone; M23 keeps it as the downgrade snapshot.
///
/// A MISSING file means a clean install and yields no candidates. A file that
/// is there and cannot be decoded THROWS -- reading it as "no candidates"
/// would make an unreadable disk indistinguishable from a clean one, and the
/// sweep decides what to delete from exactly this answer.
public func legacyJumpSecretIDs() throws -> [UUID] {
    guard FileManager.default.fileExists(
        atPath: legacyFileURL.path(percentEncoded: false)) else { return [] }
    let data = try Data(contentsOf: legacyFileURL)
    let legacy = try JSONDecoder().decode([LegacyStoredSession].self, from: data)
    var seen = Set<UUID>()
    return legacy.compactMap { $0.jump?.secretID }.filter { seen.insert($0).inserted }
}
```

- [ ] **Step 4: See it pass**

```bash
swift test --filter legacyJumpSecretIDs
```
Expected: 5 tests green.

- [ ] **Step 5: Commit**

```bash
git add Sources/macSCPCore/Sessions/SessionStore.swift Tests/macSCPCoreTests/SessionStoreTests.swift
git commit -m "feat(core): expose the legacy file's jump secret ids for the M27 sweep"
```

---

### Task 2: The sweep

**Files:**
- Create: `Sources/macSCPCore/Sessions/LegacyJumpSecretSweep.swift`
- Create: `Tests/macSCPCoreTests/LegacyJumpSecretSweepTests.swift`

**Interfaces:**
- Consumes: `SessionStore.legacyJumpSecretIDs()` from Task 1;
  `SessionStore.all() throws -> [StoredSession]`,
  `LoginSetStore.all() throws -> [LoginSet]`,
  `ManagedKeyStore.all() throws -> [ManagedKey]`,
  `SecretStore.deletePassword(for:) throws`.
- Produces: `LegacyJumpSecretSweep(sessions:loginSets:keys:secrets:)` with
  `run() throws -> Result`, `Result(removed: Int, failed: Int)`.

- [ ] **Step 1: Write the tests**

```swift
@Suite("LegacyJumpSecretSweep")
struct LegacyJumpSecretSweepTests {

    /// The whole point: an id the legacy file names and nothing claims today
    /// is removed.
    @Test func removesAJumpSecretNoRecordClaimsAnyMore() throws { … }

    /// The counterpart, and the more important half: an SSH session kept its
    /// jump through the migration, so its secretID appears in BOTH files.
    @Test func keepsAJumpSecretThatASessionStillClaims() throws { … }

    /// Not "the id we asked about is gone" but "nothing is gone anywhere".
    /// `storedIDs` exists on the double for exactly this.
    @Test func removesNothingElseFromTheSecretStore() throws { … }

    /// The catastrophic case. A session file that cannot be read must not
    /// read as "no session claims anything" -- that would make every live
    /// jump secret a candidate.
    @Test func anUnreadableSessionFileDeletesNothingAndThrows() throws { … }

    @Test func anUnreadableLoginSetFileDeletesNothingAndThrows() throws { … }
    @Test func anUnreadableManagedKeyFileDeletesNothingAndThrows() throws { … }
    @Test func anUnreadableLegacyFileDeletesNothingAndThrows() throws { … }

    /// No legacy file at all is a clean install, not an error.
    @Test func aMissingLegacyFileIsNotAnError() throws { … }

    /// House rule: one failure does not stop the rest (same shape as
    /// removing several known hosts).
    @Test func aFailingDeleteIsCountedAndTheRestStillRun() throws { … }

    /// The sweep must never read a secret -- no access prompts, and no
    /// decision resting on a read that proves nothing when it fails.
    @Test func theSweepNeverReadsASecret() throws { … }

    /// Idempotent: a second run finds the entries gone and reports zero.
    @Test func asecondRunReportsNothingRemoved() throws { … }
}
```

Each test builds real stores over temporary directories plus
`InMemorySecretStore`. For `theSweepNeverReadsASecret`, a double whose
`password(for:)` triggers `Issue.record` — this pattern appears several
times in the repo (e.g. the "reads are forbidden" doubles in
`LoginResolverTests`).

For the unreadable-file tests, per file, the same trick as in Task 1: write
broken JSON.

**Rule for all four abort tests:** after the throw, `secrets.storedIDs`
must be **unchanged**. The throw alone is not enough — it must happen
before the first deletion.

- [ ] **Step 2: See it fail**

```bash
swift test --filter LegacyJumpSecretSweep
```
Expected: FAIL, the type does not exist.

- [ ] **Step 3: Implement**

```swift
/// Removes the Keychain entries the M23 migration left behind.
///
/// M23 dropped a non-SSH session's `jump` when it upgraded the store and said
/// so in `LegacyStoredSession`: the jump's `secretID` named a Keychain entry
/// that nothing referenced afterwards, and the cleanup was deferred to "a
/// separate pass that owns a `SecretStore`". This is that pass.
///
/// **Candidates come from the preserved legacy file, never from the Keychain.**
/// That is what makes the sweep safe rather than merely careful: an entry a
/// future macSCP wrote cannot appear in a file written before M23, so it can
/// never become a candidate. Enumerating the Keychain would have no such
/// guarantee -- everything under the service shares one flat UUID namespace,
/// so session secrets, login-set secrets and key passphrases are
/// indistinguishable from each other and from anything a newer build stores.
///
/// **Every read error aborts before anything is deleted.** A store that reads
/// as empty when it merely failed would leave no id claimed, and every live
/// jump secret would look like an orphan. For the same reason the sweep talks
/// to the stores rather than to a view model: `reload()` turns a failure into
/// empty lists.
///
/// The sweep never calls `password(for:)`. Nothing is read, only deleted, so
/// there are no access prompts and no decision rests on a failing read.
public struct LegacyJumpSecretSweep {
    public struct Result: Equatable, Sendable {
        public var removed: Int
        public var failed: Int
        public init(removed: Int, failed: Int) {
            self.removed = removed
            self.failed = failed
        }
    }

    private let sessions: SessionStore
    private let loginSets: LoginSetStore
    private let keys: ManagedKeyStore
    private let secrets: any SecretStore

    public init(
        sessions: SessionStore, loginSets: LoginSetStore,
        keys: ManagedKeyStore, secrets: any SecretStore
    ) {
        self.sessions = sessions
        self.loginSets = loginSets
        self.keys = keys
        self.secrets = secrets
    }

    public func run() throws -> Result {
        // Order matters: every read happens before the first delete, so a
        // failure anywhere leaves the Keychain untouched.
        let candidates = try sessions.legacyJumpSecretIDs()
        guard !candidates.isEmpty else { return Result(removed: 0, failed: 0) }
        let claimed = try claimedIDs()

        var removed = 0, failed = 0
        for id in candidates where !claimed.contains(id) {
            do {
                try secrets.deletePassword(for: id)
                removed += 1
            } catch {
                // One failure does not stop the rest -- same rule as removing
                // several known hosts. The count is reported; the error is not
                // carried further, because it can only be an OSStatus and the
                // user's next step is the same either way.
                failed += 1
            }
        }
        return Result(removed: removed, failed: failed)
    }

    /// Every id anything still claims. Wider than strictly necessary -- a
    /// pre-M23 jump `secretID` cannot also be a login-set or managed-key id --
    /// and deliberately so: it costs one pass each and makes the rule "delete
    /// only what appears NOWHERE" true without case analysis.
    private func claimedIDs() throws -> Set<UUID> {
        var claimed = Set<UUID>()
        for session in try sessions.all() {
            claimed.insert(session.id)
            if let secretID = session.jump?.secretID { claimed.insert(secretID) }
        }
        for set in try loginSets.all() { claimed.insert(set.id) }
        for key in try keys.all() { claimed.insert(key.id) }
        return claimed
    }
}
```

- [ ] **Step 4: See it pass**

```bash
swift test --filter LegacyJumpSecretSweep
```

- [ ] **Step 5: Run the counter-proof**

Not optional. In sequence, reverting each time:

1. Remove `guard !candidates.isEmpty` and call `claimedIDs()` **after** the
   loop → `anUnreadableSessionFileDeletesNothingAndThrows` must go red.
   Proves that the order is enforced and not accidentally correct.
2. Replace `try sessions.all()` with `(try? sessions.all()) ?? []` → the
   same test must go red. This is the bug the whole milestone is built
   against.

Both red states into the report, then revert cleanly and prove
`git status --porcelain` empty.

- [ ] **Step 6: Commit**

```bash
git add Sources/macSCPCore/Sessions/LegacyJumpSecretSweep.swift Tests/macSCPCoreTests/LegacyJumpSecretSweepTests.swift
git commit -m "feat(core): reap the jump secrets the M23 migration orphaned"
```

---

### Task 3: The button in Settings

**Files:**
- Modify: `Sources/MacSCPApp/SettingsView.swift` (`ManageDataSettingsSection`)
- Modify: `Sources/MacSCPApp/Resources/{en,de,fr,pl}.lproj/Localizable.strings`

**Interfaces:**
- Consumes: `LegacyJumpSecretSweep` from Task 2.

- [ ] **Step 1: Add the four catalogs**

New keys, in **all four** files, in the place of the other `manageData.*`
keys. English as the reference:

```
"manageData.reapSecrets.button" = "Remove leftover credentials…";
"manageData.reapSecrets.explanation" = "Upgrading from version 1.0 could leave credentials in the keychain that nothing uses any more.";
"manageData.reapSecrets.confirmTitle" = "Remove leftover credentials?";
"manageData.reapSecrets.confirmMessage" = "Only credentials no saved connection, login set or key refers to are removed. This action cannot be undone.";
"manageData.reapSecrets.confirmAction" = "Remove";
"manageData.reapSecrets.result" = "Cleanup finished.";
"manageData.reapSecrets.resultFailures %lld" = "Could not be removed: %lld";
"manageData.reapSecrets.failed" = "The leftover credentials could not be checked. Nothing was removed.";
```

German:

```
"manageData.reapSecrets.button" = "Übrige Zugangsdaten entfernen…";
"manageData.reapSecrets.explanation" = "Beim Aufstieg von Version 1.0 können Zugangsdaten im Schlüsselbund geblieben sein, die nichts mehr benutzt.";
"manageData.reapSecrets.confirmTitle" = "Übrige Zugangsdaten entfernen?";
"manageData.reapSecrets.confirmMessage" = "Entfernt werden nur Zugangsdaten, auf die keine gespeicherte Verbindung, kein Login-Set und kein Schlüssel verweist. Das lässt sich nicht rückgängig machen.";
"manageData.reapSecrets.confirmAction" = "Entfernen";
"manageData.reapSecrets.result" = "Aufräumen abgeschlossen.";
"manageData.reapSecrets.resultFailures %lld" = "Nicht entfernt werden konnten: %lld";
"manageData.reapSecrets.failed" = "Die übrigen Zugangsdaten konnten nicht geprüft werden. Es wurde nichts entfernt.";
```

Translate FR and PL accordingly — the same key set, enforced by
`appLayerLanguagesMatchEnglishKeys`.

- [ ] **Step 2: Check the catalogs**

```bash
for f in Sources/MacSCPApp/Resources/*.lproj/Localizable.strings; do plutil -lint "$f"; done
swift test --filter LocalizableStrings
```
Expected: all `OK`, guard test green.

- [ ] **Step 3: Wire in the button**

In `ManageDataSettingsSection`, below the existing links, its own section.
State:

```swift
@State private var confirmingReap = false
@State private var reapResult: String?
```

The button, the dialog after the house pattern, and the report below:

```swift
Button(L10n.string("manageData.reapSecrets.button", "Remove leftover credentials…")) {
    confirmingReap = true
}
.confirmationDialog(
    L10n.string("manageData.reapSecrets.confirmTitle", "Remove leftover credentials?"),
    isPresented: $confirmingReap, titleVisibility: .visible
) {
    Button(
        L10n.string("manageData.reapSecrets.confirmAction", "Remove"),
        role: .destructive, action: runReap)
} message: {
    Text(L10n.string("manageData.reapSecrets.confirmMessage", "…"))
}
if let reapResult { Text(reapResult).font(.callout).foregroundStyle(.secondary) }
```

The call. **The failure case names no cause** — the user cannot draw any
conclusion from an unreadable store file, and the message should above all
say that nothing was removed:

```swift
private func runReap() {
    let sweep = LegacyJumpSecretSweep(
        sessions: SessionStore(directory: SessionStore.defaultDirectory),
        loginSets: LoginSetStore(directory: LoginSetStore.defaultDirectory),
        keys: ManagedKeyStore(directory: ManagedKeyStore.defaultDirectory),
        secrets: KeychainSecretStore())
    do {
        let result = try sweep.run()
        // No removal count, deliberately: `deletePassword` maps
        // `errSecItemNotFound` to success, so `Result.removed` counts
        // successful delete CALLS, not entries that were actually there --
        // and since the legacy file stays as the downgrade snapshot, a second
        // run would report the same number for a keychain that is already
        // clean. A number nobody can trust is worse than none.
        var text = L10n.string("manageData.reapSecrets.result", "Cleanup finished.")
        if result.failed > 0 {
            text += "\n" + String(
                format: L10n.string("manageData.reapSecrets.resultFailures %lld", "Failed: %lld"),
                result.failed)
        }
        reapResult = text
    } catch {
        reapResult = L10n.string("manageData.reapSecrets.failed", "Nothing was removed.")
    }
}
```

**Check the `defaultDirectory` property names before writing** —
`SessionStore.defaultDirectory` exists (`ContentView.swift` uses it); for
the other two stores, look up how `ContentView` constructs them, and use
the same source rather than inventing a path. If something deviates, that
is a finding for the report, not a silent adjustment.

- [ ] **Step 4: Build**

```bash
swift build
swift test
```
Expected: clean including the App target, suite green, count ≥ 1619 + new tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/MacSCPApp
git commit -m "feat(app): offer the leftover-credential cleanup in settings"
```

---

### Task 4: Milestone close

**Files:**
- Create: `docs/superpowers/specs/2026-08-09-m27-closeout.md`

- [ ] **Step 1: Full verification**

```bash
swift build
swift test
```

Docker rig **from the main checkout**, never from a worktree:

```bash
docker compose -f docker/test-server/compose.yml up -d
MACSCP_ITEST=1 swift test
MACSCP_KEYCHAIN=1 swift test --filter Keychain
```

If a run stalls at 0% CPU, that is the hang known since M20
(`2026-08-08-testsuite-hang-investigation.md`) — abort, restart, note it
in the report, do **not** count it as an M27 finding. Afterward check for
orphans with `pgrep -fl swiftpm-testing-helper`.

Catalogs:

```bash
for f in Sources/MacSCPApp/Resources/*.lproj/Localizable.strings Sources/macSCPCore/Resources/*.lproj/Localizable.strings; do plutil -lint "$f"; done
```

- [ ] **Step 2: The counter-proof on the protocol**

Prove that the `SecretStore` protocol is **unchanged** — the spec's promise
that none of the twelve conformances had to be touched:

```bash
git diff 05a1811..HEAD -- Sources/macSCPCore/Sessions/SecretStore.swift
```

Expected: empty. An empty diff is real evidence here, because a protocol
change would necessarily show in this file — unlike a grep, whose empty
result proves nothing.

- [ ] **Step 3: Write the report**

Shape of `2026-08-08-m26-closeout.md`. Must contain: the verification
with numbers; the spec's eleven success criteria with **evidence rather
than assertion**; the two red states of the counter-proof from Task 2 Step
5 verbatim; the two decisions that were reverted during implementation
(the raw-file route as a belt rather than a load-bearing wall; the audit
entry the session-bound log cannot hold) with what they say about the
approach; what remains open (a stale secret in login-set mode,
managed-key rollback orphans, an app-wide audit); and the number of
unpushed commits (`git rev-list --count origin/develop..develop`).

- [ ] **Step 4: Commit, do not push**

```bash
git add docs/superpowers/specs/2026-08-09-m27-closeout.md
git commit -m "docs(m27): record the milestone close"
```

The push happens only on the maintainer's explicit order.

---

## Plan self-review

**Spec coverage.** Criterion 1–2 → T2/Step 1 (the first two tests);
3 → T2/Step 1 (`anUnreadableSessionFileDeletesNothingAndThrows`) and T2/Step 5
(the counter-proof that arms it); 4 → T2/Step 3, signature takes stores,
no ViewModel; 5 → T1/Step 1 and the three unreadable-file tests in T2;
6 → T1 and T2, one test each; 7 → T2 `theSweepNeverReadsASecret`; 8 → T2
`aFailingDeleteIsCountedAndTheRestStillRun`; 9 → T1
`readingLegacyJumpSecretIDsLeavesTheFileByteIdentical`; 10 → T3, the report
only formats numbers; 11 → T3/Step 2.

**Type consistency.** `LegacyStoredSession.jump` is `StoredSession.JumpSpec?`
with `secretID: UUID`; `StoredSession.jump` is `ssh?.jump`, likewise
`JumpSpec?`. Both sides read the same property.

**Two deliberate unclarities, disclosed rather than hidden:**

1. **I did not verify the `defaultDirectory` names for `LoginSetStore` and
   `ManagedKeyStore`.** `SessionStore.defaultDirectory` is confirmed; for
   the other two, the plan says where to look instead of inventing a name
   the implementer would then trust. A plan line I have not checked is a
   hypothesis — and this one is marked as such.
2. **The test bodies in Task 2 Step 1 are names plus doc comments, not
   finished code.** That is deliberate here: each of these tests builds
   three real stores over temporary directories, and the helpers for that
   already exist in the current suites. Fully written bodies would be the
   same setup eleven times over, which the implementer would consolidate
   in one place anyway. What the plan does **not** leave open is what each
   test has to prove — that is in the doc comment, and Step 5 pins the two
   most important ones by mutation.
