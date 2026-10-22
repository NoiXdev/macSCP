### Task 11: The create-bucket sheet

**Files:**
- Create: `Sources/MacSCPAppKit/CreateBucketSheet.swift`
- Modify: `Sources/MacSCPAppKit/ConnectionActionRoute.swift`,
  `ContentView+MenuActions.swift`, `ContentView.swift`,
  `ContentView+Sheets.swift`, `ContentView+Lifecycle.swift` (the row's
  availability — see the gate note below) (**added 2026-10-20**)
- Test: `Tests/macSCPAppKitTests/CreateBucketSheetTests.swift`,
  `Tests/macSCPAppKitTests/BoundedViewRegistry.swift`

**Wiring, added 2026-10-20 — without it this task builds a sheet nothing opens.**
Task 8 built the dispatcher: `ConnectionActionRoute` is a `String`-raw enum whose
`switch` in `handleConnectionAction` has **no `default`**, so adding a case
without an arm does not compile. Add the case, its arm, and the sheet's
presentation the way Task 8 did for `s3.versioning` —
`ConnectionActionRoute.swift` (the case), `ContentView+MenuActions.swift` (the
arm), `ContentView.swift` (the sheet item), `ContentView+Sheets.swift` (the
presentation) — plus the `BoundedViewRegistry` entries and the
`BoundedViewCoverageTests` floor, which Task 8 also had to raise. Until the case
exists the row stays disabled, which is correct but is not this task's
deliverable.

This is the third and fourth instance of one plan defect: Task 7 shipped a menu
with no handler (review I2), Task 11's gate had no caller (review I3), and
Tasks 9 and 11 each listed a sheet and its test and nothing that opens them.
A rule, a view or a seam with no caller is the same defect wearing different
clothes, and this plan produced it four times.


**Interfaces:**
- Consumes: `S3BucketName.problem(with:)`, `createBucket(_:protection:)`, Task 6's empty-account connect, and Task 8's per-row availability hook in `ContentView+Lifecycle.swift`. (**Corrected 2026-10-19:** first read `createBucket(_:versioning:objectLock:)` — see Task 5. **Extended 2026-10-20:** the availability hook, see below.)

**The bucket-list gate needs a consumer, added 2026-10-20 from Task 7's review
(I3).** Spec §6.1 says create bucket is offered in bucket-list mode only, and
this task's `CreateBucketModel.isOffered(rootIsContainerList:)` is that rule —
but as the
plan stood, nothing rendered it: the file list was sheet plus test, and the menu
row had no route to a `RootMode` at all. A rule with no caller is the same
defect as an empty seam.

So this task also supplies the `s3.createBucket` row's availability through the
hook Task 8 builds, and `isOffered(rootIsContainerList:)` is what the hook asks.

**Corrected 2026-10-20, raised by Task 8's implementer against its own work.**
Both signatures above first read `isOffered(rootMode:)`, and the test below first
read `isOffered(rootMode: .bucketList)` / `isOffered(rootMode: .bucket("x"))`.
**The App cannot name a `RootMode` in production code**: `S3FileSystem.RootMode`
is internal to Core, so a plan that asks the App to switch on it asks for
something that does not compile outside a test with `@testable import`. Task 8
built `ConnectionActionContext` with a `rootIsContainerList: Bool` taken from
`RemoteFileSystem.rootIsContainerList` — a member that already exists and that
the App already read **six times across four files** before this task
(`git grep -n 'rootIsContainerList' dda95109 -- 'Sources/MacSCPAppKit/*.swift'`
prints seven lines, one of them a comment at `ContentView+Detail.swift:544`) — so the gate asks the question the App
can actually answer. Note what this costs and what it does not: the predicate no
longer knows WHICH bucket, only whether the root is a list of them, which is all
§6.1's rule needs.

Note this
is a **different** gate from `aNameAlreadyInTheListBlocksTheButton` below: that
one is inside the sheet and refuses a name the account already owns; this one
decides whether the row can be chosen at all. Both are required, and neither
substitutes for the other.

