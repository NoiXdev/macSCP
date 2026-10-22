### Task 11b: The versioning switch does not offer what Object Lock forbids

**Added 2026-10-21 by the controller, from a pre-dispatch read of the tree
before Task 11.** Task 8's `BucketVersioningModel.offeredStates` returns
`[.suspended]` for `.enabled` unconditionally
(`Sources/MacSCPAppKit/BucketVersioningSheet.swift`, the `offeredStates`
symbol). Spec §4 says of a bucket with Object Lock that "once on it can never
be turned off and versioning can never be suspended again" — sourced to AWS's
own configuration guide, not measured here. So on a lock-bearing bucket the
sheet offers the one action the spec says cannot succeed, and the user learns
it from a store refusal rather than from macSCP.

This is not a new rule. It is the rule Task 8's own first test already states,
quoted verbatim from its comment: "'suspend' means nothing on a bucket that
never kept versions, and offering it would ask for a call that cannot be
made." Task 8 applied it to the never-versioned case and not to the
lock-bearing one, because when Task 8 ran nothing in the App could answer
"does this bucket have a lock". Task 10 built that answer:
`ObjectLockStateCache`, owned by the session.

Spec §6.2 is silent on Object Lock, which is why the plan inherited the gap;
§4 is where the fact lives. The task is small and is scheduled after Task 11
rather than folded into it, because Task 11's subject is a different sheet and
its dispatch is already large.

**Files:**
- Modify: `Sources/MacSCPAppKit/BucketVersioningSheet.swift`, the four
  `Localizable.strings` catalogues, and the sheet's call site (whichever of
  `ContentView+Sheets.swift` / `ContentView.swift` constructs
  `BucketVersioningModel` — read it, do not assume).
- Test: `Tests/macSCPAppKitTests/BucketVersioningSheetTests.swift`,
  `Tests/macSCPAppKitTests/BoundedViewRegistry.swift`

**Interfaces:**
- Consumes: Task 10's `ObjectLockStateCache` and
  `BrowserSession.objectLockStates` — read both before writing anything; the
  cache's method is `hasObjectLock`, and it is the member that is `false` only
  on the store's 404, never on another failure.

- [ ] **Step 1: Write the failing tests**

```swift
@MainActor @Test func aLockBearingBucketIsNotOfferedSuspension() {
    let model = BucketVersioningModel(current: .enabled, bucketHasObjectLock: true)
    #expect(model.offeredStates == [])
    #expect(model.blockedReasonKey == "s3.versioning.objectLockKeepsItOn")
}

@MainActor @Test func aBucketWithoutALockIsStillOfferedSuspension() {
    // The positive control. Without it the test above passes on a model that
    // offers nothing to anybody.
    let model = BucketVersioningModel(current: .enabled, bucketHasObjectLock: false)
    #expect(model.offeredStates == [.suspended])
    #expect(model.blockedReasonKey == nil)
}

@MainActor @Test func anUnreadLockStateOffersNothingAndSaysNothingAboutLocks() {
    // The third state is the one that bites: the cache has not answered yet.
    // Offering suspension here would be the old behaviour under a new name,
    // and naming Object Lock here would assert a fact nobody has read.
    let model = BucketVersioningModel(current: .enabled, bucketHasObjectLock: nil)
    #expect(model.offeredStates == [])
    #expect(model.blockedReasonKey == nil)
}

@MainActor @Test func enablingIsNeverBlockedByALock() {
    // A never-versioned bucket cannot carry a lock, but a suspended one that
    // somehow reads as locked must still be offered the way back ON.
    for lock in [true, false] {
        let suspended = BucketVersioningModel(current: .suspended, bucketHasObjectLock: lock)
        #expect(suspended.offeredStates == [.enabled])
    }
}
```

- [ ] **Step 2: Run them and watch them fail**

Run: `swift test --filter BucketVersioningSheetTests`
Expected: FAIL — `BucketVersioningModel` has no `bucketHasObjectLock:`
parameter. Quote the compiler's line verbatim in the report.

- [ ] **Step 3: Make the parameter explicit at every construction site**

`bucketHasObjectLock` is a `Bool?`, and it takes **no default value**. Count
the construction sites first and spell it at each one — that is the same
ruling the controller made for `BackendDescriptor.connectionActions`, and for
the same reason: a default is what lets a new call site silently keep the old
behaviour. Write the count into the report beside the command that produced
it.

- [ ] **Step 4: Add the catalogue entry in all four languages**

`s3.versioning.objectLockKeepsItOn`. It says what is true and no more: this
bucket uses Object Lock, so its versioning cannot be switched off. It must
**not** claim the store refuses it — the fact is AWS's documentation, not a
measurement from this project's rig, and the spec marks it that way.
German in du-form.

- [ ] **Step 5: Wire the call site to the session's cache**

The sheet's opener reads `BrowserSession.objectLockStates` for the bucket. A
state not yet read is `nil`, not `false` — the whole point of the third test.
Do not add a blocking read to open the sheet.

**The two reads must land together, or the sheet has a window in which it
offers nothing and explains nothing.** `offeredStates` is already `[]` while
`current` is `nil`, and the sheet shows its action only once the versioning
read returns; if the lock read returns later, the user sees a loaded sheet
whose only button has vanished for no stated reason. Fold the lock read into
the same load as the versioning read — one `load` state covering both — rather
than letting a second answer arrive after the sheet has settled. Decide this
by reading the opener; the plan does not know which shape that file wants.

- [ ] **Step 6: Probe it**

Two plants through `scripts/mutation-probe`, on a committed tree: the lock
check removed from `offeredStates`, and `nil` treated as `false`. Both must go
RED, and the second is the one a careless fix leaves green.

- [ ] **Step 7: Run the tests and commit**

```bash
git commit -m "fix(app): a bucket under Object Lock is not offered a suspension it cannot have"
```

---

