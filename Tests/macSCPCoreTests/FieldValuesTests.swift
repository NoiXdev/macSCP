import Foundation
import Testing
@testable import macSCPCore

private enum TestField: String, CaseIterable, BackendFieldID {
    case alpha, beta, flag
}

private enum OtherField: String, CaseIterable, BackendFieldID {
    case alpha
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

    @Test func rawStorageIsInspectableForPersistence() {
        var values = FieldValues()
        values[TestField.alpha] = "one"
        #expect(values.raw.values.contains("one"))
    }
}
