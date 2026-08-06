# M22 — Data-Driven Backend Registration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every protocol-dependent decision read from `BackendDescriptor`, so the six `switch`-over-`ConnectionKind` sites M21 surfaced disappear and login sets work for WebDAV without any WebDAV-specific UI.

**Architecture:** Each backend declares its fields as a typed `enum` (one source for both schemas, the config factory and the persistence adapter). The descriptor grows a declarative form schema with a closed vocabulary — text/secret/toggle/picker/group plus a one-shape visibility condition — and a factory closure that turns collected values into a `ConnectionConfig`. The on-disk format does not change: a small per-backend adapter translates between `FieldValues` and the existing typed `Codable` structs.

**Tech Stack:** Swift 6 toolchain in `.swiftLanguageMode(.v5)`, SwiftPM, macOS 15+, SwiftUI, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-08-06-m22-datengetriebene-backends-design.md`

## Global Constraints

- **Code and comments: English only.** No German in source files.
- **App UI is localized.** All four String Catalogs (`en`/`de`/`fr`/`pl`) must carry every key and stay identical in key set — a guard test enforces this. French uses the typographic apostrophe (U+2019). CLI output is English-only and not localized.
- Swift tools 6.0, all targets `.swiftLanguageMode(.v5)`, minimum macOS 15.
- Tests: Swift Testing (`@Test`/`#expect`), TDD red→green.
- Unit suite: `swift test`. Gated suites: `MACSCP_ITEST=1` (Docker rig), `MACSCP_KEYCHAIN=1`.
- Docker rig: `docker compose -f docker/test-server/compose.yml up -d`, **always from the main checkout, never a git worktree.**
- **Never commit key material or secrets.** Secrets live exclusively in the macOS Keychain; JSON stores never contain them.
- **A secret's value must never be printed, logged, or embedded in an error.**
- **The on-disk format does not change.** `StoredSession`, `StoredS3Config`, `StoredWebDAVConfig` keep their shape. `LoginSet` may only gain *optional* new properties, so old files decode as `nil`.
- **The existing SSH and S3 tests are the safety net.** They must not be edited to fit a new implementation. If one goes red, the implementation is wrong — with exactly one carve-out, named here so nobody has to guess:

  A test that asserts a **secret field lives in the connection schema** is asserting the M12 arrangement this milestone deliberately inverts. Moving credentials into `credentialSchema` is the change that makes login sets work for every backend without per-protocol UI; a test pinning the old location is not a safety net, it is the old design. Such a test is **relocated, never deleted**: it must still assert the secret is present and reachable, now in `credentialSchema`, and be renamed to say so. `BackendDescriptorTests.s3SchemaHasProviderPresetsAndSecretField` is the known instance.

  Every other red test means the implementation is wrong. Stop and report rather than editing.
- Conventional Commits; footer on every commit: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- **Commit locally only. Do NOT push.**
- A full `swift build 2>&1 | grep -c warning` currently reports **66**, all from the Citadel/NIOSSH dependencies. No warning line may name a file you touched.
- **The unit suite hangs intermittently at 0% CPU, roughly one run in three** — a pre-existing, unexplained flake. If a run stalls with no output for over two minutes, kill it and retry. Only if it reproduces three times running is it yours.

---

## File Structure

**New — `Sources/macSCPCore/Capabilities/`**
- `BackendFieldID.swift` — the `BackendFieldID` protocol and `FieldValues`
- `FieldVocabulary.swift` — `ConnectionField`, `LeafField`, `OptionSource`, `Condition`, `FieldVisibility`
- `SchemaConformance.swift` — the reusable conformance check both Core tests and the milestone gate use

**New — per backend, next to its existing code**
- `SSH/SSHFieldSchema.swift`, `S3/S3FieldSchema.swift`, `WebDAV/WebDAVFieldSchema.swift` — field enum, both schemas, factory, adapter, display summary

**Modified**
- `Capabilities/BackendDescriptor.swift` — the new members
- `Capabilities/ConnectionFieldSchema.swift` — `ConnectionField` gains `kind` cases and `visibleWhen`
- `Presentation/ConnectionViewModel.swift` — typed properties out, `FieldValues` in
- `Sessions/LoginSetStore.swift`, `Sessions/LoginResolver.swift`
- `Sessions/CLISecretSources.swift`, `CLI/CLIErrorMapping.swift`
- `Connection/BackendConnector.swift` (dissolved)
- `MacSCPApp/ConnectionFormView.swift`, `MacSCPApp/LoginSetsSheet.swift`, `MacSCPApp/ContentView.swift`

---

### Task 1: Typed field IDs and `FieldValues`

The foundation. Nothing consumes it yet, so it is provable in isolation.

**Files:**
- Create: `Sources/macSCPCore/Capabilities/BackendFieldID.swift`
- Test: `Tests/macSCPCoreTests/FieldValuesTests.swift`

**Interfaces:**
- Consumes: nothing
- Produces: `protocol BackendFieldID`, `struct FieldValues`

- [ ] **Step 1: Write the failing tests**

`Tests/macSCPCoreTests/FieldValuesTests.swift`:

```swift
import Foundation
import Testing
@testable import macSCPCore

private enum TestField: String, CaseIterable, BackendFieldID {
    static let namespace = "TestField"
    case alpha, beta, flag
}

private enum OtherField: String, CaseIterable, BackendFieldID {
    static let namespace = "OtherField"
    case alpha
}

/// Two backends that each nest their field enum under the same short name.
/// This is the shape that a name derived from the type would collide on:
/// Swift interpolates both metatypes as the bare string "Field".
private enum FirstBackend {
    enum Field: String, CaseIterable, BackendFieldID {
        static let namespace = "FirstBackend.Field"
        case username
    }
}

private enum SecondBackend {
    enum Field: String, CaseIterable, BackendFieldID {
        static let namespace = "SecondBackend.Field"
        case username
    }
}

@Suite("FieldValues")
struct FieldValuesTests {
    @Test func readsBackWhatWasWritten() {
        var values = FieldValues()
        values[TestField.alpha] = "one"
        #expect(values[TestField.alpha] == "one")
    }

    /// An unset field reads as empty rather than nil, so every call site does
    /// not have to unwrap. Absence and "the user cleared it" are the same
    /// thing for a form field.
    @Test func unsetFieldIsEmpty() {
        #expect(FieldValues()[TestField.beta] == "")
    }

    @Test func booleanRoundTrips() {
        var values = FieldValues()
        values[bool: TestField.flag] = true
        #expect(values[bool: TestField.flag] == true)
        values[bool: TestField.flag] = false
        #expect(values[bool: TestField.flag] == false)
    }

    /// Anything that is not exactly "true" reads as false — a half-written
    /// file must not flip a toggle on.
    @Test func unparseableBooleanIsFalse() {
        var values = FieldValues()
        values[TestField.flag] = "yes"
        #expect(values[bool: TestField.flag] == false)
    }

    /// Two backends may both have a field called "alpha". Their values must
    /// not collide, or a WebDAV form would inherit an S3 value.
    @Test func sameRawNameInTwoBackendsDoesNotCollide() {
        var values = FieldValues()
        values[TestField.alpha] = "from-test"
        values[OtherField.alpha] = "from-other"
        #expect(values[TestField.alpha] == "from-test")
        #expect(values[OtherField.alpha] == "from-other")
    }

    /// Group members are addressed by group + leaf, and stored flat.
    @Test func groupMemberIsAddressedByGroupAndLeaf() {
        var values = FieldValues()
        values[TestField.alpha, OtherField.alpha] = "nested"
        #expect(values[TestField.alpha, OtherField.alpha] == "nested")
        #expect(values[TestField.alpha] == "")
    }

    /// The nested-enum collision the namespace exists to prevent. Deriving
    /// the prefix from the type name would make both of these `"Field.username"`
    /// — verified: Swift interpolates a metatype unqualified, so
    /// `"\(FirstBackend.Field.self)"` and `"\(SecondBackend.Field.self)"` are
    /// both the bare string "Field".
    @Test func nestedEnumsWithTheSameShortNameDoNotCollide() {
        var values = FieldValues()
        values[FirstBackend.Field.username] = "from-first"
        values[SecondBackend.Field.username] = "from-second"
        #expect(values[FirstBackend.Field.username] == "from-first")
        #expect(values[SecondBackend.Field.username] == "from-second")
        #expect(values.raw.count == 2)
    }

    /// Pins the on-disk key shape, not merely that some value landed
    /// somewhere. The persistence adapters read `raw` directly, so the exact
    /// key is part of the contract — a change here changes saved files.
    @Test func rawStorageUsesTheNamespacedKey() {
        var values = FieldValues()
        values[TestField.alpha] = "one"
        values[TestField.alpha, OtherField.alpha] = "nested"
        #expect(values.raw["TestField.alpha"] == "one")
        #expect(values.raw["TestField.alpha.alpha"] == "nested")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter "FieldValues"`
Expected: FAIL — `cannot find type 'BackendFieldID' in scope`

- [ ] **Step 3: Implement**

`Sources/macSCPCore/Capabilities/BackendFieldID.swift`:

```swift
import Foundation

/// A backend's field identifiers (M22). Each backend declares one of these,
/// and it is the SINGLE source for its connection schema, its credential
/// schema, its config factory and its persistence adapter.
///
/// The point is that there are no loose strings anywhere: a field that does
/// not exist cannot be written into a schema, read from `FieldValues`, or
/// forgotten by the factory — the last one because the factory switches over
/// this enum and the compiler checks exhaustiveness.
public protocol BackendFieldID: RawRepresentable, CaseIterable, Hashable, Sendable
where RawValue == String {
    /// The stable prefix this backend's stored keys carry.
    ///
    /// Declared explicitly rather than derived from the type name, for two
    /// reasons. Swift's `"\(F.self)"` yields the UNQUALIFIED name, so two
    /// backends that each nest their enum as `Backend.Field` would both
    /// produce `"Field"` and silently share storage — verified, not assumed.
    /// And a derived name would make renaming the enum a silent format
    /// change, breaking every session already on disk.
    static var namespace: String { get }
}

/// The values a form collected, keyed by field.
///
/// Storage is flat and prefixed with the field enum's declared `namespace`,
/// so two backends may both call a field `username` without colliding. Group
/// members live in the same flat map under `namespace.group.leaf`, which
/// keeps persistence a plain string map rather than a tree.
///
/// Keys are joined with `.`, so a field's raw value must not contain one.
/// Swift derives raw values from the case names, which cannot — only an
/// explicit `case foo = "a.b"` could, and no backend writes one.
public struct FieldValues: Equatable, Sendable {
    private var storage: [String: String]

    public init() { storage = [:] }

    public init(raw: [String: String]) { storage = raw }

    /// The flat map, for the per-backend persistence adapters.
    public var raw: [String: String] { storage }

    private static func key<F: BackendFieldID>(_ field: F) -> String {
        "\(F.namespace).\(field.rawValue)"
    }

    private static func key<G: BackendFieldID, L: BackendFieldID>(
        _ group: G, _ leaf: L
    ) -> String {
        "\(G.namespace).\(group.rawValue).\(leaf.rawValue)"
    }

    /// An unset field reads as the empty string — absence and "cleared by the
    /// user" are the same thing for a form field, and making every call site
    /// unwrap an optional would buy nothing.
    public subscript<F: BackendFieldID>(field: F) -> String {
        get { storage[Self.key(field)] ?? "" }
        set { storage[Self.key(field)] = newValue }
    }

    public subscript<G: BackendFieldID, L: BackendFieldID>(
        group: G, leaf: L
    ) -> String {
        get { storage[Self.key(group, leaf)] ?? "" }
        set { storage[Self.key(group, leaf)] = newValue }
    }

    /// Toggles. Only the exact string "true" is true: a half-written or
    /// hand-edited file must not be able to flip a toggle on by accident.
    public subscript<F: BackendFieldID>(bool field: F) -> Bool {
        get { storage[Self.key(field)] == "true" }
        set { storage[Self.key(field)] = newValue ? "true" : "false" }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter "FieldValues"`
Expected: PASS — 7 tests

- [ ] **Step 5: Commit**

