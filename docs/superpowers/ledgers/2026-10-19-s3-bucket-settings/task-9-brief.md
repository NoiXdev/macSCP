### Task 9: The CORS sheet, form and text

**Files:**
- Create: `Sources/MacSCPAppKit/BucketCORSSheet.swift`
- Modify: `Sources/MacSCPAppKit/ConnectionActionRoute.swift`,
  `ContentView+MenuActions.swift`, `ContentView.swift`,
  `ContentView+Sheets.swift` (**added 2026-10-20** — see "Wiring" below)
- Test: `Tests/macSCPAppKitTests/BucketCORSSheetTests.swift`,
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
- Consumes: `CORSRule`, `CORSValidation`, `S3BucketSettings.cors(ofBucket:)`.

- [ ] **Step 1: Write the failing tests**

```swift
@MainActor @Test func theFormAndTheTextShowTheSameRules() throws {
    let model = BucketCORSModel(rules: [.init(id: "r", allowedOrigins: ["*"],
        allowedMethods: ["GET"], allowedHeaders: [], exposeHeaders: [], maxAgeSeconds: 60)])
    #expect(try S3SettingsXML.parseCORS(Data(model.text.utf8)) == model.rules)
}

@MainActor @Test func anInvalidMethodBlocksSavingAndNamesItself() {
    let model = BucketCORSModel(rules: [])
    model.text = "<CORSConfiguration><CORSRule><AllowedOrigin>*</AllowedOrigin>"
        + "<AllowedMethod>FETCH</AllowedMethod></CORSRule></CORSConfiguration>"
    #expect(model.canSave == false)
    #expect(model.problem == .methodNotAllowed("FETCH"))
}

@MainActor @Test func aConfigurationTheFormCannotShowDisablesTheForm() {
    // The honest edge (spec §6.3). Measured as near-unreachable — the store
    // refuses undocumented elements — so this is the fallback, not the norm.
    let model = BucketCORSModel(rules: [])
    model.text = "<CORSConfiguration><CORSRule><AllowedOrigin>*</AllowedOrigin>"
        + "<AllowedMethod>GET</AllowedMethod><Unknown>x</Unknown></CORSRule></CORSConfiguration>"
    #expect(model.formIsAvailable == false)
    #expect(model.formUnavailableReasonKey == "s3.cors.formCannotShowThis")
}
```

- [ ] **Step 2: Run them and watch them fail**

Run: `swift test --filter BucketCORSSheetTests`
Expected: FAIL — `cannot find 'BucketCORSModel' in scope`.

- [ ] **Step 3: Implement the model and the sheet**

Two panes behind one segmented control, built with `SegmentedChoice` from `RigidControls.swift` so the control cannot be squeezed. Editing either pane updates the other; the text is the source of truth, and the form disables itself when the text holds something it cannot represent.

- [ ] **Step 4: Run the tests, catalogue entries, commit**

```bash
git commit -m "feat(app): edit a bucket's CORS rules as fields or as text"
```

---

