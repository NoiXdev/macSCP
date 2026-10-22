### Task 12: The audit trail

**Files:**
- Modify: `Sources/macSCPCore/Sessions/AuditEvent.swift`, `AuditRecorder.swift`, catalogues ×4
- Modify, **added 2026-10-21** — the App side, without which this task has no
  caller: the sites that apply each of the five operations. Read them; the plan
  does not name a line, because they moved in Tasks 8–11.
- Test: `Tests/macSCPAppKitTests/` — the existing `everyKindHasACatalogLabel` guard covers the new kinds

**This task had no caller, found 2026-10-21 by a pre-dispatch read.** The file
list above first named Core and the catalogues only, and the existing audit
sink does not reach these operations. `auditSink` is declared in exactly two
places, both in Core's Presentation layer —
`RemoteBrowserViewModel.auditSink` and `TransferQueueViewModel.auditSink`
(`grep -rn "auditSink" Sources/macSCPCore/`) — and the App wires the first of
them in one line, `ContentView+Lifecycle.swift`:
`tab.session?.remote.auditSink = { event in recorder.recordAction(event) }`.
The bucket-settings sheets do not go through `RemoteBrowserViewModel`: they
hold an `S3BucketSettings` and call it directly. So no existing sink carries
their events, and a Core-only Task 12 would have added four `Kind` cases and
four recorder methods that nothing calls — **the seventh instance on this
branch of a rule with no caller, and the one where it costs most, since this
task exists to leave a trace of the branch's only irreversible write.**

The App already has the other spelling for a sheet that records directly:
`ContentView.swift` takes `activeTab.auditRecorder` and calls
`recorder?.recordAction(...)`. Follow that, and prefer putting the recorder
where a new apply path **cannot compile without one** over a scan that looks
for the call — this project's rule about a scan that keeps buying one spelling
applies here, and five apply paths is where it starts to.

**Interfaces:**
- Produces: `AuditEvent.Kind` gains `bucketCreated`, `versioningChanged`, `corsChanged`, `objectLockChanged`, and `AuditRecorder` a method per kind.

A COMPLIANCE retention is the most irreversible thing macSCP can do; without this it is the only one leaving no trace (spec §8).

- [ ] **Step 1: Write the failing test**

**Corrected 2026-10-21, before dispatch.** This step first held one test, and
it was the only test of the task:

```swift
@Test func everyNewKindIsRecordedByTheActionThatCausesIt() {
    let recorded = Set(AuditEvent.Kind.allCases.map(\.rawValue))
    #expect(recorded.isSuperset(of: ["bucketCreated", "versioningChanged",
                                      "corsChanged", "objectLockChanged"]))
}
```

Its name claims what it does not check. `AuditEvent.Kind.allCases` contains
the cases the enum declares, so once the four cases are written the assertion
cannot fail — it is a second copy of the declaration, and it stays green on a
tree where not one of the five operations records anything. The name is the
claim the task actually owes, so the test has to be the thing the name says.

Write these instead, and keep the enum check as well — cheap, and it does pin
the raw spellings the catalogue keys are built from:

```swift
@Test func theFourNewKindsAreDeclaredWithTheSpellingsTheCatalogueUses() {
    let declared = Set(AuditEvent.Kind.allCases.map(\.rawValue))
    #expect(declared.isSuperset(of: ["bucketCreated", "versioningChanged",
                                      "corsChanged", "objectLockChanged"]))
}

@MainActor @Test func eachOperationRecordsExactlyOneEventOfItsOwnKind() async throws {
    // One case per operation, five in all: create, versioning, CORS, the
    // per-file retention/legal hold, the bucket default. Each drives the
    // sheet's own apply path against a fake and reads the recorder.
    // Parameterise it over the five rather than writing five bodies.
}

@MainActor @Test func aRefusedOperationRecordsTheFailureAndNotASuccess() async throws {
    // `AuditEvent` already carries `isError` and `errorMessage`; the existing
    // kinds use both. A refused apply must not read as done.
}

@MainActor @Test func anObjectLockLineNamesWhichOfTheThreeOperationsItWas() {
    // `objectLockChanged` covers three things: a per-file retention, a legal
    // hold, and the bucket default. Only one of them is irreversible, so a
    // trail in which they are indistinguishable does not do the job spec §8
    // asks of it. The kind cannot separate them; the detail must.
    //
    // A COMPLIANCE retention's line names the mode and the date. This is the
    // one assertion in the task that the maintainer's 2026-10-19 decision
    // rests on.
}
```

- [ ] **Step 2: Run it, watch it fail, implement, run the catalogue guard**

Run: `swift test --filter "Audit|everyKindHasACatalogLabel"`

**No detail in an audit line may be the store's words or carry a secret.** The detail is the bucket name and the action, both macSCP's own values.

**Added 2026-10-21:** a detail is also read back by a test, and `#expect`
prints the source text of the expression it checks, so a value that must not
leak goes in a named constant with the `Bool` computed before the
expectation. Nothing in these five operations is a secret — a bucket name, a
key, a mode, a date — but the rule binds the shape of the test either way,
and an access key must never reach a line through an error message copied
from a refusal.

- [ ] **Step 3: Commit**

```bash
git commit -m "feat(core): record the bucket settings in the audit trail"
```

---