```bash
git add Sources/macSCPCore/Capabilities/BackendFieldID.swift Tests/macSCPCoreTests/FieldValuesTests.swift
git commit -m "feat: add typed backend field IDs and FieldValues

One enum per backend becomes the single source for both schemas, the
config factory and the persistence adapter. Storage is namespaced by the
enum's type name so two backends can both have a field called username.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: The field vocabulary

The closed vocabulary the schema is written in. Nesting depth is a **type** property here, not a runtime check: a `.group` holds `LeafField`, and `LeafField.Kind` has no `.group` case, so "exactly one level deep" is guaranteed by the compiler.

**Files:**
- Create: `Sources/macSCPCore/Capabilities/FieldVocabulary.swift`
- Modify: `Sources/macSCPCore/Capabilities/ConnectionFieldSchema.swift`
- Test: `Tests/macSCPCoreTests/FieldVisibilityTests.swift`

**Interfaces:**
- Consumes: `FieldValues`, `BackendFieldID` (Task 1)
- Produces: `LeafField`, `OptionSource`, `FieldOption`, `FieldCondition`, `FieldVisibility.isVisible(_:in:)`; `ConnectionField` gains `kind` cases `.picker`/`.group` and a `visibleWhen` property

- [ ] **Step 1: Write the failing tests**

`Tests/macSCPCoreTests/FieldVisibilityTests.swift`:

```swift
import Foundation
import Testing
@testable import macSCPCore

private enum VField: String, CaseIterable, BackendFieldID {
    case authKind, keyPath
}

@Suite("FieldVisibility")
struct FieldVisibilityTests {
    private func keyPathField(condition: FieldCondition?) -> ConnectionField {
        ConnectionField(
            id: VField.keyPath.rawValue, labelKey: "k", labelDefault: "Key",
            kind: .text, visibleWhen: condition)
    }

    @Test func fieldWithoutConditionIsAlwaysVisible() {
        #expect(FieldVisibility.isVisible(keyPathField(condition: nil), in: FieldValues()))
    }

    @Test func conditionMatchesWhenTheFieldHasTheValue() {
        var values = FieldValues()
        values[VField.authKind] = "privateKey"
        let field = keyPathField(
            condition: FieldCondition(field: VField.authKind.rawValue, equals: "privateKey"))
        #expect(FieldVisibility.isVisible(field, in: values))
    }

    @Test func conditionFailsWhenTheFieldHasAnotherValue() {
        var values = FieldValues()
        values[VField.authKind] = "password"
        let field = keyPathField(
            condition: FieldCondition(field: VField.authKind.rawValue, equals: "privateKey"))
        #expect(!FieldVisibility.isVisible(field, in: values))
    }

    /// An unset controlling field means the condition does not hold. The
    /// alternative — showing everything until the user picks — would flash
    /// mutually exclusive fields on first open.
    @Test func conditionFailsWhenTheControllingFieldIsUnset() {
        let field = keyPathField(
            condition: FieldCondition(field: VField.authKind.rawValue, equals: "privateKey"))
        #expect(!FieldVisibility.isVisible(field, in: FieldValues()))
    }

    /// The condition compares against the namespaced key, so a same-named
    /// field in another backend cannot satisfy it.
    @Test func conditionResolvesAgainstTheOwningBackend() {
        var values = FieldValues()
        values[VField.authKind] = "privateKey"
        let field = keyPathField(
            condition: FieldCondition(field: VField.authKind.rawValue, equals: "privateKey"))
        #expect(FieldVisibility.isVisible(field, in: values, namespace: "VField"))
        #expect(!FieldVisibility.isVisible(field, in: values, namespace: "OtherBackendField"))
    }

    /// Which fields a form should render is a pure function of the schema and
    /// the current values. It lives in Core so it is provable without a view —
    /// the renderer in Task 7 does nothing but walk this list.
    @Test func visibleFieldsFiltersByCondition() {
        let schema = ConnectionFieldSchema(
            fields: [
                ConnectionField(id: VField.authKind.rawValue, labelKey: "a",
                                labelDefault: "Auth", kind: .text),
                keyPathField(condition: FieldCondition(
                    field: VField.authKind.rawValue, equals: "privateKey")),
            ],
            presets: [])

        var values = FieldValues()
        values[VField.authKind] = "password"
        #expect(schema.visibleFields(in: values, namespace: "VField").map(\.id)
            == [VField.authKind.rawValue])

        values[VField.authKind] = "privateKey"
        #expect(schema.visibleFields(in: values, namespace: "VField").map(\.id)
            == [VField.authKind.rawValue, VField.keyPath.rawValue])
    }

    /// A group's own leaves are filtered too, and the group survives even when
    /// some of its leaves do not.
    @Test func visibleLeavesFilterIndependentlyOfTheGroup() {
        let leaves = [
            LeafField(id: "always", labelKey: "a", labelDefault: "A", kind: .text),
            LeafField(id: "conditional", labelKey: "c", labelDefault: "C", kind: .text,
                      visibleWhen: FieldCondition(
                        field: VField.authKind.rawValue, equals: "privateKey")),
        ]
        let group = ConnectionField(id: "grp", labelKey: "g", labelDefault: "G",
                                    kind: .group(leaves))
        var values = FieldValues()
        values[VField.authKind] = "password"
        #expect(ConnectionFieldSchema.visibleLeaves(of: group, in: values,
                                                    namespace: "VField").map(\.id)
            == ["always"])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter "FieldVisibility"`
Expected: FAIL — `cannot find 'FieldCondition' in scope`

- [ ] **Step 3: Implement the vocabulary**

`Sources/macSCPCore/Capabilities/FieldVocabulary.swift`:

```swift
import Foundation

/// One option in a picker.
public struct FieldOption: Sendable, Equatable, Identifiable {
    public let id: String
    public let labelKey: String
    public let labelDefault: String

    public init(id: String, labelKey: String, labelDefault: String) {
        self.id = id; self.labelKey = labelKey; self.labelDefault = labelDefault
    }
}

/// Where a picker's options come from (M22).
///
/// A closed set on purpose. `managedKeys` and `loginSets` cannot be resolved
/// in Core — those stores live in the App — so the form is handed a resolver
/// that turns a source into options. Three cases means one `switch`, in one
/// place; an open-ended "options provider" would be the dispatcher we are
/// removing, wearing a different hat.
public enum OptionSource: Sendable, Equatable {
    case managedKeys
    case loginSets(kind: ConnectionKind)
    case fixed([FieldOption])
}

/// "Field X has value Y" — and deliberately nothing else. No and, no or, no
/// negation. This covers the only real case (SSH shows the key path only for
/// `authKind == privateKey`) and cannot grow into an expression language. A
/// backend that needs more is a reason to think, not a reason to extend this.
public struct FieldCondition: Sendable, Equatable {
    public let field: String
    public let equals: String

    public init(field: String, equals: String) {
        self.field = field; self.equals = equals
    }
}

/// A field inside a `.group`. Its `Kind` has no `.group` case, so nesting is
/// exactly one level deep — guaranteed by the type system rather than by a
/// validation test somebody can forget to run.
public struct LeafField: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case text, number, secret, toggle
        case picker(OptionSource)
    }

    public let id: String
    public let labelKey: String
    public let labelDefault: String
    public let kind: Kind
    public let visibleWhen: FieldCondition?

    public init(id: String, labelKey: String, labelDefault: String,
                kind: Kind, visibleWhen: FieldCondition? = nil) {
        self.id = id; self.labelKey = labelKey; self.labelDefault = labelDefault
        self.kind = kind; self.visibleWhen = visibleWhen
    }
}

/// Evaluates a field's visibility condition. Pure, so the rule is provable
/// without a view.
public enum FieldVisibility {
    public static func isVisible(
        _ field: ConnectionField, in values: FieldValues, namespace: String? = nil
    ) -> Bool {
        evaluate(field.visibleWhen, in: values, namespace: namespace)
    }

    public static func isVisible(
        _ field: LeafField, in values: FieldValues, namespace: String? = nil
    ) -> Bool {
        evaluate(field.visibleWhen, in: values, namespace: namespace)
    }

    private static func evaluate(
        _ condition: FieldCondition?, in values: FieldValues, namespace: String?
    ) -> Bool {
        guard let condition else { return true }
        // The controlling field is addressed the same way `FieldValues`
        // stores it: namespaced by the owning backend's enum type name.
        let actual: String?
        if let namespace {
            actual = values.raw["\(namespace).\(condition.field)"]
        } else {
            // No namespace given — match the one key ending in this field
            // name. Callers inside a backend always pass the namespace; this
            // branch exists for tests and for a schema rendered standalone.
            actual = values.raw.first { $0.key.hasSuffix(".\(condition.field)") }?.value
        }
        return actual == condition.equals
    }
}
```

- [ ] **Step 4: Extend `ConnectionField`**

In `Sources/macSCPCore/Capabilities/ConnectionFieldSchema.swift`, replace the `ConnectionField` declaration with:

```swift
/// One field the connection form should render for a protocol (M12, extended
/// in M22). `labelKey` is resolved to a localized string in the App layer
/// (Core stays bundle-free).
public struct ConnectionField: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case text, number, secret, toggle
        case picker(OptionSource)
        /// Exactly one level deep — `LeafField` has no group case.
        case group([LeafField])
    }

    public let id: String            // raw value of the backend's field enum
    public let labelKey: String      // L10n key
    public let labelDefault: String  // English fallback
    public let kind: Kind
    /// Shown only when this holds; nil means always.
    public let visibleWhen: FieldCondition?

    public var isSecret: Bool { kind == .secret }

    public init(id: String, labelKey: String, labelDefault: String,
                kind: Kind, visibleWhen: FieldCondition? = nil) {
        self.id = id; self.labelKey = labelKey; self.labelDefault = labelDefault
        self.kind = kind; self.visibleWhen = visibleWhen
    }
}
```

The existing S3 and WebDAV descriptors already call `ConnectionField(id:labelKey:labelDefault:kind:)` — the new parameter has a default, so they keep compiling unchanged.

Then add the filter, so "which fields does this form show right now" is a pure function in Core rather than logic buried in a view:

```swift
extension ConnectionFieldSchema {
    /// The fields a form should render for these values. Pure, so the rule is
    /// provable without a view — the renderer walks this and nothing else.
    public func visibleFields(in values: FieldValues, namespace: String) -> [ConnectionField] {
        fields.filter { FieldVisibility.isVisible($0, in: values, namespace: namespace) }
    }

    /// A group's visible leaves. A leaf's condition is evaluated the same way
    /// as a top-level field's, so a group can show and hide its own members.
    public static func visibleLeaves(
        of field: ConnectionField, in values: FieldValues, namespace: String
    ) -> [LeafField] {
        guard case .group(let leaves) = field.kind else { return [] }
        return leaves.filter { FieldVisibility.isVisible($0, in: values, namespace: namespace) }
    }
}
```

And give `ConnectionField.Kind` its leaf twin as an **optional** computed property, so the one impossible case cannot silently yield a wrong value:

```swift
extension ConnectionField.Kind {
    /// The `LeafField.Kind` this maps to, or nil for `.group` — which has no
    /// leaf equivalent by construction. Returning an Optional rather than a
    /// stand-in means a caller that forgets the group case fails to compile
    /// instead of quietly rendering a text field.
    public var asLeafKind: LeafField.Kind? {
        switch self {
        case .text: return .text
        case .number: return .number
        case .secret: return .secret
        case .toggle: return .toggle
        case .picker(let source): return .picker(source)
        case .group: return nil
        }
    }
}
```

- [ ] **Step 5: Run the tests and the full suite**

Run: `swift test --filter "FieldVisibility"` → PASS, 5 tests
Run: `swift test` → PASS, everything else unchanged

- [ ] **Step 6: Commit**

```bash
git add Sources/macSCPCore/Capabilities Tests/macSCPCoreTests/FieldVisibilityTests.swift
git commit -m "feat: add the declarative field vocabulary

Closed enums throughout: picker option sources are three cases, and the
visibility condition expresses exactly 'field X equals Y'. Nesting depth
is a type property -- a group holds LeafField, whose Kind has no group
case -- so one level deep is checked by the compiler, not by a test.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: The descriptor's new members, and the conformance check

