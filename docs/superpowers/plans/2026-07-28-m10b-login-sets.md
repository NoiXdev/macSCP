# M10b — Login Sets Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reusable, named logins (username + password OR key), referenceable from connections, with a management sheet (⌘⇧L), a three-way choice in the form, and a merge suggestion for identical existing logins; deleting a set losslessly restores affected connections to Manual.

**Architecture:** `LoginSet` (Core) with its own `LoginSetStore` (`logins.json`, record-based for forward compatibility), `StoredSession.loginSetID` (decode-compatible like `groupID`), `LoginResolver` as a pure resolution function, `LoginMergePlanner` as a pure grouping function; all mutating flows (CRUD, delete restoration, merge application, export resolution) live in `SessionListViewModel`, which already owns SessionStore + SecretStore. The app wires up the sheet, the menu, and the three-way form.

**Tech Stack:** Swift 6 / `.swiftLanguageMode(.v5)`, Swift Testing, SwiftUI, macOS Keychain via the existing `SecretStore`.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-28-m10b-login-sets-design.md` — binding. Mockup: `docs/design/assets/m10-mockups.html` sections 3+4. Branch: **develop**.
- Secrets NEVER in JSON — the set's password/passphrase lives in the keychain UNDER THE SET UUID via the existing `SecretStore` (`savePassword/password/deletePassword` are UUID-addressed; no protocol change).
- Forward compatibility for `logins.json`: a record with an unknown `authKind` raw value (future `agent`, M10d) is NEVER delivered by `all()` (never misread as a password set), but survives upsert/delete of OTHER entries in the file.
- `StoredSession.loginSetID: UUID?` optional WITHOUT a custom decoder (exactly the `groupID` pattern) — legacy JSON reads as nil.
- A missing referenced set at connect time = HONEST error, no silent fallback.
- Ignoring a merge persists ONLY sets of session IDs — never passwords, hashes, or anything derived from them.
- All new UI text EN/DE (`L10n.string`, both catalogs); code + comments English ONLY; no new dependencies.
- Conventional Commits (English), footer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- `swift build` + the full `swift test` green after every task (starting point 475 tests / 37 suites); gated suites only in T4; tests run SYNCHRONOUSLY in the foreground; TDD red→green for Core.
- NO release, no merge to main — the milestone ends with a push to develop.

## Schedule

T1 (Core: LoginSet + Store + loginSetID + Resolver) → T2 (Core: MergePlanner + SessionListViewModel APIs + export resolution) → T3 (App: sheets + menu + three-way + connect wiring) → T4 wrap-up (coordinator).

---

### Task 1: LoginSet + LoginSetStore + loginSetID + LoginResolver (Core)

**Files:**
- Create: `Sources/macSCPCore/Sessions/LoginSetStore.swift`
- Create: `Sources/macSCPCore/Sessions/LoginResolver.swift`
- Modify: `Sources/macSCPCore/Sessions/StoredSession.swift`
- Test: `Tests/macSCPCoreTests/LoginSetStoreTests.swift` (new), `Tests/macSCPCoreTests/LoginResolverTests.swift` (new)

**Interfaces:**
- Consumes: `StoredSession.AuthKind` (existing), `SecretStore` protocol (existing, UUID-addressed), `InMemorySecretStore` (existing test double in `Tests/macSCPCoreTests/InMemorySecretStore.swift`).
- Produces (T2/T3 rely on this exactly):
  - `LoginSet` (`id: UUID`, `name: String`, `username: String`, `authKind: StoredSession.AuthKind`, `keyPath: String?`; init with defaults `id: UUID = UUID()`, `authKind: .password`, `keyPath: nil`)
  - `LoginSetStore(directory: URL)`: `all() throws -> [LoginSet]` (name-sorted, case-insensitive), `upsert(_:) throws`, `delete(id:) throws`, `ignoredMergeGroups() throws -> [Set<UUID>]`, `addIgnoredMergeGroup(_: Set<UUID>) throws`
  - `StoredSession.loginSetID: UUID?` (public var, init parameter with default nil)
  - `ResolvedLogin` (`username: String`, `authKind: StoredSession.AuthKind`, `keyPath: String?`, `secret: String?`)
  - `LoginResolver.resolve(session:sets:secrets:) throws -> ResolvedLogin?` and `LoginResolveError.missingSet`

- [x] **Step 1: Write failing tests** (`LoginSetStoreTests.swift` + `LoginResolverTests.swift`; adopt the fixture pattern from `KnownHostsStoreTests` — temp directory per test):

```swift
    // LoginSetStoreTests:
    // upsertAndAllRoundtrip: upsert two sets ("Web", "Admin") ->
    //   all() returns both, name-sorted case-insensitively ["Admin", "Web"];
    //   field values (username/authKind/keyPath) are preserved.
    // upsertReplacesById: upsert a set, change the name, upsert again ->
    //   all().count == 1, new name.
    // deleteRemovesOnlyMatch: two sets, delete(id: first.id) ->
    //   only the second remains; delete of an unknown id does not throw.
    // emptyDirectoryReadsEmpty: all() on an empty directory == [].
    // unknownAuthKindIsHiddenButPreserved: write raw JSON with three records
    //   directly to logins.json (reproducing the file format),
    //   one of them with "authKind": "agent" -> all() returns only the two
    //   known ones; afterwards upsert a NEW set and delete
    //   one of the known ones -> the file's raw JSON still contains
    //   the "agent" record (a string-contains check on "agent" suffices).
    // ignoredMergeGroupsRoundtrip: addIgnoredMergeGroup([a, b]) ->
    //   ignoredMergeGroups() == [Set([a, b])]; append a second group ->
    //   both present; empty directory -> [].
    //
    // LoginResolverTests:
    // manualSessionResolvesNil: session.loginSetID == nil ->
    //   resolve(...) == nil (caller uses the session's own data).
    // setSessionResolvesFromSet: set (user "deploy", .privateKey,
    //   keyPath "/k"), secret "pp" in InMemorySecretStore under set.id;
    //   session with loginSetID = set.id -> ResolvedLogin(username: "deploy",
    //   authKind: .privateKey, keyPath: "/k", secret: "pp").
    // missingSecretResolvesNilSecret: no keychain entry -> secret == nil,
    //   remaining fields come from the set.
    // missingSetThrows: loginSetID points at an unknown UUID ->
    //   #expect(throws: LoginResolveError.missingSet).
    // legacySessionJSONDecodesNilLoginSetID: load a raw sessions.json WITHOUT
    //   a loginSetID field (reproducing the format) through SessionStore ->
    //   loginSetID == nil. (Belongs logically to StoredSession; test it
    //   here alongside instead of in a third file.)
