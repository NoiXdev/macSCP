import Foundation
import Testing
@testable import macSCPCore

private enum VField: String, CaseIterable, BackendFieldID {
    case authKind, keyPath
    static let namespace = "VField"
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