The descriptor grows the members every later task reads, and Core gains the reusable conformance check that turns "a field nobody renders" from a silent gap into a test failure.

**Files:**
- Modify: `Sources/macSCPCore/Capabilities/BackendDescriptor.swift`
- Create: `Sources/macSCPCore/Capabilities/SchemaConformance.swift`
- Test: `Tests/macSCPCoreTests/SchemaConformanceTests.swift`

**Interfaces:**
- Consumes: Tasks 1–2
- Produces: on `BackendDescriptor` — `connectionSchema: ConnectionFieldSchema`, `credentialSchema: ConnectionFieldSchema`, `makeConfig: @Sendable (FieldValues, String) throws -> ConnectionConfig`, `displaySummary: @Sendable (FieldValues) -> String`, `secretEnvironmentVariable: String?`, `requiresSecret: Bool`; plus `enum SchemaConformance` with `static func check<F: BackendFieldID>(_ descriptor: BackendDescriptor, fields: F.Type) -> [String]`

- [ ] **Step 1: Write the failing test**

`Tests/macSCPCoreTests/SchemaConformanceTests.swift`:

```swift
import Foundation
import Testing
@testable import macSCPCore

private enum SampleField: String, CaseIterable, BackendFieldID {
    case alpha, beta, orphan
}

@Suite("SchemaConformance")
struct SchemaConformanceTests {
    private func descriptor(fieldIDs: [String]) -> BackendDescriptor {
        BackendDescriptor(
            kind: .s3,
            capabilities: BackendDescriptor.descriptor(for: .s3).capabilities,
            connectionSchema: ConnectionFieldSchema(
                fields: fieldIDs.map {
                    ConnectionField(id: $0, labelKey: "k", labelDefault: "L", kind: .text)
                },
                presets: []),
            credentialSchema: ConnectionFieldSchema(fields: [], presets: []),
            makeConfig: { _, _ in throw RemoteFSError.protocolError(reason: "unused") },
            displaySummary: { _ in "" },
            connect: { _, _, _ in throw RemoteFSError.protocolError(reason: "unused") },
            badgeLabelKey: "b", badgeLabelDefault: "B",
            secretEnvironmentVariable: nil, requiresSecret: false,
            fileActions: [], connectionActions: [])
    }

    /// The gap the compiler cannot see: a field the enum declares, that the
    /// factory may well handle, but that appears in NEITHER schema — so no
    /// form ever renders an input for it and the user cannot set it.
    @Test func reportsAFieldMissingFromBothSchemas() {
        let complaints = SchemaConformance.check(
            descriptor(fieldIDs: ["alpha", "beta"]), fields: SampleField.self)
        #expect(complaints.contains { $0.contains("orphan") })
    }

    @Test func acceptsADescriptorCoveringEveryField() {
        let complaints = SchemaConformance.check(
            descriptor(fieldIDs: ["alpha", "beta", "orphan"]), fields: SampleField.self)
        #expect(complaints.isEmpty)
    }

    /// The reverse gap: a schema entry whose id is not in the enum at all.
    /// Impossible to write today from typed call sites, but a decoded or
    /// hand-built schema could carry one.
    @Test func reportsASchemaFieldThatIsNotInTheEnum() {
        let complaints = SchemaConformance.check(
            descriptor(fieldIDs: ["alpha", "beta", "orphan", "ghost"]),
            fields: SampleField.self)
        #expect(complaints.contains { $0.contains("ghost") })
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter "SchemaConformance"`
Expected: FAIL — `extra argument 'connectionSchema' in call`

- [ ] **Step 3: Extend `BackendDescriptor`**

In `Sources/macSCPCore/Capabilities/BackendDescriptor.swift`, replace `fieldSchema` with the two schemas and add the closures and the two CLI axes. Keep `kind`, `capabilities`, `badgeLabelKey`, `badgeLabelDefault`, `fileActions`, `connectionActions` exactly as they are.

```swift
    public let connectionSchema: ConnectionFieldSchema
    public let credentialSchema: ConnectionFieldSchema

    /// Turns collected form values plus the resolved secret into a runtime
    /// config. The backend switches over its OWN field enum inside here, so
    /// the compiler checks that a newly added field is handled.
    public let makeConfig: @Sendable (FieldValues, String) throws -> ConnectionConfig

    /// A human label for the sidebar, the tab title and the audit trail.
    /// Before M22 those built `user@host` from fields S3 and WebDAV never
    /// fill, which is why the audit log carried `host: "unused"`.
    public let displaySummary: @Sendable (FieldValues) -> String

    /// Opens a connection. Living here rather than in a central dispatcher
    /// is what lets `BackendConnector` disappear (Task 10).
    public let connect: @Sendable (
        ConnectionConfig,
        @escaping ConnectionViewModel.HostKeyDecider,
        @escaping WebDAVSessionDelegate.CertificateDecider
    ) async throws -> any RemoteFileSystem

    /// The environment variable the CLI reads this backend's secret from.
    /// S3 uses the AWS-conventional name so existing pipelines need not
    /// relearn one; nil means the backend needs no secret.
    public let secretEnvironmentVariable: String?

    /// Whether connecting needs a secret at all. SSH with agent auth does
    /// not, which is why this is a value and not derived from the schema.
    public let requiresSecret: Bool
```

Update the initializer accordingly and adjust the three existing descriptors to pass `connectionSchema:` where they passed `fieldSchema:`, `credentialSchema: ConnectionFieldSchema(fields: [], presets: [])` for now, and placeholder closures that throw `RemoteFSError.protocolError(reason: "not migrated yet")`. Tasks 4–6 replace those per backend.

- [ ] **Step 4: Implement the conformance check**

`Sources/macSCPCore/Capabilities/SchemaConformance.swift`:

```swift
import Foundation

/// Checks that a backend's field enum and its two schemas agree (M22).
///
/// This catches the one gap an exhaustive `switch` in the factory cannot: a
/// field the enum declares and the factory handles, but that appears in
/// NEITHER schema — so no form renders an input for it and the user can
/// never set it. Nothing about that is a compile error.
public enum SchemaConformance {
    /// Returns one complaint per problem; empty means conformant.
    public static func check<F: BackendFieldID>(
        _ descriptor: BackendDescriptor, fields: F.Type
    ) -> [String] {
        let declared = Set(F.allCases.map(\.rawValue))
        let inSchemas = Set(
            ids(in: descriptor.connectionSchema) + ids(in: descriptor.credentialSchema))

        var complaints: [String] = []
        for missing in declared.subtracting(inSchemas).sorted() {
            complaints.append(
                "\(F.self).\(missing) is declared but appears in neither schema, "
                + "so no form can render it")
        }
        for unknown in inSchemas.subtracting(declared).sorted() {
            complaints.append("schema field \"\(unknown)\" is not a case of \(F.self)")
        }
        return complaints
    }

    private static func ids(in schema: ConnectionFieldSchema) -> [String] {
        schema.fields.flatMap { field -> [String] in
            if case .group(let leaves) = field.kind {
                return [field.id] + leaves.map(\.id)
            }
            return [field.id]
        }
    }
}
```

- [ ] **Step 5: Run tests and the full suite**

Run: `swift test --filter "SchemaConformance"` → PASS, 3 tests
Run: `swift test` → PASS

- [ ] **Step 6: Commit**

```bash
git add Sources/macSCPCore/Capabilities Tests/macSCPCoreTests/SchemaConformanceTests.swift
git commit -m "feat: give the descriptor its schemas, factory and CLI axes

Plus the conformance check for the one gap an exhaustive switch cannot
see: a field the enum declares and the factory handles, but that appears
in neither schema, so no form can render it.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: S3 goes data-driven

S3 first: its form is already schema-rendered, so it is the smallest real migration and the pattern the other two follow.

**Files:**
- Create: `Sources/macSCPCore/S3/S3FieldSchema.swift`
- Modify: `Sources/macSCPCore/Capabilities/BackendDescriptor.swift` (the S3 descriptor)
- Test: `Tests/macSCPCoreTests/S3FieldSchemaTests.swift`

**Interfaces:**
- Consumes: Tasks 1–3
- Produces: `enum S3Field: String, CaseIterable, BackendFieldID` with cases `endpoint, region, bucket, accessKeyID, secretAccessKey, usePathStyle`; `S3FieldSchema.connection`, `.credential`, `.makeConfig(_:_:)`, `.displaySummary(_:)`, `.values(from: StoredS3Config)`, `.stored(from: FieldValues)`

- [ ] **Step 1: Write the failing tests**

`Tests/macSCPCoreTests/S3FieldSchemaTests.swift`:

```swift
import Foundation
import Testing
@testable import macSCPCore

@Suite("S3FieldSchema")
struct S3FieldSchemaTests {
    private func filledValues() -> FieldValues {
        var values = FieldValues()
        values[S3Field.endpoint] = "https://minio.local:9000"
        values[S3Field.region] = "us-east-1"
        values[S3Field.bucket] = "backups"
        values[S3Field.accessKeyID] = "AKIA"
        values[bool: S3Field.usePathStyle] = true
        return values
    }

