# Backlog: tests that reach real stores

**Created:** 2026-08-22, after an incident during the implementation of
the connection state work. Not a design — a finding about the project, not
about one branch.

## What happened

An implementer wanted to prove that their new safeguard test catches a
regression, and for that removed the gate in front of the session handoff,
as a trial. Their test builds a real `ContentView`. The briefly unguarded
code then ran through and wrote **into the developer's real stores**:

- an entry in `~/Library/Application Support/macSCP/sessions-v2.json`
- a password into the login keychain under `dev.noix.macSCP`

The value written was a test string, not a real secret. The implementer
reverted the change immediately, stopped, and reported it; the protection
mechanism refused to let them clean it up in the keychain, which is
correct.

**Correction, measured 2026-08-22:** an earlier version of this paragraph
claimed both entries had been removed. Checked: the keychain entry is
gone, the entry in `sessions-v2.json` was still there. The claim was an
assumption, not a measurement.

This is not merely untidiness. `SessionListViewModel.save` looks up by
**name** — a run with a broken seam therefore writes the same entry again
and produces **byte-identical JSON**. The very snapshot test meant to prove
isolation thus passes precisely in the empty state the incident left
behind.

## The actual finding

**`ContentView` hardwires the keychain and the session store.** There is
no test seam. Which means *any* test that builds a `ContentView` can write
into the real stores.

Two files are affected today:

- `Tests/macSCPAppKitTests/ConnectAttemptHandoffTests.swift`
- `Tests/macSCPAppKitTests/LivenessGiveUpOrderingTests.swift`

On a green run, neither writes anything. That is not protection though,
it is an accident of the code path: **the next real regression at this
call site writes into a real keychain** — on the developer's machine and
in CI.

A test meant to prove a safeguard works must be able to play through its
failure. As long as the stores are real, "playing through the failure"
means exactly that.

## What needs doing

**A test seam for the real stores**, so a test can point them at a
temporary directory and a memory-only secret store. This fixes the class
instead of the two cases, and is the precondition for a test at the
`ContentView` level being allowed to safely exist at all.

**And the isolation must be demonstrated, not claimed:** point the store
at a temporary directory, run the suite, and show that the real file is
untouched. A claim about isolation without evidence is the same kind of
assertion this branch has repeatedly refuted.

## Rule in effect from now on

No mutation attempt that can reach real credentials, session, or
configuration stores. If proving something requires that, the test setup
must be changed first.

---

## Addendum 2026-08-25: `SessionListViewModel` has the same seam gap, and it is newly consequential

From the wrap-up review of the *failed setup* plan, recorded here **only**,
not fixed.

`SessionListViewModel.init` has default values that point at the real
directories, and `init` calls `reload()`. Counted in the same pass that
writes this paragraph, across every construction site under `Tests/`:

- **16** sites omit `loginSetStore:` and thereby read the real
  `~/Library/Application Support/macSCP/logins.json`
  (`PaneVisibilityPersistenceTests` 2, `SessionExportTagsTests` 3,
  `SessionListViewModelTests` 9, `SessionSecretPolicyTests` 2).
- **51** sites omit `auditStore:`. **8** of those (6 different
  construction sites, one of them — `makeVM()` — used three times) go on
  to call `vm.delete(...)`, all in `SessionListViewModelTests`, which
  triggers a `removeItem` against the **real** audit directory — harmless
  today, because the session IDs are fresh and the file never exists.
  (A ninth `vm.delete(...)` call, in `deleteRemovesTheSessionsAuditLog`,
  does not count: the `vm` there gets `auditStore:` explicitly injected
  against a temp directory.)

Pre-existing debt, but `c1db9a6` made it consequential for the first time:
there, `loginSets = (try? loginSetStore.all()) ?? []` is replaced by a
`do/catch` that **appends** the error onto `errorMessage`. That means the
observable state of these 16 tests now hangs off the content of a real
user file. Today it is fine — of the 16, two read `errorMessage`
afterward, and both assertions are `hasPrefix`-shaped and survive an
appended string. No write on the read path.

**Cheap fix, same class as above:** remove the default values from
`init` and make the call sites explicit. Then "reads the real file" is
nothing a test can do by accident.

## Addendum 2026-08-25: `catalogDirectories` is a hard-coded list

`LocalizationParityTests.catalogDirectories` and `GermanAddressFormTests
.catalogs` enumerate the catalog locations by hand. The *locales* within
one location are derived from disk, the **locations themselves are not**.
A third localized target would go silently unchecked.

This is exactly the class `ReconnectWiringGuardTests` has its own
`everySourceDirectoryIsScannedOrExplicitlyExcluded` for: a check that
checks less than it believes it does is worse than none, because it
reports success. Today there are exactly two `Resources/` directories, so
consequence-free — and the same derivation from disk would be just as
cheap here as it is there.

## Addendum 2026-08-26: `LoopbackTLSStub` imports `Security` ungated

From the wrap-up review of the *failed setup* plan (M5 there), added here
because it only lived in the gitignored `.superpowers/` store and would
have vanished with the working directory. **Only reasoned about, not
acted on** — not a violation, but the thinnest point of the isolation
guarantee in the whole tree, and new.

`Tests/macSCPCoreTests/LoopbackTLSStub.swift` is the only `import
Security` under `Tests/` and calls `SecPKCS12Import` **ungated** — on
every `swift test`, not behind `MACSCP_KEYCHAIN`. That nothing ends up in
the login keychain from this hangs on a single dictionary line:

```swift
kSecImportToMemoryOnly as String: kCFBooleanTrue as Any,
```

The SDK header confirms both directions: with the flag, process memory
only (`API_AVAILABLE(macos(15.0))`, matching the package minimum);
without it, import into the default keychain. The file already documents
this in its own header comment.

**Why it still belongs in the backlog:** any line that deletes this
import or removes the flag line — a refactor, a merge conflict, a
copy-paste into a new stub file — silently switches off the protection,
on every ungated test run, not just a gated one. Cheap fix: apply the
same guard idea that already enforces `MACSCP_KEYCHAIN` for the gated
suite — a self-test that checks `SecPKCS12Import` calls under `Tests/`
for `kSecImportToMemoryOnly: true`.
