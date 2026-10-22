### Task 7: The connection-level action seam

**Files:**
- Modify: `Sources/macSCPCore/Capabilities/BackendContributions.swift`, `BackendDescriptor.swift`
- Create: `Sources/MacSCPAppKit/ConnectionActionsMenu.swift`
- Modify: `Sources/MacSCPAppKit/ContentView+Lifecycle.swift`
- Test: `Tests/macSCPCoreTests/BackendContributionTests.swift`, `Tests/macSCPAppKitTests/ConnectionActionsMenuTests.swift`

**Interfaces:**
- Produces:

```swift
public struct ConnectionActionContribution: Sendable, Equatable, Identifiable {
    public let id: String
    public let titleKey: String
    public let titleDefault: String
    public let systemImage: String
}
// on BackendDescriptor:
public let connectionActions: [ConnectionActionContribution]
```

S3's four entries: `s3.createBucket`, `s3.versioning`, `s3.cors`, `s3.objectLock`. SSH's and WebDAV's are `[]`.

**This is the seam M22 deleted for being empty.** It is rebuilt with four callers present. The guard below is what holds it to that.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func onlyS3ContributesConnectionActions() {
    #expect(BackendDescriptor.sshDescriptor.connectionActions.isEmpty)
    #expect(BackendDescriptor.webDAVDescriptor.connectionActions.isEmpty)
    #expect(BackendDescriptor.s3Descriptor.connectionActions.count == 4)
}

@Test func theSeamIsNotEmptyInEveryBackend() {
    // The anti-goal, as a test: if every descriptor's list empties, the seam
    // has become the thing M22 removed and should go with it.
    let total = ConnectionKind.allCases
        .map(BackendDescriptor.descriptor(for:))
        .reduce(0) { $0 + $1.connectionActions.count }
    #expect(total > 0)
}

@MainActor @Test func aBackendWithNoActionsRendersNoCapsule() {
    #expect(ConnectionActionsMenu.isPresented(for: BackendDescriptor.sshDescriptor) == false)
    #expect(ConnectionActionsMenu.isPresented(for: BackendDescriptor.s3Descriptor) == true)
}
```

- [ ] **Step 2: Run them and watch them fail**

Run: `swift test --filter "BackendContribution|ConnectionActionsMenu"`
Expected: FAIL — `value of type 'BackendDescriptor' has no member 'connectionActions'`.

- [ ] **Step 3: Add `ConnectionActionContribution` and the descriptor member**

Every existing `BackendDescriptor(...)` construction gains `connectionActions:`. A synthetic descriptor exists in `SchemaConformanceTests` and needs it too.

- [ ] **Step 4: Build `ConnectionActionsMenu`**

A `Menu` rendering the active session's descriptor's `connectionActions`, titled from `L10n.string(titleKey, titleDefault)`. `isPresented(for:)` is `!descriptor.connectionActions.isEmpty`. The view is a `BoundedView` if it declares a width.

- [ ] **Step 5: Place it in the toolbar**

In `ContentView+Lifecycle.swift`'s `ToolbarItemGroup(placement: .primaryAction)`, **before** the existing buttons, so it lands in the free area left of the icon group (spec §5, the maintainer's screenshot of 2026-10-19). Rendered only when `isPresented(for:)`.

- [ ] **Step 6: Run the tests**

Run: `swift test --filter "BackendContribution|ConnectionActionsMenu"`
Expected: PASS.

- [ ] **Step 7: Four catalogue entries per action title, ×4 locales**

- [ ] **Step 8: Commit**

```bash
git add Sources/macSCPCore/Capabilities Sources/MacSCPAppKit Tests
git commit -m "feat(app): a connection's own actions, as one list per backend"
```

---