    @Test func schemaCoversEveryDeclaredField() {
        #expect(SchemaConformance.check(
            BackendDescriptor.descriptor(for: .s3), fields: S3Field.self).isEmpty)
    }

    /// The credential schema is what the login-set editor renders. Access key
    /// and secret belong to the login; endpoint and bucket belong to the
    /// connection.
    @Test func credentialSchemaCarriesOnlyTheLoginFields() {
        let ids = Set(BackendDescriptor.descriptor(for: .s3).credentialSchema.fields.map(\.id))
        #expect(ids == [S3Field.accessKeyID.rawValue, S3Field.secretAccessKey.rawValue])
    }

    @Test func makeConfigBuildsAnS3Config() throws {
        let config = try S3FieldSchema.makeConfig(filledValues(), "topsecret")
        guard case .s3(let s3) = config else {
            Issue.record("expected .s3, got \(config)")
            return
        }
        #expect(s3.endpoint == "https://minio.local:9000")
        #expect(s3.bucket == "backups")
        #expect(s3.usePathStyle == true)
        #expect(s3.secretAccessKey == "topsecret")
    }

    @Test func makeConfigRejectsAnEmptyBucket() {
        var values = filledValues()
        values[S3Field.bucket] = ""
        #expect(throws: (any Error).self) { _ = try S3FieldSchema.makeConfig(values, "s") }
    }

    /// The round trip the persistence adapter must satisfy: what the form
    /// collected survives being written to disk and read back.
    @Test func valuesRoundTripThroughTheStoredConfig() {
        let stored = S3FieldSchema.stored(from: filledValues())
        let back = S3FieldSchema.values(from: stored)
        #expect(back[S3Field.endpoint] == "https://minio.local:9000")
        #expect(back[S3Field.region] == "us-east-1")
        #expect(back[S3Field.bucket] == "backups")
        #expect(back[S3Field.accessKeyID] == "AKIA")
        #expect(back[bool: S3Field.usePathStyle] == true)
    }

    /// The stored config has no secret field at all, so the round trip must
    /// not carry one either.
    @Test func theRoundTripDropsTheSecret() {
        var values = filledValues()
        values[S3Field.secretAccessKey] = "topsecret"
        let back = S3FieldSchema.values(from: S3FieldSchema.stored(from: values))
        #expect(back[S3Field.secretAccessKey] == "")
    }

    @Test func displaySummaryNamesTheBucketAndEndpointHost() {
        #expect(S3FieldSchema.displaySummary(filledValues()) == "backups @ minio.local")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter "S3FieldSchema"`
Expected: FAIL — `cannot find 'S3Field' in scope`

- [ ] **Step 3: Implement**

`Sources/macSCPCore/S3/S3FieldSchema.swift`:

```swift
import Foundation

/// S3's field identifiers — the single source for its two schemas, its config
/// factory and its persistence adapter (M22).
public enum S3Field: String, CaseIterable, BackendFieldID {
    case endpoint, region, bucket, accessKeyID, secretAccessKey, usePathStyle
}

/// S3's data-driven registration (M22). Everything the generic layers need to
/// know about S3 lives here; nothing outside branches on `.s3`.
public enum S3FieldSchema {
    public static let connection = ConnectionFieldSchema(
        fields: [
            ConnectionField(id: S3Field.endpoint.rawValue,
                            labelKey: "connection.s3.endpoint", labelDefault: "Endpoint",
                            kind: .text),
            ConnectionField(id: S3Field.region.rawValue,
                            labelKey: "connection.s3.region", labelDefault: "Region",
                            kind: .text),
            ConnectionField(id: S3Field.bucket.rawValue,
                            labelKey: "connection.s3.bucket", labelDefault: "Bucket",
                            kind: .text),
            ConnectionField(id: S3Field.usePathStyle.rawValue,
                            labelKey: "connection.s3.pathStyle",
                            labelDefault: "Use path-style URLs", kind: .toggle),
        ],
        presets: [
            ConnectionPreset(id: "aws", nameKey: "connection.s3.preset.aws",
                             nameDefault: "Amazon S3",
                             values: [S3Field.endpoint.rawValue: "https://s3.amazonaws.com",
                                      S3Field.usePathStyle.rawValue: "false"]),
            ConnectionPreset(id: "hetzner", nameKey: "connection.s3.preset.hetzner",
                             nameDefault: "Hetzner Object Storage",
                             values: [S3Field.endpoint.rawValue: "https://fsn1.your-objectstorage.com",
                                      S3Field.usePathStyle.rawValue: "true"]),
            ConnectionPreset(id: "custom", nameKey: "connection.s3.preset.custom",
                             nameDefault: "Custom", values: [:]),
        ])

    /// What a login set carries: the credentials, not the endpoint. Rendered
    /// by the login-set editor with the same generic code as the form.
    public static let credential = ConnectionFieldSchema(
        fields: [
            ConnectionField(id: S3Field.accessKeyID.rawValue,
                            labelKey: "connection.s3.accessKey",
                            labelDefault: "Access Key ID", kind: .text),
            ConnectionField(id: S3Field.secretAccessKey.rawValue,
                            labelKey: "connection.s3.secretKey",
                            labelDefault: "Secret Access Key", kind: .secret),
        ],
        presets: [])

    public static func makeConfig(
        _ values: FieldValues, _ secret: String
    ) throws -> ConnectionConfig {
        // Switching over the field enum is what makes the compiler check that
        // a newly added field was considered here.
        for field in S3Field.allCases {
            switch field {
            case .bucket:
                guard !values[.bucket].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { throw RemoteFSError.connectionFailed(reason: "Enter the bucket") }
            case .endpoint:
                guard !values[.endpoint].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { throw RemoteFSError.connectionFailed(reason: "Enter the endpoint") }
            case .region, .accessKeyID, .secretAccessKey, .usePathStyle:
                break
            }
        }
        return .s3(S3ConnectionConfig(
            accessKeyID: values[.accessKeyID].trimmingCharacters(in: .whitespacesAndNewlines),
            secretAccessKey: secret,
            region: values[.region].trimmingCharacters(in: .whitespacesAndNewlines),
            endpoint: values[.endpoint].trimmingCharacters(in: .whitespacesAndNewlines),
            bucket: values[.bucket].trimmingCharacters(in: .whitespacesAndNewlines),
            usePathStyle: values[bool: .usePathStyle],
            sessionToken: nil))
    }

    /// Bucket and endpoint host — what identifies an S3 connection to a human.
    public static func displaySummary(_ values: FieldValues) -> String {
        let host = URL(string: values[.endpoint])?.host() ?? values[.endpoint]
        return "\(values[.bucket]) @ \(host)"
    }

    // MARK: - Persistence adapter

    /// The on-disk format is unchanged; this translates in both directions.
    public static func values(from stored: StoredS3Config) -> FieldValues {
        var values = FieldValues()
        values[.endpoint] = stored.endpoint
        values[.region] = stored.region
        values[.bucket] = stored.bucket
        values[.accessKeyID] = stored.accessKeyID
        values[bool: .usePathStyle] = stored.usePathStyle
        // secretAccessKey deliberately absent: it lives in the Keychain.
        return values
    }

    public static func stored(from values: FieldValues) -> StoredS3Config {
        StoredS3Config(
            accessKeyID: values[.accessKeyID], region: values[.region],
            endpoint: values[.endpoint], bucket: values[.bucket],
            usePathStyle: values[bool: .usePathStyle])
    }
}
```

Then point the S3 descriptor at these: `connectionSchema: S3FieldSchema.connection`, `credentialSchema: S3FieldSchema.credential`, `makeConfig: S3FieldSchema.makeConfig`, `displaySummary: S3FieldSchema.displaySummary`, `secretEnvironmentVariable: "AWS_SECRET_ACCESS_KEY"`, `requiresSecret: true`, and `connect: { config, _, _ in guard case .s3(let s3) = config else { throw RemoteFSError.protocolError(reason: "wrong config for the S3 backend") }; return try await S3FileSystem.connect(s3) }`.

- [ ] **Step 4: Run tests and the full suite**

Run: `swift test --filter "S3FieldSchema"` → PASS, 7 tests
Run: `swift test` → PASS, existing S3 tests unchanged and green

- [ ] **Step 5: Commit**

```bash
git add Sources/macSCPCore/S3/S3FieldSchema.swift Sources/macSCPCore/Capabilities/BackendDescriptor.swift Tests/macSCPCoreTests/S3FieldSchemaTests.swift
git commit -m "feat(s3): declare S3 through the field schema

Field enum, both schemas, config factory, display summary and the
persistence adapter. The on-disk StoredS3Config is untouched -- the
adapter translates in both directions.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: WebDAV goes data-driven

Same shape as Task 4. Read `Sources/macSCPCore/S3/S3FieldSchema.swift` first and follow it — the two files should be recognisably siblings.

**Files:**
- Create: `Sources/macSCPCore/WebDAV/WebDAVFieldSchema.swift`
- Modify: `Sources/macSCPCore/Capabilities/BackendDescriptor.swift` (the WebDAV descriptor)
- Test: `Tests/macSCPCoreTests/WebDAVFieldSchemaTests.swift`

**Interfaces:**
- Consumes: Tasks 1–4
- Produces: `enum WebDAVField: String, CaseIterable, BackendFieldID` with cases `baseURL, username, password, useNextcloudPath`; `WebDAVFieldSchema.connection`, `.credential`, `.makeConfig(_:_:)`, `.displaySummary(_:)`, `.values(from: StoredWebDAVConfig)`, `.stored(from: FieldValues)`

- [ ] **Step 1: Write the failing tests**

`Tests/macSCPCoreTests/WebDAVFieldSchemaTests.swift`:

```swift
import Foundation
import Testing
@testable import macSCPCore

@Suite("WebDAVFieldSchema")
struct WebDAVFieldSchemaTests {
    private func filledValues() -> FieldValues {
        var values = FieldValues()
        values[WebDAVField.baseURL] = "https://cloud.example.com"
        values[WebDAVField.username] = "tim"
        values[bool: WebDAVField.useNextcloudPath] = true
        return values
    }

    @Test func schemaCoversEveryDeclaredField() {
        #expect(SchemaConformance.check(
            BackendDescriptor.descriptor(for: .webdav), fields: WebDAVField.self).isEmpty)
    }

    /// Username and password are the login; the URL and the Nextcloud toggle
    /// describe the server. This split is what makes a WebDAV login set work
    /// with no WebDAV-specific UI.
    @Test func credentialSchemaCarriesOnlyTheLoginFields() {
        let ids = Set(BackendDescriptor.descriptor(for: .webdav).credentialSchema.fields.map(\.id))
        #expect(ids == [WebDAVField.username.rawValue, WebDAVField.password.rawValue])
    }

    @Test func makeConfigBuildsAWebDAVConfig() throws {
        let config = try WebDAVFieldSchema.makeConfig(filledValues(), "app-password")
        guard case .webdav(let dav) = config else {
            Issue.record("expected .webdav, got \(config)")
            return
        }
        #expect(dav.baseURL == "https://cloud.example.com")
        #expect(dav.username == "tim")
        #expect(dav.useNextcloudPath == true)
        #expect(dav.password == "app-password")
    }

    /// A URL pasted from a browser address bar routinely carries trailing
    /// whitespace.
    @Test func makeConfigTrimsTheBaseURL() throws {
        var values = filledValues()
        values[WebDAVField.baseURL] = "  https://cloud.example.com  "
        let config = try WebDAVFieldSchema.makeConfig(values, "p")
        guard case .webdav(let dav) = config else {
            Issue.record("expected .webdav")
            return
        }
        #expect(dav.baseURL == "https://cloud.example.com")
    }

    @Test func makeConfigRejectsAnEmptyBaseURL() {
        var values = filledValues()
        values[WebDAVField.baseURL] = "   "
        #expect(throws: (any Error).self) { _ = try WebDAVFieldSchema.makeConfig(values, "p") }
    }

    @Test func valuesRoundTripThroughTheStoredConfig() {
        let back = WebDAVFieldSchema.values(from: WebDAVFieldSchema.stored(from: filledValues()))
        #expect(back[WebDAVField.baseURL] == "https://cloud.example.com")
        #expect(back[WebDAVField.username] == "tim")
        #expect(back[bool: WebDAVField.useNextcloudPath] == true)
    }

    @Test func theRoundTripDropsTheSecret() {
        var values = filledValues()
        values[WebDAVField.password] = "app-password"
        let back = WebDAVFieldSchema.values(from: WebDAVFieldSchema.stored(from: values))
        #expect(back[WebDAVField.password] == "")
    }

    @Test func displaySummaryNamesTheUserAndHost() {
        #expect(WebDAVFieldSchema.displaySummary(filledValues()) == "tim @ cloud.example.com")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter "WebDAVFieldSchema"`
Expected: FAIL — `cannot find 'WebDAVField' in scope`

- [ ] **Step 3: Implement**

`Sources/macSCPCore/WebDAV/WebDAVFieldSchema.swift`, following `S3FieldSchema` exactly in shape:

```swift
import Foundation

/// WebDAV's field identifiers (M22).
public enum WebDAVField: String, CaseIterable, BackendFieldID {
    case baseURL, username, password, useNextcloudPath
}

public enum WebDAVFieldSchema {
    public static let connection = ConnectionFieldSchema(
        fields: [
            ConnectionField(id: WebDAVField.baseURL.rawValue,
                            labelKey: "connection.webdav.baseURL",
                            labelDefault: "Server URL", kind: .text),
            ConnectionField(id: WebDAVField.useNextcloudPath.rawValue,
                            labelKey: "connection.webdav.nextcloudPath",
                            labelDefault: "Append Nextcloud path", kind: .toggle),
        ],
        presets: [
            ConnectionPreset(id: "nextcloud", nameKey: "connection.webdav.preset.nextcloud",
                             nameDefault: "Nextcloud / ownCloud",
                             values: [WebDAVField.useNextcloudPath.rawValue: "true"]),
            ConnectionPreset(id: "custom", nameKey: "connection.webdav.preset.custom",
                             nameDefault: "Custom",
                             values: [WebDAVField.useNextcloudPath.rawValue: "false"]),
        ])

    public static let credential = ConnectionFieldSchema(
        fields: [
            ConnectionField(id: WebDAVField.username.rawValue,
                            labelKey: "connection.webdav.username",
                            labelDefault: "User name", kind: .text),
            ConnectionField(id: WebDAVField.password.rawValue,
                            labelKey: "connection.webdav.password",
                            labelDefault: "Password", kind: .secret),
        ],
        presets: [])

    public static func makeConfig(
        _ values: FieldValues, _ secret: String
    ) throws -> ConnectionConfig {
        for field in WebDAVField.allCases {
            switch field {
            case .baseURL:
                guard !values[.baseURL].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { throw RemoteFSError.connectionFailed(reason: "Enter the server URL") }
            case .username, .password, .useNextcloudPath:
                break
            }
        }
        return .webdav(WebDAVConnectionConfig(
            baseURL: values[.baseURL].trimmingCharacters(in: .whitespacesAndNewlines),
            username: values[.username].trimmingCharacters(in: .whitespacesAndNewlines),
            useNextcloudPath: values[bool: .useNextcloudPath],
            password: secret))
    }

    public static func displaySummary(_ values: FieldValues) -> String {
        let host = URL(string: values[.baseURL])?.host() ?? values[.baseURL]
        return "\(values[.username]) @ \(host)"
    }

    public static func values(from stored: StoredWebDAVConfig) -> FieldValues {
        var values = FieldValues()
        values[.baseURL] = stored.baseURL
        values[.username] = stored.username
        values[bool: .useNextcloudPath] = stored.useNextcloudPath
        return values
    }

    public static func stored(from values: FieldValues) -> StoredWebDAVConfig {
        StoredWebDAVConfig(
            baseURL: values[.baseURL], username: values[.username],
            useNextcloudPath: values[bool: .useNextcloudPath])
    }
}
```

Point the WebDAV descriptor at these, with `secretEnvironmentVariable: "MACSCP_PASSWORD"`, `requiresSecret: true`, and a `connect` closure that unwraps `.webdav` and calls `WebDAVFileSystem.connect(_:trustStore:decider:)` with `TrustedCertificateStore(directory: SessionStore.defaultDirectory)`.

- [ ] **Step 4: Run tests and the full suite**

Run: `swift test --filter "WebDAVFieldSchema"` → PASS, 8 tests
Run: `swift test` → PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/macSCPCore/WebDAV/WebDAVFieldSchema.swift Sources/macSCPCore/Capabilities/BackendDescriptor.swift Tests/macSCPCoreTests/WebDAVFieldSchemaTests.swift
git commit -m "feat(webdav): declare WebDAV through the field schema

Username and password move into the credential schema, which is what
makes a WebDAV login set fall out of the generic editor rather than
needing its own UI.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: SSH goes data-driven

The hard one. SSH has three auth kinds, a managed-key picker whose options come from a store the Core cannot see, and a jump host that is a second login inside the form.

**Files:**
- Create: `Sources/macSCPCore/SSH/SSHFieldSchema.swift`
- Modify: `Sources/macSCPCore/Capabilities/BackendDescriptor.swift` (the SSH descriptor)
- Test: `Tests/macSCPCoreTests/SSHFieldSchemaTests.swift`

**Interfaces:**
- Consumes: Tasks 1–5
- Produces: `enum SSHField: String, CaseIterable, BackendFieldID` with cases `host, port, username, authKind, keyPath, managedKeyID, password, jump`; `enum SSHJumpField: String, CaseIterable, BackendFieldID` with cases `host, port, username, authKind, keyPath, managedKeyID, password`; `SSHFieldSchema.connection`, `.credential`, `.makeConfig(_:_:)`, `.displaySummary(_:)`, `.values(from: StoredSession)`, `.apply(_ values: FieldValues, to: inout StoredSession)`

**If the jump group turns out not to fit the one-level vocabulary, stop and report NEEDS_CONTEXT rather than widening the vocabulary on your own.** The spec names this as the first place the implementation should pause and ask.

To be precise about what "widening" means, because the two are easy to confuse: the **vocabulary** is `ConnectionField.Kind`, `LeafField.Kind`, `OptionSource` and `FieldCondition` — those are frozen, and needing a new case in any of them is a design question to escalate. A **backend's own field enum** is not the vocabulary; adding a case to `SSHField` is ordinary modelling and needs no permission.

**Why SSH has both `password` and `passphrase`, sharing one keychain slot.** SSH stores exactly one secret per login, but it means two different things: a password under `.password` auth, a key passphrase under `.privateKey`, and nothing at all under `.agent`. The shipped login-set editor already renders them as two differently-labelled rows (`connection.auth.password` vs `connection.field.passphrase`, the latter marked optional) and shows neither for agent logins — a deliberate M10d decision, commented in `LoginSetsSheet.swift` as "only Name + Username apply".

One unconditional field could not reproduce that: it would either make passphrases unenterable (if conditioned on `.password`) or grow a meaningless secret row on agent logins (if left unconditional), regressing shipped behaviour. Two conditional fields describe what the UI already is, and keep `FieldCondition` at "equals". Both map to the same Keychain entry — `makeConfig` never reads either, because the resolved secret arrives as its second parameter and `authKind` decides what it means.

- [ ] **Step 1: Write the failing tests**

`Tests/macSCPCoreTests/SSHFieldSchemaTests.swift`:

```swift
import Foundation
import Testing
@testable import macSCPCore

@Suite("SSHFieldSchema")
struct SSHFieldSchemaTests {
    private func passwordValues() -> FieldValues {
        var values = FieldValues()
        values[SSHField.host] = "server.example.com"
        values[SSHField.port] = "22"
        values[SSHField.username] = "tim"
        values[SSHField.authKind] = "password"
        return values
    }

    @Test func schemaCoversEveryDeclaredField() {
        #expect(SchemaConformance.check(
            BackendDescriptor.descriptor(for: .ssh), fields: SSHField.self).isEmpty)
    }

    @Test func makeConfigBuildsPasswordAuth() throws {
        let config = try SSHFieldSchema.makeConfig(passwordValues(), "hunter2")
        guard case .ssh(let ssh) = config else {
            Issue.record("expected .ssh, got \(config)")
            return
        }
        #expect(ssh.host == "server.example.com")
        #expect(ssh.port == 22)
        #expect(ssh.auth == .password("hunter2"))
    }

    @Test func makeConfigBuildsPrivateKeyAuth() throws {
        var values = passwordValues()
        values[SSHField.authKind] = "privateKey"
        values[SSHField.keyPath] = "/Users/tim/.ssh/id_ed25519"
        let config = try SSHFieldSchema.makeConfig(values, "passphrase")
        guard case .ssh(let ssh) = config else {
            Issue.record("expected .ssh")
            return
        }
        #expect(ssh.auth == .privateKey(
            keyPath: "/Users/tim/.ssh/id_ed25519", passphrase: "passphrase"))
    }

    /// Agent auth needs no secret at all — an empty one must not turn into an
    /// empty password.
    @Test func makeConfigBuildsAgentAuthWithoutASecret() throws {
        var values = passwordValues()
        values[SSHField.authKind] = "agent"
        let config = try SSHFieldSchema.makeConfig(values, "")
        guard case .ssh(let ssh) = config else {
            Issue.record("expected .ssh")
            return
        }
        #expect(ssh.auth == .agent)
    }

    @Test func makeConfigRejectsPrivateKeyAuthWithoutAPath() {
        var values = passwordValues()
        values[SSHField.authKind] = "privateKey"
        values[SSHField.keyPath] = "   "
        #expect(throws: (any Error).self) { _ = try SSHFieldSchema.makeConfig(values, "p") }
    }

    /// The key path is only shown for private-key auth. That rule lives in the
    /// schema, so the form does not have to know it.
    @Test func theKeyPathFieldIsConditionalOnTheAuthKind() throws {
        let schema = BackendDescriptor.descriptor(for: .ssh).connectionSchema
        let keyPath = try #require(schema.fields.first { $0.id == SSHField.keyPath.rawValue })
        let condition = try #require(keyPath.visibleWhen)
        #expect(condition.field == SSHField.authKind.rawValue)
        #expect(condition.equals == "privateKey")

        var values = passwordValues()
        #expect(!FieldVisibility.isVisible(keyPath, in: values, namespace: "SSHField"))
        values[SSHField.authKind] = "privateKey"
        #expect(FieldVisibility.isVisible(keyPath, in: values, namespace: "SSHField"))
    }

    /// The managed-key picker's options come from a store the Core cannot
    /// reach, so the schema names the source and the App resolves it.
    @Test func theManagedKeyFieldIsAPickerOverManagedKeys() throws {
        let schema = BackendDescriptor.descriptor(for: .ssh).connectionSchema
        let field = try #require(schema.fields.first { $0.id == SSHField.managedKeyID.rawValue })
        guard case .picker(let source) = field.kind else {
            Issue.record("expected a picker, got \(field.kind)")
            return
        }
        #expect(source == .managedKeys)
    }

    /// The jump host is one group, exactly one level deep.
    @Test func theJumpFieldIsAGroupOfLeafFields() throws {
        let schema = BackendDescriptor.descriptor(for: .ssh).connectionSchema
        let field = try #require(schema.fields.first { $0.id == SSHField.jump.rawValue })
        guard case .group(let leaves) = field.kind else {
            Issue.record("expected a group, got \(field.kind)")
            return
        }
        #expect(Set(leaves.map(\.id)) == Set(SSHJumpField.allCases.map(\.rawValue)))
    }

    @Test func valuesRoundTripThroughTheStoredSession() {
        var session = StoredSession(
            name: "prod", host: "server.example.com", port: 22, username: "tim")
        SSHFieldSchema.apply(passwordValues(), to: &session)
        let back = SSHFieldSchema.values(from: session)
        #expect(back[SSHField.host] == "server.example.com")
        #expect(back[SSHField.port] == "22")
        #expect(back[SSHField.username] == "tim")
        #expect(back[SSHField.authKind] == "password")
    }

    @Test func displaySummaryIsUserAtHost() {
        #expect(SSHFieldSchema.displaySummary(passwordValues()) == "tim@server.example.com")
    }
}
```

Adjust the `StoredSession(...)` call to the type's real initialiser — run `grep -n "public init" Sources/macSCPCore/Sessions/StoredSession.swift` first and match it.

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter "SSHFieldSchema"`
Expected: FAIL — `cannot find 'SSHField' in scope`

- [ ] **Step 3: Implement**

`Sources/macSCPCore/SSH/SSHFieldSchema.swift`. The auth kind is a fixed picker; the key path and the managed-key picker hang off it by condition; the jump host is one `.group`.

```swift
import Foundation

public enum SSHField: String, CaseIterable, BackendFieldID {
    case host, port, username, authKind, keyPath, managedKeyID, password, passphrase, jump
}

/// The jump host's own login. A separate enum because a `.group` holds
/// `LeafField`, which cannot nest further — one level is all SSH needs.
public enum SSHJumpField: String, CaseIterable, BackendFieldID {
    case host, port, username, authKind, keyPath, managedKeyID, password
}

public enum SSHFieldSchema {
    private static let authOptions = [
        FieldOption(id: "password", labelKey: "connection.auth.password",
                    labelDefault: "Password"),
        FieldOption(id: "privateKey", labelKey: "connection.auth.privateKey",
                    labelDefault: "Private key"),
        FieldOption(id: "agent", labelKey: "connection.auth.agent",
                    labelDefault: "SSH agent"),
    ]

    private static let onPrivateKey = FieldCondition(
        field: SSHField.authKind.rawValue, equals: "privateKey")
    private static let onPassword = FieldCondition(
        field: SSHField.authKind.rawValue, equals: "password")

    public static let connection = ConnectionFieldSchema(
        fields: [
            ConnectionField(id: SSHField.host.rawValue, labelKey: "connection.field.host",
                            labelDefault: "Host", kind: .text),
            ConnectionField(id: SSHField.port.rawValue, labelKey: "connection.field.port",
                            labelDefault: "Port", kind: .number),
            ConnectionField(id: SSHField.username.rawValue,
                            labelKey: "connection.field.username",
                            labelDefault: "User name", kind: .text),
            ConnectionField(id: SSHField.authKind.rawValue,
                            labelKey: "connection.field.authKind",
                            labelDefault: "Authentication",
                            kind: .picker(.fixed(authOptions))),
            ConnectionField(id: SSHField.password.rawValue,
                            labelKey: "connection.field.password",
                            labelDefault: "Password", kind: .secret,
                            visibleWhen: onPassword),
            ConnectionField(id: SSHField.keyPath.rawValue,
                            labelKey: "connection.field.keyPath",
                            labelDefault: "Key file", kind: .text,
                            visibleWhen: onPrivateKey),
            ConnectionField(id: SSHField.managedKeyID.rawValue,
                            labelKey: "connection.field.managedKey",
                            labelDefault: "Managed key",
                            kind: .picker(.managedKeys), visibleWhen: onPrivateKey),
            ConnectionField(id: SSHField.jump.rawValue, labelKey: "connection.jump.title",
                            labelDefault: "Jump host", kind: .group(jumpLeaves)),
        ],
        presets: [])

    private static let jumpLeaves: [LeafField] = [
        LeafField(id: SSHJumpField.host.rawValue, labelKey: "connection.field.host",
                  labelDefault: "Host", kind: .text),
        LeafField(id: SSHJumpField.port.rawValue, labelKey: "connection.field.port",
                  labelDefault: "Port", kind: .number),
        LeafField(id: SSHJumpField.username.rawValue, labelKey: "connection.field.username",
                  labelDefault: "User name", kind: .text),
        LeafField(id: SSHJumpField.authKind.rawValue, labelKey: "connection.field.authKind",
                  labelDefault: "Authentication", kind: .picker(.fixed(authOptions))),
        LeafField(id: SSHJumpField.password.rawValue, labelKey: "connection.field.password",
                  labelDefault: "Password", kind: .secret),
        LeafField(id: SSHJumpField.keyPath.rawValue, labelKey: "connection.field.keyPath",
                  labelDefault: "Key file", kind: .text),
        LeafField(id: SSHJumpField.managedKeyID.rawValue,
                  labelKey: "connection.field.managedKey",
                  labelDefault: "Managed key", kind: .picker(.managedKeys)),
    ]

    public static let credential = ConnectionFieldSchema(
        fields: [
            ConnectionField(id: SSHField.username.rawValue,
                            labelKey: "connection.field.username",
                            labelDefault: "User name", kind: .text),
            ConnectionField(id: SSHField.authKind.rawValue,
                            labelKey: "connection.field.authKind",
                            labelDefault: "Authentication",
                            kind: .picker(.fixed(authOptions))),
            ConnectionField(id: SSHField.password.rawValue,
                            labelKey: "connection.field.password",
                            labelDefault: "Password", kind: .secret,
                            visibleWhen: onPassword),
            ConnectionField(id: SSHField.keyPath.rawValue,
                            labelKey: "connection.field.keyPath",
                            labelDefault: "Key file", kind: .text,
                            visibleWhen: onPrivateKey),
            ConnectionField(id: SSHField.managedKeyID.rawValue,
                            labelKey: "connection.field.managedKey",
                            labelDefault: "Managed key",
                            kind: .picker(.managedKeys), visibleWhen: onPrivateKey),
        ],
        presets: [])

    public static func makeConfig(
        _ values: FieldValues, _ secret: String
    ) throws -> ConnectionConfig {
        let auth: SSHConnectionConfig.AuthMethod
        switch values[SSHField.authKind] {
        case "privateKey":
            let path = values[SSHField.keyPath]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else {
                throw RemoteFSError.connectionFailed(reason: "Choose a key file")
            }
            auth = .privateKey(keyPath: path, passphrase: secret.isEmpty ? nil : secret)
        case "agent":
            // Agent auth carries no secret: an empty one must not become an
            // empty password, which a server would reject confusingly.
            auth = .agent
        default:
            auth = .password(secret)
        }
        return .ssh(try SSHConnectionConfig(
            host: values[SSHField.host].trimmingCharacters(in: .whitespacesAndNewlines),
            port: Int(values[SSHField.port]) ?? 22,
            username: values[SSHField.username]
                .trimmingCharacters(in: .whitespacesAndNewlines),
            auth: auth))
    }

    public static func displaySummary(_ values: FieldValues) -> String {
        "\(values[SSHField.username])@\(values[SSHField.host])"
    }

    public static func values(from session: StoredSession) -> FieldValues {
        var values = FieldValues()
        values[SSHField.host] = session.host
        values[SSHField.port] = String(session.port)
        values[SSHField.username] = session.username
        values[SSHField.authKind] = session.authKind.rawValue
        values[SSHField.keyPath] = session.keyPath ?? ""
        return values
    }

    public static func apply(_ values: FieldValues, to session: inout StoredSession) {
        session.host = values[SSHField.host]
        session.port = Int(values[SSHField.port]) ?? 22
        session.username = values[SSHField.username]
        if let kind = StoredSession.AuthKind(rawValue: values[SSHField.authKind]) {
            session.authKind = kind
        }
        let path = values[SSHField.keyPath]
        session.keyPath = path.isEmpty ? nil : path
    }
}
```

Point the SSH descriptor at these, with `secretEnvironmentVariable: "MACSCP_PASSWORD"`, `requiresSecret: true` (the agent case is handled by the factory, not by refusing to ask), and a `connect` closure that unwraps `.ssh` and calls `CitadelFileSystem.connect(config:knownHosts:onUnknownHostKey:)`.

- [ ] **Step 4: Run tests and the full suite**

Run: `swift test --filter "SSHFieldSchema"` → PASS, 10 tests
Run: `swift test` → PASS, the existing SSH tests unchanged and green

- [ ] **Step 5: Commit**

```bash
git add Sources/macSCPCore/SSH/SSHFieldSchema.swift Sources/macSCPCore/Capabilities/BackendDescriptor.swift Tests/macSCPCoreTests/SSHFieldSchemaTests.swift
git commit -m "feat(ssh): declare SSH through the field schema

Auth kind is a fixed picker; the key path and the managed-key picker hang
off it by visibility condition; the jump host is one group of leaf
fields, exactly one level deep.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: The generic form renderer

One renderer for all three backends. The App contributes exactly one thing: a resolver that turns an `OptionSource` into options, because `managedKeys` and `loginSets` live in stores the Core cannot see.

**Files:**
- Create: `Sources/MacSCPApp/SchemaFormView.swift`
- Modify: `Sources/MacSCPApp/ConnectionFormView.swift`
- Test: none new — see the note below

**Interfaces:**
- Consumes: Tasks 1–6
- Produces: `struct SchemaFormView: View` — `init(schema: ConnectionFieldSchema, values: Binding<FieldValues>, namespace: String, isEditMode: Bool, resolve: @escaping (OptionSource) -> [FieldOption])`

**No new tests in this task, and that is deliberate.** Every rule this view obeys was already made testable and tested elsewhere: which fields are visible is `ConnectionFieldSchema.visibleFields` (Task 2), which fields exist at all is the conformance check (Tasks 4–6). What remains here is SwiftUI wiring, which this project does not unit-test — consistent with every prior App-layer task. Do not invent a test that asserts an enum pattern-matches itself in order to have one; the verification for this task is the build, the full suite staying green, and the L10n key-set guard.

- [ ] **Step 1: Build the renderer**

`FormRow` is currently `private struct FormRow` at `ConnectionFormView.swift:1091`. Drop the `private` so the new file can use it — the label column width of 110 and the `firstTextBaseline` alignment are the house rhythm every form in the app already follows, and reimplementing them would drift.

`Sources/MacSCPApp/SchemaFormView.swift`:

```swift
import SwiftUI
import macSCPCore

/// Renders any backend's schema (M22). One view for every protocol: the
/// dispatcher this replaces had a hand-written section per backend, which is
/// why adding WebDAV in M21 meant touching six switch statements.
///
/// The App contributes exactly one thing — `resolve`, which turns an
/// `OptionSource` into options — because managed keys and login sets live in
/// stores Core cannot see.
struct SchemaFormView: View {
    let schema: ConnectionFieldSchema
    @Binding var values: FieldValues
    /// The backend field enum's type name, so a condition resolves against
    /// the owning backend and not a same-named field in another.
    let namespace: String
    let isEditMode: Bool
    let resolve: (OptionSource) -> [FieldOption]

    @State private var selectedPresetID: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !schema.presets.isEmpty { presetPicker }
            // The filter is Core's, and tested there — this view walks the
            // result and renders it, holding no visibility rules of its own.
            ForEach(schema.visibleFields(in: values, namespace: namespace)) { field in
                row(for: field)
            }
        }
    }

    @ViewBuilder
    private func row(for field: ConnectionField) -> some View {
        if let leafKind = field.kind.asLeafKind {
            FormRow(label: L10n.string(field.labelKey, field.labelDefault)) {
                control(kind: leafKind, binding: binding(field.id))
            }
        } else {
            // nil asLeafKind means `.group` — the only case without a leaf twin.
            GroupBox(label: Text(L10n.string(field.labelKey, field.labelDefault))) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(ConnectionFieldSchema.visibleLeaves(
                        of: field, in: values, namespace: namespace)) { leaf in
                        FormRow(label: L10n.string(leaf.labelKey, leaf.labelDefault)) {
                            control(kind: leaf.kind, binding: binding(field.id, leaf.id))
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private func control(kind: LeafField.Kind, binding: Binding<String>) -> some View {
        switch kind {
        case .text, .number:
            TextField("", text: binding).textFieldStyle(.roundedBorder)
        case .secret:
            // In edit mode a stored secret is never read back out of the
            // Keychain to prefill the field; an empty field means "keep the
            // stored one", which the placeholder has to say out loud.
            SecureField(isEditMode
                ? L10n.string("connection.secret.unchanged", "unchanged")
                : "", text: binding)
                .textFieldStyle(.roundedBorder)
        case .toggle:
            Toggle("", isOn: Binding(
                get: { binding.wrappedValue == "true" },
                set: { binding.wrappedValue = $0 ? "true" : "false" }))
                .labelsHidden()
        case .picker(let source):
            let options = resolve(source)
            Picker("", selection: binding) {
                ForEach(options) { option in
                    Text(L10n.string(option.labelKey, option.labelDefault)).tag(option.id)
                }
            }
            .labelsHidden()
        }
    }

    /// Mirrors the existing S3 preset picker at `ConnectionFormView.swift:785`
    /// — the selection is real state, so the field shows which provider is
    /// chosen rather than snapping back to blank after each pick.
    private var presetPicker: some View {
        FormRow(label: L10n.string("connection.preset", "Provider")) {
            Picker("", selection: Binding(
                get: { selectedPresetID },
                set: { id in
                    selectedPresetID = id
                    guard let preset = schema.presets.first(where: { $0.id == id })
                    else { return }
                    for (fieldID, value) in preset.values {
                        values.setRaw("\(namespace).\(fieldID)", to: value)
                    }
                })) {
                ForEach(schema.presets) { preset in
                    Text(L10n.string(preset.nameKey, preset.nameDefault)).tag(preset.id)
                }
            }
            .labelsHidden()
        }
    }

    private func binding(_ fieldID: String, _ leafID: String? = nil) -> Binding<String> {
        let key = leafID.map { "\(namespace).\(fieldID).\($0)" }
            ?? "\(namespace).\(fieldID)"
        return Binding(
            get: { values.raw[key] ?? "" },
            set: { values.setRaw(key, to: $0) })
    }
}
```

This needs one addition to `FieldValues` (Task 1's type) — a raw setter, so the renderer can write by full key without knowing the field enum's static type. Note the name: `raw` is already a property, and Swift will not let a method share that base name.

```swift
    /// Writes by full namespaced key. The generic form renderer needs this
    /// because it holds an id string, not a statically-typed field case.
    public mutating func setRaw(_ key: String, to value: String) {
        storage[key] = value
    }
```

Add it in this task, not Task 1 — it exists only because the renderer exists, and a setter with no reader is exactly the kind of speculative API the design asks us not to write.

- [ ] **Step 2: Replace the S3 and WebDAV sections**

In `ConnectionFormView.swift`, delete `s3Section`, `s3FieldRow`, `s3TextBinding`, `applyS3Preset`, `webdavSection`, `webdavFieldRow`, `webdavTextBinding`, `applyWebDAVPreset` and the `s3CredentialFieldIDs` set. Render instead:

```swift
SchemaFormView(
    schema: BackendDescriptor.descriptor(for: viewModel.kind).connectionSchema,
    values: $viewModel.values,
    namespace: namespace(for: viewModel.kind),
    isEditMode: isEditMode,
    resolve: resolveOptions)
```

`resolveOptions` is the one `switch` over `OptionSource`: `.managedKeys` reads the `ManagedKeyStore`, `.loginSets(kind:)` reads the login sets filtered by kind, `.fixed(let options)` returns them unchanged.

Leave the SSH section in place for now — Task 8 moves it.

- [ ] **Step 3: Localize the new keys**

`connection.preset` and `connection.secret.unchanged` are new. Add both to **all four** catalogs (`en`/`de`/`fr`/`pl`) — the key-set guard test fails otherwise, and French uses the typographic apostrophe (U+2019). Check first whether the existing S3/WebDAV sections already carry equivalents under other names; reuse beats a duplicate key.

- [ ] **Step 4: Run the full suite and check the build**

Run: `swift test` → PASS, including the catalog key-set guard
Run: `swift build 2>&1 | grep warning | grep -E "SchemaFormView|ConnectionFormView"` → prints nothing

- [ ] **Step 5: Commit**

```bash
git add Sources/MacSCPApp Sources/macSCPCore
git commit -m "feat: render connection forms from the schema

One renderer for every backend. The App contributes exactly one thing --
a resolver turning an OptionSource into options -- because managed keys
and login sets live in stores Core cannot see.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 8: SSH onto the generic renderer, and the view model on `FieldValues`

The riskiest UI task: the most-used form in the app moves onto the generic path, and `ConnectionViewModel` loses its typed properties.

**Files:**
- Modify: `Sources/macSCPCore/Presentation/ConnectionViewModel.swift`
- Modify: `Sources/MacSCPApp/ConnectionFormView.swift`
- Test: `Tests/macSCPCoreTests/ConnectionViewModelSchemaTests.swift`

**Interfaces:**
- Consumes: Tasks 1–7
- Produces: `ConnectionViewModel.values: FieldValues`; `connect()` and `validateForEditSave(sessionID:)` route through `BackendDescriptor.descriptor(for: kind).makeConfig`

- [ ] **Step 1: Write the failing tests**

`Tests/macSCPCoreTests/ConnectionViewModelSchemaTests.swift`:

```swift
import Foundation
import Testing
@testable import macSCPCore

@Suite("ConnectionViewModel schema")
@MainActor
struct ConnectionViewModelSchemaTests {
    @Test func buildsAnSSHConfigFromValues() throws {
        let model = ConnectionViewModel()
        model.kind = .ssh
        model.values[SSHField.host] = "server.example.com"
        model.values[SSHField.port] = "22"
        model.values[SSHField.username] = "tim"
        model.values[SSHField.authKind] = "password"

        let config = try model.makeConfig(secret: "hunter2")
        guard case .ssh(let ssh) = config else {
            Issue.record("expected .ssh")
            return
        }
        #expect(ssh.host == "server.example.com")
    }

    @Test func buildsAWebDAVConfigFromValues() throws {
        let model = ConnectionViewModel()
        model.kind = .webdav
        model.values[WebDAVField.baseURL] = "https://cloud.example.com"
        model.values[WebDAVField.username] = "tim"

        let config = try model.makeConfig(secret: "app-password")
        guard case .webdav(let dav) = config else {
            Issue.record("expected .webdav")
            return
        }
        #expect(dav.baseURL == "https://cloud.example.com")
    }

    /// Switching protocol must not carry the previous one's values across —
    /// they are namespaced, so an S3 endpoint cannot leak into a WebDAV form,
    /// but the user should also not see a stale form.
    @Test func switchingKindClearsTheForm() {
        let model = ConnectionViewModel()
        model.kind = .s3
        model.values[S3Field.bucket] = "backups"
        model.kind = .webdav
        #expect(model.values[S3Field.bucket] == "")
    }

    @Test func missingRequiredFieldSurfacesAsAFailure() {
        let model = ConnectionViewModel()
        model.kind = .webdav
        #expect(throws: (any Error).self) { _ = try model.makeConfig(secret: "p") }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter "ConnectionViewModel schema"`
Expected: FAIL — `value of type 'ConnectionViewModel' has no member 'values'`

- [ ] **Step 3: Rework the view model**

Remove `s3Endpoint`, `s3Region`, `s3Bucket`, `s3AccessKeyID`, `s3SecretAccessKey`, `s3UsePathStyle`, `webdavBaseURL`, `webdavUseNextcloudPath`, `makeS3Config()`, `makeWebDAVConfig()`. Add:

```swift
    /// Everything the form collected, keyed by the active backend's fields.
    public var values = FieldValues()

    /// Builds the runtime config for the selected backend. The `switch` that
    /// used to live here is now the descriptor's own factory.
    public func makeConfig(secret: String) throws -> ConnectionConfig {
        try BackendDescriptor.descriptor(for: kind).makeConfig(values, secret)
    }
```

Give `kind` a `didSet` that resets `values` to a fresh `FieldValues()`. Route `connect()` and `validateForEditSave(sessionID:)` through `makeConfig(secret:)` and the per-backend adapters, deleting their `switch` over `kind`.

- [ ] **Step 4: Move the SSH section onto `SchemaFormView`**

In `ConnectionFormView.swift`, delete the bespoke SSH sections and render the same `SchemaFormView` for every kind. The jump block becomes the `.group` the schema declares.

- [ ] **Step 5: Run the full suite**

Run: `swift test` → PASS. The existing `ConnectionViewModelTests` SSH and S3 cases must be green **unchanged** — if one needs editing, stop and report it.

- [ ] **Step 6: Commit**

```bash
git add Sources/macSCPCore/Presentation/ConnectionViewModel.swift Sources/MacSCPApp/ConnectionFormView.swift Tests/macSCPCoreTests/ConnectionViewModelSchemaTests.swift
git commit -m "refactor: drive the connection form and view model from the schema

ConnectionViewModel loses its typed per-protocol properties and keeps one
FieldValues; connect() and validateForEditSave() call the descriptor's
factory instead of switching over the kind.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 9: Login sets, the resolver, and WebDAV falling out

**Files:**
- Modify: `Sources/macSCPCore/Sessions/LoginSetStore.swift` (both `LoginSet` **and** its private `Record` persistence shape)
- Modify: `Sources/macSCPCore/Sessions/LoginSetExportCodec.swift` (`ExportedLoginSet`)
- Modify: `Sources/macSCPCore/Sessions/LoginResolver.swift`
- Modify: `Sources/MacSCPApp/LoginSetsSheet.swift`
- Test: `Tests/macSCPCoreTests/LoginResolverSchemaTests.swift`

**Interfaces:**
- Consumes: Tasks 1–8
- Produces: `LoginSet` gains optional `baseURL: String?` and `useNextcloudPath: Bool?`; `LoginResolver.resolve(session:sets:secrets:) throws -> FieldValues?` replaces `resolve` and `resolveS3`

**Three seams the file list above exists to name, because each is easy to miss:**

1. `LoginSet` is persisted through a **private `Record` struct** inside `LoginSetStore`, not directly. A new property on `LoginSet` that is not also on `Record` compiles fine and silently fails to save. `Record` already documents the pattern: `var kind: ConnectionKind?` is optional precisely so legacy records decode.
2. `ExportedLoginSet` in `LoginSetExportCodec.swift` is a **third** shape carrying the same data, for `.macscplogins` files. The two new properties belong there too, also optional, and its `public init` is exhaustive — adding a property is a compile error at every call site, which is the good kind.
3. `LoginResolver` has **five** functions, not two. Only `resolve` and `resolveS3` collapse. `resolveJump(spec:sets:secrets:)` and its overload stay exactly as they are — a jump host is an SSH concept and has no meaning for S3 or WebDAV, so making it generic would be inventing a requirement. `ResolvedLogin` and `ResolvedJump` stay for the jump path; only `ResolvedS3Login` disappears.

**Preserve the `kindMismatch` invariant.** `resolve` and `resolveS3` both hard-stop when `set.kind != session.kind`, with the comment "fail honestly rather than resolve credentials shaped for the wrong protocol". The collapsed function must keep that guard — it is the one thing standing between a user and an S3 session silently connecting with SSH credentials.

- [ ] **Step 1: Write the failing tests**

`Tests/macSCPCoreTests/LoginResolverSchemaTests.swift`:

```swift
import Foundation
import Testing
@testable import macSCPCore

@Suite("LoginResolver schema")
struct LoginResolverSchemaTests {
    /// A WebDAV login set resolves into the same FieldValues shape the form
    /// produces — that is what makes WebDAV login sets work with no
    /// WebDAV-specific code anywhere.
    @Test func resolvesAWebDAVSetIntoFieldValues() throws {
        let secrets = InMemorySecretStore()
        var set = LoginSet(name: "cloud", username: "tim")
        set.kind = .webdav
        try secrets.savePassword("app-password", for: set.id)

        var session = StoredSession(name: "s", host: "", port: 443, username: "")
        session.kind = .webdav
        session.loginSetID = set.id

        let values = try #require(
            LoginResolver.resolve(session: session, sets: [set], secrets: secrets))
        #expect(values[WebDAVField.username] == "tim")
        #expect(values[WebDAVField.password] == "app-password")
    }

    @Test func resolvesAnS3SetIntoFieldValues() throws {
        let secrets = InMemorySecretStore()
        var set = LoginSet(name: "minio", username: "")
        set.kind = .s3
        set.accessKeyID = "AKIA"
        try secrets.savePassword("topsecret", for: set.id)

        var session = StoredSession(name: "s", host: "", port: 443, username: "")
        session.kind = .s3
        session.loginSetID = set.id

        let values = try #require(
            LoginResolver.resolve(session: session, sets: [set], secrets: secrets))
        #expect(values[S3Field.accessKeyID] == "AKIA")
        #expect(values[S3Field.secretAccessKey] == "topsecret")
    }

    @Test func aSessionWithoutASetResolvesToNil() throws {
        let session = StoredSession(name: "s", host: "h", port: 22, username: "u")
        #expect(try LoginResolver.resolve(
            session: session, sets: [], secrets: InMemorySecretStore()) == nil)
    }

    @Test func aMissingSetIsAnError() {
        var session = StoredSession(name: "s", host: "h", port: 22, username: "u")
        session.loginSetID = UUID()
        #expect(throws: LoginResolveError.missingSet) {
            _ = try LoginResolver.resolve(
                session: session, sets: [], secrets: InMemorySecretStore())
        }
    }

    /// The invariant that survives the collapse: binding a session to a set of
    /// a different protocol is a hard stop, never a fallback to credentials
    /// shaped for the wrong backend.
    @Test func aSetOfTheWrongKindIsAHardStop() {
        var set = LoginSet(name: "ssh", username: "tim")
        set.kind = .ssh
        var session = StoredSession(name: "s", host: "", port: 443, username: "")
        session.kind = .webdav
        session.loginSetID = set.id
        #expect(throws: LoginResolveError.kindMismatch) {
            _ = try LoginResolver.resolve(
                session: session, sets: [set], secrets: InMemorySecretStore())
        }
    }

    /// The jump path is untouched: a jump host is an SSH concept, so
    /// `resolveJump` keeps returning `ResolvedLogin` and is not made generic.
    @Test func theJumpResolverStillReturnsAnSSHLogin() throws {
        let spec = StoredSession.JumpSpec(host: "bastion", username: "tim")
        let resolved = try LoginResolver.resolveJump(
            spec: spec, sets: [], secrets: InMemorySecretStore())
        #expect(resolved.username == "tim")
    }
}
```

Adjust the `LoginSet(...)` and `StoredSession(...)` calls to the real initialisers.

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter "LoginResolver schema"`
Expected: FAIL — the resolver returns `ResolvedLogin?`, not `FieldValues?`