- [ ] **Step 1: Write the failing tests**

```swift
@MainActor @Test func aNameTheStoreWouldRejectBlocksTheButtonAndSaysWhy() {
    let model = CreateBucketModel()
    model.name = "My_Bucket"
    #expect(model.canCreate == false)
    #expect(model.problem == .uppercase)
}

@MainActor @Test func objectLockIsFinalAndTheSheetSaysSo() {
    // The note says Object Lock can never be turned off again and freezes
    // versioning with it — NOT that it can only be set at creation, which
    // spec §6.1 withdrew on 2026-10-19. The honest sentence is "if you say
    // yes, you cannot undo it", not "you must decide now".
    let model = CreateBucketModel()
    #expect(model.objectLockNoteKey == "s3.createBucket.objectLockIsFinal")
}

@MainActor @Test func objectLockImpliesVersioning() {
    let model = CreateBucketModel()
    model.objectLock = true
    #expect(model.versioning == true)
    #expect(model.versioningIsLocked == true)
}

@MainActor @Test func theModelHandsCoreTheOneChoiceCoreAccepts() {
    // **Added 2026-10-21 by the controller, from a pre-dispatch read.** Core
    // deliberately has no pair of `Bool`s here:
    // `createBucket(_:protection:)` takes `BucketProtection`, and its doc
    // comment says why — "two independent `Bool`s would let a caller write
    // the combination that cannot exist", and an earlier shape that took two
    // and refused `objectLock: true, versioning: false` with
    // `.protocolError` was replaced by the enum so the contradiction cannot
    // be written at all.
    //
    // The two tests above reintroduce that pair in the App, which is right
    // — two checkboxes is what the user sees — but nothing above checks
    // which `BucketProtection` reaches Core. The sheet is where the pair is
    // folded back into the one choice, so that is where it is pinned.
    let model = CreateBucketModel()
    #expect(model.protection == .none)
    model.versioning = true
    #expect(model.protection == .versioned)
    model.objectLock = true
    #expect(model.protection == .lockedAndVersioned)
    model.versioning = false          // refused: the lock holds it on
    #expect(model.protection == .lockedAndVersioned)
}

@MainActor @Test func theActionIsOfferedOnlyInBucketListMode() {
    // Author's call, spec §6.1: a bucket made in single-bucket mode would be
    // invisible afterwards.
    #expect(CreateBucketModel.isOffered(rootIsContainerList: true) == true)
    #expect(CreateBucketModel.isOffered(rootIsContainerList: false) == false)
}

@MainActor @Test func aNameAlreadyInTheListBlocksTheButton() {
    // **Added 2026-10-19 from Task 5's review.** MEASURED on the rig: a
    // second `createBucket` of a bucket the key already owns SUCCEEDS, the
    // Object Lock header does not retrofit, and the versioning request DOES
    // take effect. Since `.never` is unrepresentable at the store, that is a
    // one-way door opened on a bucket the user did not mean to touch, and the
    // sheet reports "created".
    //
    // Core cannot tell created-from-already-owned apart on a 200, so the
    // check lives here: this sheet is offered only in bucket-list mode, so it
    // already holds the list and the check costs no request.
    let model = CreateBucketModel(existingNames: ["macscp-seed", "macscp-second"])
    model.name = "macscp-seed"
    #expect(model.canCreate == false)
    #expect(model.problem == nil)            // the NAME is valid; it is taken
    #expect(model.nameIsTakenKey == "s3.createBucket.nameIsTaken")
    model.name = "macscp-third"
    #expect(model.canCreate == true)         // the positive control
}

@MainActor @Test func theRowIsLiveOnlyWhileThePaneIsSHOWINGTheBucketList() {
    // **Added 2026-10-21 by the controller, from a pre-dispatch read.** See
    // "Where `existingNames` comes from" below; this is the gate that makes
    // the taken-name check above mean anything.
    #expect(CreateBucketModel.isOffered(rootIsContainerList: true, paneBucket: nil) == true)
    #expect(CreateBucketModel.isOffered(rootIsContainerList: true, paneBucket: "macscp-seed") == false)
    #expect(CreateBucketModel.isOffered(rootIsContainerList: false, paneBucket: nil) == false)
}
```