```

- [x] **Step 2: Prove red.** `swift test --filter LoginSetStoreTests` and `--filter LoginResolverTests` → FAIL (types do not exist).

- [x] **Step 3: Implementation.**

`StoredSession.swift` — exactly the `groupID` pattern (no custom decoder):

```swift
    /// The login set this session's credentials come from, if any (M10b).
    /// Optional so legacy JSON without this field keeps decoding as `nil`
    /// (nil = the session carries its own credentials, "manual" mode).
    public var loginSetID: UUID?
    // Init: loginSetID: UUID? = nil as the last parameter, assign it.
```

`LoginSetStore.swift`:

```swift
import Foundation

/// A reusable, named login (M10b): username plus either a keychain-held
/// password or a private key path (with a keychain-held passphrase).
/// Contains NO secrets — those live in the SecretStore under `id`.
public struct LoginSet: Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var username: String
    public var authKind: StoredSession.AuthKind
    /// Path to the private key (only set when authKind == .privateKey).
    public var keyPath: String?

    public init(
        id: UUID = UUID(), name: String, username: String,
        authKind: StoredSession.AuthKind = .password, keyPath: String? = nil
    ) { … }
}

/// JSON persistence for login sets (`logins.json`), following the
/// SessionStore pattern: stateless, atomic writes.
///
/// Forward compatibility: entries are persisted as raw records whose
/// `authKind` is a plain string. A record with an UNKNOWN raw (e.g. a
/// future "agent" set written by a newer app version, M10d) is never
/// surfaced by `all()` — it must not be misread as a password set — but
/// it survives upsert/delete of other entries untouched.
public struct LoginSetStore: Sendable {
    private struct Record: Codable {
        var id: UUID
        var name: String
        var username: String
        var authKind: String
        var keyPath: String?
    }
    private struct StoreFile: Codable {
        var sets: [Record] = []
        var ignoredMergeGroups: [[UUID]] = []
    }