- [ ] **Step 3: Implement**

Add `baseURL: String?` and `useNextcloudPath: Bool?` to `LoginSet`, to `LoginSetStore.Record`, and to `ExportedLoginSet` — all three, all optional, so files written before M22 decode with `nil`. Then collapse `resolve` and `resolveS3` into one that finds the set, keeps the `.missingSet` and `.kindMismatch` guards unchanged, asks the backend's adapter to translate the set's typed fields into `FieldValues`, reads the secret from the Keychain under the set's id, and returns the values. `resolveJump` and both `ResolvedLogin`/`ResolvedJump` stay; delete `ResolvedS3Login` and update its callers.

Note that `resolve` short-circuits for `authKind == .agent` — "Agent sets carry no secret and no key path (M10d), the keychain is never read for them". That short-circuit stays, and applies only when the set's kind is `.ssh`.

- [ ] **Step 4: Make the login-set editor generic**

In `LoginSetsSheet.swift`, replace the hand-enumerated type picker with `ForEach(ConnectionKind.allCases)` and render `BackendDescriptor.descriptor(for: kind).credentialSchema` through `SchemaFormView`. Delete `isSaveDisabled`'s `switch` in favour of a required-field check over the schema, and delete the `preconditionFailure`.

- [ ] **Step 5: Run the full suite**