**Where `existingNames` comes from, and the trap in it. Added 2026-10-21 by the
controller, from a pre-dispatch read of the wiring.** The taken-name test above
is justified in this plan by the sentence "this sheet is offered only in
bucket-list mode, so it already holds the list and the check costs no request."
That conflates two different things, and the difference is a silent defect.

`rootIsContainerList` is a property of the **connection**, not of where the
remote pane is standing. On such a connection the user can navigate **into** a
bucket, and `session.remote`'s current listing is then that bucket's **objects**,
not the account's buckets. Feeding those as `existingNames` would check a
proposed bucket name against object names: it would let through exactly the
duplicate `createBucket` this test exists to prevent — measured on the rig as a
success that silently opens a one-way door on a bucket the user did not mean to
touch — and would block a valid name that happens to match some object's.

**Ruling: the row is live only while the pane is SHOWING the bucket list**, so
`existingNames` is always the real one and the claim that the check costs no
request stays true. The context already answers this and needs no new field:
`ConnectionActionContext.bucket` returns the first path component when
`rootIsContainerList`, so `rootIsContainerList && bucket == nil` means "the pane
is at the bucket list right now". Hence the signature changes to
`isOffered(rootIsContainerList:paneBucket:)` and the route's arm reads
`context.settings != nil && context.rootIsContainerList && context.bucket == nil`.

The alternative — offer the row anywhere on a bucket-list connection and fetch
the bucket list for the check — costs a request and makes this plan's own
"costs no request" false. It was not taken. Spec §6.1's reason for the gate
(a bucket made in single-bucket mode would be invisible) is untouched by this:
it argues about the connection, and narrowing to the pane only narrows further.

**And the arm you will be tempted to copy is the wrong one.** All three existing
arms in `ConnectionActionRoute.isAvailable(in:)` read
`context.settings != nil && context.bucket != nil`, because each is a
**bucket-level** action and `bucket` is `nil` at the list. This row is the
inverse: it is live exactly where they are dead. Copying a neighbouring arm
gives a row that can never be chosen — a view with no reachable route, which is
the defect this plan has already produced seven times. Task 8's implementer saw
it coming and left the note in that function's own doc comment: "a later row's
condition (a bucket-list-only gate) is an arm of its own."

The four rows then partition cleanly: versioning, CORS and Object Lock live
inside a bucket; create-bucket lives at the list. A test that asserts no two of
the four are live at the same place would say that, and is worth writing.

**A sentence Task 10 already ships depends on this task landing, carried here
2026-10-21 from Task 10's review (Minor).** `s3.objectLock.notEnabledOnThisBucket`
reads, in `en`:

> "Object Lock is not switched on for this bucket, so nothing in it can be
> locked. macSCP does not switch it on for a bucket that already exists; it can
> be chosen when a bucket is created."

Its last clause is a promise about a choice that does not exist yet. It becomes
true when this task's Object Lock checkbox lands, and it is wrong in every build
until then — Task 10's reviewer raised it as a Minor and I deferred it to here
rather than hedging a sentence that is about to be correct. So: when the checkbox
exists, check that clause against what the sheet actually offers, in all four
catalogues, and say in your report that you did. If this task's checkbox ends up
spelled differently from what that sentence describes, the sentence is the thing
that moves.

- [ ] **Step 2–5: Red, implement, catalogue entries, commit**

Run: `swift test --filter CreateBucketSheetTests`

```bash
git commit -m "feat(app): create a bucket, with the two switches that are final"
```

---

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