    private let directory: URL
    public init(directory: URL) { self.directory = directory }
    private var fileURL: URL { directory.appendingPathComponent("logins.json") }

    private func load() throws -> StoreFile {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
            return StoreFile()
        }
        return try JSONDecoder().decode(StoreFile.self, from: Data(contentsOf: fileURL))
    }

    private func persist(_ file: StoreFile) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(file).write(to: fileURL, options: .atomic)
    }

    /// All sets with a KNOWN auth kind, name-sorted case-insensitively.
    public func all() throws -> [LoginSet] {
        try load().sets.compactMap { record in
            guard let kind = StoredSession.AuthKind(rawValue: record.authKind) else { return nil }
            return LoginSet(id: record.id, name: record.name, username: record.username,
                            authKind: kind, keyPath: record.keyPath)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func upsert(_ set: LoginSet) throws {
        var file = try load()
        let record = Record(id: set.id, name: set.name, username: set.username,
                            authKind: set.authKind.rawValue, keyPath: set.keyPath)
        if let index = file.sets.firstIndex(where: { $0.id == set.id }) {
            file.sets[index] = record
        } else {
            file.sets.append(record)
        }
        try persist(file)
    }

    public func delete(id: UUID) throws {
        var file = try load()
        file.sets.removeAll { $0.id == id }
        try persist(file)
    }

    /// Persisted "don't suggest merging these again" groups (M10b spec §4):
    /// plain session-ID sets — deliberately never passwords or anything
    /// derived from them.
    public func ignoredMergeGroups() throws -> [Set<UUID>] {
        try load().ignoredMergeGroups.map(Set.init)
    }

    public func addIgnoredMergeGroup(_ sessionIDs: Set<UUID>) throws {
        var file = try load()
        file.ignoredMergeGroups.append(Array(sessionIDs).sorted { $0.uuidString < $1.uuidString })
        try persist(file)
    }
}
```

`LoginResolver.swift`:

```swift
import Foundation

/// Thrown when a session references a login set that no longer exists —
/// the connect must fail honestly instead of silently guessing (spec §2).
public enum LoginResolveError: Error, Equatable {
    case missingSet
}

/// Credentials resolved from a login set: what the connect flow needs to
/// fill the connection form. `secret` is the set's keychain entry
/// (password, or key passphrase for .privateKey), nil when absent.
public struct ResolvedLogin: Equatable, Sendable {
    public var username: String
    public var authKind: StoredSession.AuthKind
    public var keyPath: String?
    public var secret: String?
    public init(username: String, authKind: StoredSession.AuthKind,
                keyPath: String?, secret: String?) { … }
}

public enum LoginResolver {
    /// Resolves a session's login: `nil` for manual sessions
    /// (loginSetID == nil — the caller uses the session's own data),
    /// the set's credentials otherwise. A dangling reference throws.
    public static func resolve(
        session: StoredSession, sets: [LoginSet], secrets: any SecretStore
    ) throws -> ResolvedLogin? {
        guard let setID = session.loginSetID else { return nil }
        guard let set = sets.first(where: { $0.id == setID }) else {
            throw LoginResolveError.missingSet
        }
        let secret = (try? secrets.password(for: set.id)) ?? nil
        return ResolvedLogin(username: set.username, authKind: set.authKind,
                             keyPath: set.keyPath, secret: secret)
    }
}
```

- [x] **Step 4: Green + full suite.** `swift test` → 475 + new (record the real number), 0 failures.

- [x] **Step 5: Commit.** `feat: add login sets with store, session reference and resolver`

---

### Task 2: LoginMergePlanner + SessionListViewModel APIs + export resolution (Core)

**Files:**
- Create: `Sources/macSCPCore/Sessions/LoginMergePlanner.swift`
- Modify: `Sources/macSCPCore/Presentation/SessionListViewModel.swift`
- Test: `Tests/macSCPCoreTests/LoginMergePlannerTests.swift` (new), `Tests/macSCPCoreTests/SessionListViewModelTests.swift` (extend)

**Interfaces:**
- Consumes (T1): `LoginSet`, `LoginSetStore` (signatures see T1), `StoredSession.loginSetID`, `LoginResolver.resolve(session:sets:secrets:)`, `ResolvedLogin`, `LoginResolveError.missingSet`; existing: `SecretStore`, `SessionListViewModel` (store/secrets/reload/exportPayload), `InMemorySecretStore`.
- Produces (T3 relies on this exactly):
  - `LoginMergeCandidate` (`username: String`, `authKind: StoredSession.AuthKind`, `keyPath: String?`, `sessionIDs: [UUID]`)
  - `LoginMergePlanner.candidates(sessions:ignoredGroups:secrets:) -> [LoginMergeCandidate]`
  - `SessionListViewModel`: `loginSets: [LoginSet]` (published, loaded along in `reload()`), `saveLoginSet(_ set: LoginSet, secret: String?)`, `usageCount(of setID: UUID) -> Int`, `sessionsUsing(setID: UUID) -> [StoredSession]`, `deleteLoginSet(_ set: LoginSet) -> LoginSetDeleteResult`, `mergeCandidates() -> [LoginMergeCandidate]`, `applyMerge(_ candidate: LoginMergeCandidate, name: String) -> LoginSet?`, `ignoreMerge(_ candidate: LoginMergeCandidate)`, `resolvedLogin(for session: StoredSession) throws -> ResolvedLogin?`, `suggestedSetName(forUsername username: String) -> String`, extended `save(... loginSetID: UUID? = nil)`
  - `LoginSetDeleteResult` (`restored: Int`, `secretFailures: Int`, Equatable)

**Behavioral requirements (spec §3/§4/§5, binding):**
1. Planner: ONLY sessions with `loginSetID == nil` participate. privateKey groups: same (username, keyPath). password groups: same username AND identical keychain password VALUE (in-memory comparison; a session without a stored password does not participate). Only groups ≥ 2. A candidate is suppressed when its session-ID set is a SUBSET of an ignored group (a new member ⇒ no longer a subset ⇒ reactivated). Deterministic order (username-sorted; sessionIDs in the input session order).
2. `deleteLoginSet`: for each affected session, copy back username/authKind/keyPath from the set, copy the set's secret into the session's keychain entry (only when present), `loginSetID = nil`, upsert; a keychain failure for one session counts (`secretFailures`) instead of aborting — the session is STILL restored (values + nil reference), only its secret is missing. Afterwards delete the set + the set's secret, `reload()`.
3. `applyMerge`: create a set (name parameter; collision handling supplies `suggestedSetName` BEFORE the call, see below), copy the secret of the FIRST group session under the set ID (for `.password`; for `.privateKey` the passphrase likewise), set `loginSetID` on all group sessions, delete the session secrets after the successful switch-over (throw-free via `try?` — a deletion failure is a harmless leftover, never an abort), `reload()`. A store failure when creating the set ⇒ nil + `errorMessage`, nothing switched over.
4. `suggestedSetName(forUsername:)`: base = username; if the name collides case-insensitively with an existing set, append " (2)", " (3)" … (the pattern of the file-conflict names).
5. `save(... loginSetID:)`: non-nil ⇒ the session references the set and NO session secret is written (the `password` argument is ignored); nil ⇒ today's behavior unchanged.
6. `exportPayload`: for sessions with a set, username/authKind/keyPath and (when `includePasswords`) the password are exported resolved from the SET; a missing set secret counts in `missingPasswordCount`; a missing SET exports the session with its (empty) own values — export never aborts. Export format unchanged v1.
7. `reload()` loads `loginSets` along with everything else (store failure ⇒ empty list, existing errorMessage pattern).

- [x] **Step 1: Failing tests** (planner file new; VM tests in the existing pattern with temp SessionStore + InMemorySecretStore + LoginSetStore on the same temp directory):

```swift
    // LoginMergePlannerTests:
    // groupsByUsernameAndKeyPath: 3 key sessions (2x deploy//k1, 1x deploy//k2)
    //   -> exactly one candidate (deploy, .privateKey, /k1) with 2 IDs.
    // groupsByUsernameAndPasswordValue: 3 password sessions user "root",
    //   secrets "a"/"a"/"b" -> one candidate with the two "a" sessions.
    // sessionWithoutStoredPasswordExcluded: session without a keychain entry
    //   -> does not participate (no candidate from it).
    // sessionWithSetExcluded: session with loginSetID != nil -> does not participate.
    // singletonGroupsSuppressed: only 1 session per key -> [].
    // ignoredGroupSuppressesSubset: candidate {a,b}; ignoredGroups [{a,b}]
    //   -> []; ignoredGroups [{a,b,c}] (superset) -> also suppressed.
    // newMemberReactivates: ignoredGroups [{a,b}], candidate {a,b,c}
    //   -> candidate appears.
    //
    // SessionListViewModelTests (additions):
    // saveWithLoginSetSkipsSessionSecret: save(..., loginSetID: set.id)
    //   -> the session has loginSetID, secrets.password(for: session.id) == nil.
    // deleteLoginSetRestoresSessions: set (user/key + passphrase "pp"),
    //   2 sessions reference it -> deleteLoginSet: both sessions
    //   carry the set's username/authKind/keyPath, loginSetID == nil,
    //   session secret == "pp", set gone, set secret gone,
    //   result restored == 2, secretFailures == 0.
    // deleteLoginSetCountsSecretFailure: SecretStore double whose
    //   savePassword throws for one specific session ID (small local
    //   double in the test, InMemory-based) -> restored == 2,
    //   secretFailures == 1, BOTH sessions are still restored.
    // applyMergeCreatesSetAndRewires: 2 password sessions "root"/"a" ->
    //   applyMerge(candidate, name: "root"): the set exists (user root,
    //   .password), set secret == "a", both sessions loginSetID == set.id,
    //   session secrets deleted.
    // suggestedSetNameAvoidsCollision: sets "root", "root (2)" exist
    //   -> suggestedSetName(forUsername: "root") == "root (3)";
    //   without collision == "root".
    // ignoreMergePersists: ignoreMerge(candidate) -> mergeCandidates()
    //   no longer returns it (via LoginSetStore.ignoredMergeGroups).
    // exportResolvesLoginSet: session with a set (user "deploy", password "s")
    //   -> exportPayload(all, includePasswords: true): ExportedSession
    //   carries username "deploy", password "s"; a missing set secret
    //   counts in missingPasswordCount.
    // resolvedLoginMissingSetThrows: session with a dangling loginSetID ->
    //   #expect(throws:) on resolvedLogin(for:).
```

- [x] **Step 2: Prove red.** `swift test --filter LoginMergePlannerTests` and `--filter SessionListViewModelTests` → FAIL.

- [x] **Step 3: Implementation.**

`LoginMergePlanner.swift`:

```swift
import Foundation

/// A group of manual sessions sharing the same effective login (M10b spec
/// §4) — the "merge into one set?" suggestion the UI banners.
public struct LoginMergeCandidate: Equatable, Sendable {
    public var username: String
    public var authKind: StoredSession.AuthKind
    public var keyPath: String?
    public var sessionIDs: [UUID]
}

/// Pure equality detection over MANUAL sessions (loginSetID == nil).
/// Password values are compared in memory only and never leave this
/// function; sessions without a stored password do not participate.
public enum LoginMergePlanner {
    public static func candidates(
        sessions: [StoredSession], ignoredGroups: [Set<UUID>], secrets: any SecretStore
    ) -> [LoginMergeCandidate] {
        // Group into a dictionary with a struct key
        //   GroupKey { username; kind; keyPath: String?; password: String? }
        // (Hashable, file-private):
        //   .privateKey -> keyPath set, password nil
        //   .password   -> password = (try? secrets.password(for: id)),
        //                  SKIP PARTICIPATION on nil
        // Only groups with count >= 2. Suppress when
        //   ignoredGroups.contains(where: { Set(ids).isSubset(of: $0) }).
        // Result username-sorted (on ties keyPath, then count);
        // sessionIDs in the input order of the sessions.
    }
}
```

`SessionListViewModel` additions (existing pattern: `do/catch` + `reload()` + `errorMessage` via `CoreL10n`; add three new CoreL10n keys following the existing style, e.g. `core.login.saveFailed %@`, `core.login.deleteFailed %@`, `core.login.mergeFailed %@`, EN/DE in both Core catalogs):

```swift
    // New stored property + init parameter (defaulted, no breakage for callers):
    public private(set) var loginSets: [LoginSet] = []
    private let loginSetStore: LoginSetStore
    // Init parameter (defaulted like auditStore):
    //   loginSetStore: LoginSetStore =
    //     LoginSetStore(directory: SessionStore.defaultDirectory)
    // reload(): add loginSets = (try? loginSetStore.all()) ?? [].

    public struct LoginSetDeleteResult: Equatable {
        public var restored: Int
        public var secretFailures: Int
        public init(restored: Int, secretFailures: Int) { … }
    }

    public func sessionsUsing(setID: UUID) -> [StoredSession] {
        sessions.filter { $0.loginSetID == setID }
    }
    public func usageCount(of setID: UUID) -> Int { sessionsUsing(setID: setID).count }

    /// Saves a set; a non-nil, non-empty secret overwrites the keychain
    /// entry under the SET id (nil/empty keeps it — the editor's
    /// "unchanged" prompt semantics, same as updateSession).
    public func saveLoginSet(_ set: LoginSet, secret: String?)

    /// Spec §3 "delete = restoration": every referencing session gets the
    /// set's username/authKind/keyPath copied back, the set's secret copied
    /// into ITS keychain slot, loginSetID nilled. A keychain failure for
    /// one session is counted, never aborts — the session is still
    /// restored, only its secret is missing. Afterwards the set and its
    /// secret are removed.
    public func deleteLoginSet(_ set: LoginSet) -> LoginSetDeleteResult

    public func mergeCandidates() -> [LoginMergeCandidate] {
        LoginMergePlanner.candidates(
            sessions: sessions,
            ignoredGroups: (try? loginSetStore.ignoredMergeGroups()) ?? [],
            secrets: secrets)
    }
    public func ignoreMerge(_ candidate: LoginMergeCandidate)   // addIgnoredMergeGroup(Set(ids))
    public func applyMerge(_ candidate: LoginMergeCandidate, name: String) -> LoginSet?
    public func suggestedSetName(forUsername username: String) -> String
    public func resolvedLogin(for session: StoredSession) throws -> ResolvedLogin? {
        try LoginResolver.resolve(session: session, sets: loginSets, secrets: secrets)
    }
    // save(...): add parameter loginSetID: UUID? = nil; assign it in
    // both branches; only write the secret in the nil case.
    // exportPayload: for each session, first try? resolvedLogin(for:) —
    // a non-nil ResolvedLogin replaces username/authKind/keyPath and (when
    // includePasswords) the password; nil/throw => today's path.
```

- [x] **Step 4: Green + full suite.** `swift test` → T1 state + new, 0 failures.

- [x] **Step 5: Commit.** `feat: add login merge planning and set lifecycle to the session view model`

---

### Task 3: Logins sheet + editor + menu + three-way form + connect wiring (App)

**Files:**
- Create: `Sources/MacSCPApp/LoginSetsSheet.swift` (list + merge banner + editor sub-sheet)
- Modify: `Sources/MacSCPApp/MacSCPApp.swift` (Sessions menu: "Logins…" ⌘⇧L), `Sources/MacSCPApp/ContentView.swift` (sheet state + TabCommands closure + connect resolution + save path), `Sources/MacSCPApp/SessionSidebar.swift` (background menu entry), `Sources/MacSCPApp/ConnectionFormView.swift` (three-way auth block), `Sources/macSCPCore/Presentation/ConnectionViewModel.swift` (form fields), `Sources/MacSCPApp/Resources/en.lproj/Localizable.strings` + `de.lproj`
- Test: none (app target; smoke test in T4). The ConnectionViewModel fields are plain stored properties — no dedicated test needed.

**Interfaces:**
- Consumes (T1/T2, exactly): `SessionListViewModel.loginSets/saveLoginSet/deleteLoginSet/usageCount/sessionsUsing/mergeCandidates/applyMerge/ignoreMerge/suggestedSetName/resolvedLogin/save(... loginSetID:)`, `LoginSet`, `LoginMergeCandidate`, `LoginSetDeleteResult`, `LoginResolveError.missingSet`; existing: `TabCommands` bridge (M8a/M10a pattern `showKnownHosts`), `KnownHostsSheet` as the shape template, `ConnectionViewModel` form fields, `connect(in:stored:)` in ContentView.

**Behavioral requirements (spec §2/§3/§5 + mockup section 3, binding):**
1. `LoginSetsSheet(sessionList: SessionListViewModel)` (~720 pt, shaped like `KnownHostsSheet`): rows per mockup — KEY/PASS badge (badge look taken from `keyTypeBadge`), set name, `user · SSH key (~/path)` or `user · password` short form, on the right the usage count `L10n` "%lld connections"/"%lld Verbindungen" (singular "1 connection" via two keys `loginSets.usage.one`/`loginSets.usage.many %lld`). Footer: "New…", "Edit…" (single selection), "Delete…" (destructive), "Close". Merge banner AT THE TOP when `mergeCandidates()` is non-empty: text names the username + count ("N connections use the same login 'user'"), buttons "Ignore" (ignoreMerge, banner disappears) and "Merge…" — confirmation dialog lists the session NAMES (resolved via sessionIDs) + target set name (`suggestedSetName`), confirming calls `applyMerge`. Multiple candidates: show the first, let the rest advance after an action.
2. Editor sub-sheet (new/edit): name, username, segments Password|SSH key (pattern of the connection form: SecureField with a "leave empty to keep" prompt when editing, key path + "Choose…" fileImporter + passphrase SecureField). "Save" disabled until name+username are non-empty (trimmed). Saving → `saveLoginSet(set, secret: input.isEmpty ? nil : input)`.
3. Deletion: `confirmationDialog`, message names `usageCount` and states that affected connections get their data stored directly again (EN "%lld connections will keep these credentials stored directly again." / DE "%lld Verbindungen erhalten diese Zugangsdaten wieder direkt hinterlegt."); `secretFailures > 0` ⇒ red message in the sheet (pattern `knownHosts.removeError`).
4. Menu + entry points: Sessions menu entry "Logins…" ⌘⇧L (TabCommands closure `showLogins`, key-window guard like `showKnownHosts`); sidebar background menu "Logins…" directly under "Known Hosts…"; in the form's set mode a "Manage logins…" link (opens the same sheet locally, pattern of the TOFU footnote from M10a).
5. Three-way in the form (mockup section 3, lower sheet): above today's auth block, a segmented control `Login set | Manual`. Set mode: picker over `sessionList.loginSets` (display "Name — user"), replaces the username/password/key fields entirely; below it the "Manage logins…" link. Manual mode: today's fields + toggle "Save as new login set" + name field (prompt = `suggestedSetName(forUsername:)` live). New `ConnectionViewModel` fields: `loginMode` (`enum LoginMode: String, CaseIterable, Sendable { case set, manual }`, default `.manual`), `selectedLoginSetID: UUID?`, `saveAsNewLoginSet: Bool = false`, `newLoginSetName: String = ""`. Form validation: set mode requires `selectedLoginSetID != nil` instead of username/password.
6. Connect wiring in ContentView:
   - Form connect in set mode: before `form.connect()`, resolve the set (`loginSets` + keychain via `resolvedLogin` for a synthetic session OR directly: the set from `sessionList.loginSets`, secret via `sessionList` — the smaller solution: a small helper function `fillForm(from set: LoginSet)` sets username/authChoice/keyPath/password from the set + a keychain read). Save path: `save(..., loginSetID: form.selectedLoginSetID)` in set mode; in manual mode with "Save as new login set" active, FIRST `saveLoginSet` (name from the field, empty ⇒ `suggestedSetName`), then `save(..., loginSetID: newSet.id)`.
   - `connect(in:stored:)`: `try sessionList.resolvedLogin(for: stored)` — non-nil ⇒ fill the form from `ResolvedLogin` (instead of the session's own values); `LoginResolveError.missingSet` ⇒ do NOT connect, show the form with the error message `loginSets.missingSet` (EN "The stored login for this connection was not found. Choose a login or enter credentials." / DE "Das hinterlegte Login dieser Verbindung wurde nicht gefunden. Login wählen oder Zugangsdaten eingeben.") — via the form's existing error field.
   - Form edit mode: `loginSetID` set ⇒ `loginMode = .set` + preselection; otherwise `.manual` (today's prefill).
7. All new keys EN/DE in BOTH catalogs; cross-check with grep. Suggestion: `menu.logins`, `loginSets.title`, `loginSets.usage.one`, `loginSets.usage.many %lld`, `loginSets.new`, `loginSets.edit`, `loginSets.delete`, `loginSets.delete.title`, `loginSets.delete.message %lld`, `loginSets.delete.confirm`, `loginSets.deleteError %lld`, `loginSets.empty`, `loginSets.merge.banner %lld %@`, `loginSets.merge.ignore`, `loginSets.merge.action`, `loginSets.merge.confirmTitle`, `loginSets.merge.confirm`, `loginSets.editor.titleNew`, `loginSets.editor.titleEdit`, `loginSets.editor.name`, `loginSets.editor.username`, `loginSets.editor.keepSecret`, `loginSets.missingSet`, `form.loginMode.set`, `form.loginMode.manual`, `form.selectLogin`, `form.manageLogins`, `form.saveAsSet`, `form.saveAsSet.name` (finalize the list during implementation).

- [x] **Step 1:** ConnectionViewModel fields + three-way UI in the form. **Step 2:** LoginSetsSheet + editor + merge banner. **Step 3:** menu/sidebar/TabCommands + ContentView wiring (connect resolution, save paths, missingSet error). **Step 4:** localization keys + grep cross-check both catalogs. **Step 5:** `swift build` (0 errors, no new warnings) + full `swift test` (T2 state). **Step 6:** commit `feat: add reusable login sets with form picker and merge suggestions`.

---

### Task 4: Final verification (coordinator)

- [x] Gated suites: Docker rig `start` (main checkout), `MACSCP_ITEST=1 MACSCP_KEYCHAIN=1 swift test` → all tests, zero skips; rig `stop`.
- [ ] Visual smoke — delegated to the maintainer (checklist in the summary: sheet ⌘⇧L, create/edit a set, three-way in the form, merge banner with two identical logins, delete a set ⇒ connections keep working, connect via a set).
- [x] Plan checkboxes, ledger, Opus final review (review package via `git merge-base`), a fix round if needed, push develop, `gh run watch`, memory update, summary. NO release.