Run: `swift test` → PASS, existing login-set tests unchanged

- [ ] **Step 6: Commit**

```bash
git add Sources/macSCPCore/Sessions Sources/MacSCPApp/LoginSetsSheet.swift Tests/macSCPCoreTests/LoginResolverSchemaTests.swift
git commit -m "feat: resolve every login set through one code path

LoginResolver.resolve and resolveS3 collapse into one returning
FieldValues, and the editor renders the credential schema -- so a WebDAV
login set exists without a line of WebDAV-specific UI.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 10: The CLI seams and the connector's dissolution

**Files:**
- Modify: `Sources/macSCPCore/Sessions/CLISecretSources.swift`, `Sources/macSCPCore/CLI/CLIErrorMapping.swift`, `Sources/macSCPCore/Connection/StoredSessionConnectionConfig.swift`
- Delete: `Sources/macSCPCore/Connection/BackendConnector.swift`
- Modify: call sites in `Sources/MacSCPApp/ContentView.swift` and `Sources/MacSCPCLI/SessionConnecting.swift`
- Test: `Tests/macSCPCoreTests/CLISecretSourcesSchemaTests.swift`

**Interfaces:**
- Consumes: Tasks 1–9
- Produces: `StoredSessionConnectionError.missingBackendConfiguration(kind: ConnectionKind)` replaces `.missingS3Configuration` and `.missingWebDAVConfiguration`

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import macSCPCore

@Suite("CLISecretSources schema")
struct CLISecretSourcesSchemaTests {
    /// The environment-variable name is a property of the backend, not a
    /// branch in the CLI. S3 keeps the AWS-conventional name so existing
    /// pipelines need not relearn one.
    @Test func eachBackendNamesItsOwnEnvironmentVariable() {
        #expect(BackendDescriptor.descriptor(for: .s3).secretEnvironmentVariable
            == "AWS_SECRET_ACCESS_KEY")
        #expect(BackendDescriptor.descriptor(for: .webdav).secretEnvironmentVariable
            == "MACSCP_PASSWORD")
        #expect(BackendDescriptor.descriptor(for: .ssh).secretEnvironmentVariable
            == "MACSCP_PASSWORD")
    }

    @Test func everyBackendDeclaresWhetherItNeedsASecret() {
        for kind in ConnectionKind.allCases {
            #expect(BackendDescriptor.descriptor(for: kind).requiresSecret == true)
        }
    }

    /// One error case for every backend, so a fourth protocol adds no case.
    @Test func theMissingConfigurationErrorNamesItsKind() {
        let error = StoredSessionConnectionError.missingBackendConfiguration(kind: .webdav)
        #expect(error == .missingBackendConfiguration(kind: .webdav))
        #expect(error != .missingBackendConfiguration(kind: .s3))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter "CLISecretSources schema"`
