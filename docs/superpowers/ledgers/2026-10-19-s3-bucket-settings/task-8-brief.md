### Task 8: The versioning sheet

**Files:**
- Create: `Sources/MacSCPAppKit/BucketVersioningSheet.swift`
- Modify: `Sources/MacSCPAppKit/ContentView+MenuActions.swift`
- Modify: `Sources/MacSCPAppKit/ContentView+Lifecycle.swift` (**added 2026-10-20
  — see "This task owns the handler seam" below**)
- Test: `Tests/macSCPAppKitTests/BucketVersioningSheetTests.swift`

**This task owns the handler seam, added 2026-10-20 from Task 7's review (I2).**
Task 7 built the menu but had no handler to give it, so
`ContentView+Lifecycle.swift` passes `onSelect: nil` and all four rows render
disabled. No later task's file list touched that file, so without this
assignment every row would stay disabled for the rest of the plan — a menu that
is placed, localized, tested and permanently dead.

Replace the `nil` with a dispatcher that routes by contribution **id**, the way
`ContentView+MenuActions.swift` already dispatches file actions, and give it
**per-row availability** rather than one flag for the menu: the call site in
`ContentView+Lifecycle.swift` is the only place that knows both the descriptor
and the session's root mode, which is what Task 11's gate needs (I3, recorded
there). Wire `s3.versioning` to this task's sheet; the other three ids stay
unavailable until Tasks 9, 10 and 11 add their arms, and a row with no arm
stays disabled rather than enabled-and-inert.

A test pins that a wired id is enabled and an unwired id is not — the positive
beside the negative, since "disabled" is the state a broken dispatcher also
produces.

**You will break a guard, and this is the one, named here so you do not discover
it as a mystery red.** Task 7's fix round added
`ConnectionActionsMenuTests.theRowsAreDisabledWhileThereIsNoHandler`
(`Tests/macSCPAppKitTests/ConnectionActionsMenuTests.swift:186`). It requires a
`.disabled(...)` inside the `ForEach` conditioned on the handler being `nil`,
reading the handler's name from the view's own declaration, and it exists because
without it the whole user-visible behaviour of that commit was unpinned — a
plant deleting the line came back GREEN during review.

Replacing `.disabled(onSelect == nil)` with per-row availability makes that test
red **correctly**: the property it names stops being the property the code has.
Rewrite it to the new rule — a row is disabled when its own id has no arm —
rather than deleting it, and keep both halves it was built with: the condition is
read, not merely present (a `.disabled(false)` plant must stay red), and the
handler's name is derived, not spelled. Say in your report which plants you
re-ran against the rewritten guard.

**Added 2026-10-20, from Task 7's re-review.** This obligation was missing when
Task 8 was given the handler seam earlier the same day: the amendment named the
file to change and not the guard that change invalidates, which is the plan-level
form of the mistake this project has a rule about for comments.

**Interfaces:**
- Consumes: `S3BucketSettings.versioning(ofBucket:)`, `BucketVersioning`, `ConnectionActionContribution` id `s3.versioning`.

- [ ] **Step 1: Write the failing tests**

```swift
@MainActor @Test func aNeverVersionedBucketOffersOnlyEnabling() {
    // Review Focus 4: "suspend" means nothing on a bucket that never kept
    // versions, and offering it would ask for a call that cannot be made.
    let model = BucketVersioningModel(current: .never)
    #expect(model.offeredStates == [.enabled])
}

@MainActor @Test func anEnabledBucketCanBeSuspendedAndNotUnset() {
    let model = BucketVersioningModel(current: .enabled)
    #expect(model.offeredStates == [.suspended])
}

@MainActor @Test func suspendingSaysWhatItDoesNotDo() {
    let model = BucketVersioningModel(current: .enabled)
    #expect(model.warningKey == "s3.versioning.suspendKeepsVersions")
}
```

- [ ] **Step 2: Run them and watch them fail**

Run: `swift test --filter BucketVersioningSheetTests`
Expected: FAIL — `cannot find 'BucketVersioningModel' in scope`.

- [ ] **Step 3: Implement the model and the sheet**

The sheet shows the current state, the one state it can move to, and the warning that suspension keeps every stored version and its cost.

- [ ] **Step 4: Wire the contribution id**

In `ContentView+MenuActions.swift`, beside the existing `s3.presignedURL` arm.

- [ ] **Step 5: Run the tests, add the catalogue entries, commit**

Run: `swift test --filter BucketVersioningSheetTests`

```bash
git commit -m "feat(app): turn a bucket's versioning on, and say what suspending keeps"
```

---

