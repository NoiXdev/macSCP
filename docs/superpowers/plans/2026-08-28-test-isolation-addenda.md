# Test isolation: the three follow-ups — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** No test can accidentally read or write a real store, and no check reports success about something it is not actually looking at.

**Basis:** `docs/superpowers/specs/2026-08-22-backlog-test-isolation.md` — that entry is also the design; it names the finding and the fix for each of the three follow-ups.

**The main finding is already done:** `ContentView` has gotten its test seam (`sessionListViewModel:`, `secretStore:`, `managedKeyStore:`). What remains open are the three follow-ups.

## Global Constraints

- Code, comments, identifiers, test names, commit messages: **English only**.
- Conventional Commits; footer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- **No mutation attempt that can reach a real credentials, session, or
  configuration store.** That is the rule this very entry established, and
  it applies to the implementation just the same.
- **Isolation is demonstrated, not claimed.** Whoever says a test no longer
  writes to the real file shows it — file before, suite run, file after.
- **No line numbers, no location references in comments.** Every number
  and every enumeration is counted in the same pass that writes it.
- All six targets are set to `.swiftLanguageMode(.v6)`; **CI goes red as
  soon as the count of distinct warning sites exceeds 1.**
- One scratch path, deleted after use.
- The app is not launched, nothing is pushed.

---

### Task 1: Remove the default values from `SessionListViewModel.init`

**Files:**
- Modify: `Sources/macSCPCore/Presentation/SessionListViewModel.swift`,
  `Sources/MacSCPAppKit/ContentView.swift`, and the test files that
  construct it
- Test: the existing suites; plus a demonstration (see step 4)

**The measured current state:** `init` carries three default values that
point at the real directories:

```swift
auditStore: AuditLogStore = AuditLogStore(directory: AuditLogStore.defaultDirectory),
loginSetStore: LoginSetStore = LoginSetStore(directory: SessionStore.defaultDirectory),
keys: ManagedKeyStore = ManagedKeyStore(directory: SessionStore.defaultDirectory)
```

and `init` calls `reload()`. A test that omits a store thereby reads a real
user file.

**On the count:** the backlog entry names **16** constructions without
`loginSetStore:` and **51** without `auditStore:`, of which **8** are
followed by `vm.delete(...)`. These numbers are from 2026-08-25. **Count
them yourself** — and do not count with a single-line `grep`: the
arguments often sit on the following lines, a single-line search counts
wrong. (I got this wrong myself, first, while writing the plan.)

**The only production site** is `ContentView`, where the model is built
with `sessionListViewModel ?? SessionListViewModel(...)` — that site must
pass the three stores through explicitly afterward.

- [ ] **Step 1: Count and write it down.** How many construction sites
  there are, how many are missing each store, and how many of those go on
  to write (`vm.delete`, `vm.save`, …). The numbers go into the report.
- [ ] **Step 2: Remove the three default values.** After this, nothing
  that omits a store compiles any more — that is the intent, and it is the
  same capability boundary as with connecting: not observing, but making
  it impossible.
- [ ] **Step 3: Update the call sites.** Tests point at temporary
  directories. **No assertion is weakened to make something compile** —
  where a test used to accidentally read the real file and passed because
  of it, that is a finding and belongs in the report.
- [ ] **Step 4: Demonstrate the isolation.** The entry explicitly demands
  this: compare the contents of
  `~/Library/Application Support/macSCP/sessions-v2.json` and `logins.json`
  before and after a full run (a checksum suffices) and quote the result.
  **Change nothing about these files.** If one does not exist, "still does
  not exist afterward" is the result.
- [ ] **Step 5:** full suite green, no new warning.
- [ ] **Step 6: Commit** — `refactor(sessions): make every store an explicit choice`

---

### Task 2: Derive catalog locations from disk

**Files:**
- Modify: `Tests/macSCPAppKitTests/LocalizationParityTests.swift`,
  `Tests/macSCPAppKitTests/GermanAddressFormTests.swift`

**The measured current state:** both hard-code the catalog locations. The
languages within one location are derived from disk, the locations
themselves are not. A third localized target would go silently unchecked.

The entry classifies this itself: *"a check that checks less than it
believes it does is worse than none, because it reports success."* Today
there are exactly two `Resources/` directories, so it is consequence-free
for now.

**Precedent in-house:** `ReconnectWiringGuardTests
.everySourceDirectoryIsScannedOrExplicitlyExcluded` derives roots from disk
**and** from `Package.swift`. Read that before starting.

- [ ] **Step 1: Red first.** Set up a third `Resources/` directory with a
  catalog that deliberately omits a key, and prove that the checks today
  do **not** notice it. Remove it again.
- [ ] **Step 2: Derive instead of enumerating**, following the precedent
  above.
- [ ] **Step 3:** Run the same probe again — it must now go **red**. Quote
  both runs.
- [ ] **Step 4:** full suite green, no new warning.
- [ ] **Step 5: Commit** — `test(l10n): find the catalogues instead of listing them`

---

### Task 3: Pin down the guard in the TLS stub

**Files:**
- Modify: `Tests/macSCPCoreTests/` (a new or existing guard file)

**The measured current state:** `Tests/macSCPCoreTests/LoopbackTLSStub.swift`
is the only `import Security` under `Tests/` and calls `SecPKCS12Import`
**ungated** — on every `swift test`, not behind `MACSCP_KEYCHAIN`. That
nothing ends up in the login keychain as a result hangs on **one**
dictionary line:

```swift
kSecImportToMemoryOnly as String: kCFBooleanTrue as Any,
```

Without it, the call imports into the default keychain. Not a violation —
but the thinnest point of the isolation guarantee in the whole tree, held
up by one line that a refactor, a merge, or a copy-paste into a new stub
can remove.

- [ ] **Step 1: The guard.** Every `SecPKCS12Import` call under `Tests/`
  must carry `kSecImportToMemoryOnly` set true in the same options
  dictionary.

  **This check is inherently negative** ("no call without the flag") and
  therefore falls under the rule from `CLAUDE.md`: it needs a **positive**
  check beside it, asserting that the call exists at all. Without one it
  passes the moment someone renames the file — and reports success.
- [ ] **Step 2: Prove both directions.** Remove the flag → **red**; remove
  the call entirely → **the positive check goes red**. Quote both runs,
  revert both probes.
- [ ] **Step 3:** full suite green, no new warning.
- [ ] **Step 4: Commit** — `test(security): pin the flag that keeps the stub out of the keychain`

---

## What is explicitly not included

- **No change to `SessionListViewModel.save`** and none to what the stores
  do.
- No rework of the gated suites (`MACSCP_ITEST`, `MACSCP_KEYCHAIN`).
- No cleanup of the entry that the original incident left behind in the
  real `sessions-v2.json` — that is a file belonging to the maintainer, and
  nobody but him touches it.
