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

    /// A group's leaves must be resolved against the GROUP-QUALIFIED namespace
    /// (`SSHField.jump`), never the owner's (`SSHField`) — a leaf's condition
    /// names a sibling leaf, and `FieldValues` stores those under
    /// `owner.group.leaf`.
    ///
    /// This is the contract the generic renderer has to honour, and the one
    /// mistake nothing else can catch: every jump leaf is unconditional today,
    /// so a renderer passing the plain owner namespace would pass the entire
    /// suite while silently keying the jump's rows off the TARGET's fields.
    /// Both directions are asserted, so the test fails if the wrong namespace
    /// ever starts producing the right answer by accident.
    @Test func aLeafConditionFollowsTheJumpNotTheTarget() {
        let leaves = [
            LeafField(id: SSHJumpField.host.rawValue, labelKey: "h",
                      labelDefault: "Host", kind: .text),
            LeafField(id: SSHJumpField.keyPath.rawValue, labelKey: "k",
                      labelDefault: "Key path", kind: .text,
                      visibleWhen: FieldCondition(
                        field: SSHJumpField.authKind.rawValue,
                        equals: StoredSession.AuthKind.privateKey.rawValue)),
        ]
        let jump = ConnectionField(id: SSHField.jump.rawValue, labelKey: "j",
                                   labelDefault: "Jump host", kind: .group(leaves))

        // The target authenticates with a key, the jump with a password — so
        // the jump's key-path row must stay hidden.
        var values = FieldValues()
        values[SSHField.authKind] = StoredSession.AuthKind.privateKey.rawValue
        values[SSHField.jump, SSHJumpField.authKind] = StoredSession.AuthKind.password.rawValue

        let qualified = "\(SSHField.namespace).\(SSHField.jump.rawValue)"
        #expect(
            ConnectionFieldSchema.visibleLeaves(of: jump, in: values, namespace: qualified)
                .map(\.id) == [SSHJumpField.host.rawValue])

        // The owner's plain namespace reads the TARGET's auth kind instead and
        // wrongly shows the row — pinned here so the difference is visible.
        #expect(
            ConnectionFieldSchema.visibleLeaves(of: jump, in: values,
                                                namespace: SSHField.namespace)
                .map(\.id) == [SSHJumpField.host.rawValue, SSHJumpField.keyPath.rawValue])
    }
}
