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