Expected: FAIL — `type 'BackendDescriptor' has no member 'secretEnvironmentVariable'` is already satisfied by Task 3, so the failure will be on `missingBackendConfiguration`

- [ ] **Step 3: Implement**

Replace `CLISecretSources`'s `switch` with `descriptor.secretEnvironmentVariable` and its `needsSecret` chain with `descriptor.requiresSecret`. Replace the two per-protocol error cases with `.missingBackendConfiguration(kind:)` and update `CLIErrorMapping` to one message that names the protocol. Delete `BackendConnector.swift` and route its call sites through `BackendDescriptor.descriptor(for: config.kind).connect(...)`.

- [ ] **Step 4: Run the full suite and the gated CLI suite**

```bash
swift test
docker compose -f docker/test-server/compose.yml up -d
MACSCP_ITEST=1 swift test --filter "CLIRoundtrip"
```

- [ ] **Step 5: Commit**

```bash
git add Sources/macSCPCore Sources/MacSCPApp Sources/MacSCPCLI Tests/macSCPCoreTests/CLISecretSourcesSchemaTests.swift
git commit -m "refactor: read the CLI seams from the descriptor

The environment-variable name and 'needs a secret' become descriptor
properties, the two per-protocol configuration errors become one that
names its kind, and BackendConnector dissolves into the descriptor's own
connect closure.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 11: `displaySummary` replaces the placeholder labels

**Files:**
- Modify: `Sources/MacSCPApp/ContentView.swift`, `Sources/macSCPCore/Presentation/TabsViewModel.swift`, the audit recorder wiring
- Test: `Tests/macSCPCoreTests/DisplaySummaryTests.swift`

**Interfaces:**
- Consumes: Tasks 1–10
- Produces: no new API — the sidebar, tab title and audit trail read `descriptor.displaySummary(values)`

**This task has no red phase, and the report must say so plainly.** `displaySummary` was built and tested in Tasks 4–6; the work here is replacing three call sites that build `user@host` by hand. The test below is a characterization test that pins the property those call sites must preserve — it is expected to pass the moment it is written. Do not manufacture a failure to satisfy the red→green habit; state in the report that this task's verification is the call-site diff plus the suite.

- [ ] **Step 1: Write the characterization test**

```swift
import Foundation
import Testing
@testable import macSCPCore

@Suite("displaySummary")
struct DisplaySummaryTests {
    /// Before M22 the audit trail recorded `host: "unused"` and a WebDAV tab
    /// was titled `tim@`, because both were built from SSH-shaped fields the
    /// other backends never fill.
    @Test func eachBackendSummarisesItselfWithoutEmptyParts() {
        var s3 = FieldValues()
        s3[S3Field.bucket] = "backups"
        s3[S3Field.endpoint] = "https://minio.local:9000"
        let s3Summary = BackendDescriptor.descriptor(for: .s3).displaySummary(s3)
        #expect(!s3Summary.hasSuffix("@"))
        #expect(s3Summary.contains("backups"))

        var dav = FieldValues()
        dav[WebDAVField.username] = "tim"
        dav[WebDAVField.baseURL] = "https://cloud.example.com"
        let davSummary = BackendDescriptor.descriptor(for: .webdav).displaySummary(dav)
        #expect(davSummary.contains("cloud.example.com"))
        #expect(!davSummary.hasSuffix("@"))
    }
}
```

- [ ] **Step 2: Run it, then wire the call sites**

Run: `swift test --filter "displaySummary"` → PASS immediately, as stated above. Then replace the three call sites that build `user@host` by hand, and remove the `"unused"` placeholders from the audit recorder. Re-run afterwards to confirm the rewiring did not break the property.

- [ ] **Step 3: Run the full suite and commit**

```bash
swift test
git add Sources/MacSCPApp Sources/macSCPCore Tests/macSCPCoreTests/DisplaySummaryTests.swift
git commit -m "fix: label every backend with its own summary

The sidebar, tab title and audit trail stop building user@host from
SSH-shaped fields the other backends never fill -- which is why the audit
log carried host: \"unused\" and a WebDAV tab was titled tim@.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 12: Legacy fixtures, the grep proof, and the milestone close

The task that proves users' saved connections survive.

**Files:**
- Create: `Tests/macSCPCoreTests/Fixtures/legacy-session-pre-m22.json`, `Tests/macSCPCoreTests/Fixtures/legacy-loginset-pre-m22.json`
- Create: `Tests/macSCPCoreTests/LegacyStoreCompatibilityTests.swift`
- Modify: `README.md`

- [ ] **Step 1: Capture the fixtures from the pre-M22 format**

Take the JSON shape `StoredSession` and `LoginSet` write **today** — one SSH session with a key path, one S3 session with its `s3` block, one WebDAV session with its `webdav` block, and one login set of each kind. Write them out by hand from the current `Codable` shape (`git show 92571cc:Sources/macSCPCore/Sessions/StoredSession.swift` if the type has since changed) and check them in as fixtures. **These files contain no secrets** — secrets live in the Keychain, and the fixtures must be inspected to confirm that before committing.

- [ ] **Step 2: Write the compatibility test**

```swift
import Foundation
import Testing
@testable import macSCPCore

@Suite("Legacy store compatibility")
struct LegacyStoreCompatibilityTests {
    private func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name)")
        return try Data(contentsOf: url)
    }

    /// The one test that cannot be replaced by reasoning: a session written
    /// before M22 must still load and still produce the same config.
    @Test func aPreM22SessionStillLoads() throws {
        let sessions = try JSONDecoder().decode(
            [StoredSession].self, from: fixture("legacy-session-pre-m22.json"))
        #expect(sessions.count == 3)

        let ssh = try #require(sessions.first { $0.kind == .ssh })
        #expect(SSHFieldSchema.values(from: ssh)[SSHField.host] == "server.example.com")

        let s3 = try #require(sessions.first { $0.kind == .s3 })
        let s3Config = try #require(s3.s3)
        #expect(S3FieldSchema.values(from: s3Config)[S3Field.bucket] == "backups")

        let dav = try #require(sessions.first { $0.kind == .webdav })
        let davConfig = try #require(dav.webdav)
        #expect(WebDAVFieldSchema.values(from: davConfig)[WebDAVField.username] == "tim")
    }

    @Test func aPreM22LoginSetStillLoads() throws {
        let sets = try JSONDecoder().decode(
            [LoginSet].self, from: fixture("legacy-loginset-pre-m22.json"))
        #expect(sets.count == 2)
        #expect(sets.contains { $0.kind == .ssh })
        #expect(sets.contains { $0.kind == .s3 && $0.accessKeyID == "AKIA" })
    }

    /// The fixtures are checked into git, so they must carry no secret
    /// material. Note this cannot scan for the word "password": `AuthKind`'s
    /// raw value IS "password", so a legitimate `"authKind": "password"`
    /// would trip a naive scan. Scan for the field names that would hold a
    /// value instead.
    @Test func fixturesCarryNoSecrets() throws {
        let secretFieldNames = ["secretAccessKey", "\"secret\"", "\"password\"",
                                "passphrase", "embeddedKey", "privateKey\":"]
        for name in ["legacy-session-pre-m22.json", "legacy-loginset-pre-m22.json"] {
            let text = try #require(String(data: try fixture(name), encoding: .utf8))
            for needle in secretFieldNames {
                #expect(!text.contains(needle), "fixture \(name) contains \(needle)")
            }
        }
    }
}
```

- [ ] **Step 3: Prove the branches are gone**

```bash
grep -rn "kind == \.\|case .ssh:\|case .s3:\|case .webdav:" Sources/ \
  | grep -v "Sources/macSCPCore/Capabilities/BackendDescriptor.swift" \
  | grep -v "FieldSchema.swift"
```

Every remaining hit must be justified in the report — a `ConnectionConfig` unwrap inside a backend's own `connect` closure is fine; anything in a generic layer is not.

- [ ] **Step 4: Full verification**

```bash
swift test
docker compose -f docker/test-server/compose.yml up -d
MACSCP_ITEST=1 swift test
scripts/package-app
```

- [ ] **Step 5: README**

Nothing user-visible changed, so the README needs no feature edit. Check that its "Building from source" section still describes the rig accurately.

- [ ] **Step 6: Commit**

```bash
git add Tests/macSCPCoreTests/Fixtures Tests/macSCPCoreTests/LegacyStoreCompatibilityTests.swift
git commit -m "test: pin that pre-M22 stores still load

Frozen fixtures in the format sessions and login sets are written in
today. This is the only test proving the milestone does not cost users
their saved connections, and the only one reasoning cannot replace.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Milestone Close

- [ ] Whole-milestone review over `5a17d40..HEAD`
- [ ] Confirm the five success criteria from the spec, each with the command that shows it
- [ ] Report which parts of the vocabulary went unused — an unused case is a design mistake worth removing before it ossifies
- [ ] Ledger entry in `.superpowers/sdd/progress.md`
- [ ] Push only on the maintainer's explicit instruction
