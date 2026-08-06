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
        // A leaf's condition names a SIBLING leaf, so the controlling value is
        // stored under `owner.group.leaf` -- written by hand here because "grp"
        // is not a `BackendFieldID` case.
        var values = FieldValues()
        values.setRaw("VField.grp.\(VField.authKind.rawValue)", to: "password")
        #expect(ConnectionFieldSchema.visibleLeaves(of: group, in: values,
                                                    owner: "VField").map(\.id)
            == ["always"])

        values.setRaw("VField.grp.\(VField.authKind.rawValue)", to: "privateKey")
        #expect(ConnectionFieldSchema.visibleLeaves(of: group, in: values,
                                                    owner: "VField").map(\.id)
            == ["always", "conditional"])
    }

    /// A group's leaves resolve against the GROUP-QUALIFIED namespace
    /// (`SSHField.jump`), never the owner's (`SSHField`) — a leaf's condition
    /// names a sibling leaf, and `FieldValues` stores those under
    /// `owner.group.leaf`.
    ///
    /// `visibleLeaves` builds that qualification itself, so a caller can no
    /// longer get it wrong. This pins the behaviour from both sides: the
    /// qualified lookup hides the jump's key path, and the plain owner
    /// namespace — the mistake, now unexpressible through `visibleLeaves` —
    /// would have shown it by reading the TARGET's auth kind. Every jump leaf
    /// is unconditional today, so nothing else in the suite exercises this.
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

        #expect(
            ConnectionFieldSchema.visibleLeaves(of: jump, in: values,
                                                owner: SSHField.namespace)
                .map(\.id) == [SSHJumpField.host.rawValue])

        // The other direction: evaluating the SAME leaf against the plain owner
        // namespace reads the TARGET's auth kind and wrongly shows the row.
        // That is what `visibleLeaves` now makes impossible to ask for; kept
        // here so the difference stays visible rather than merely asserted.
        #expect(FieldVisibility.isVisible(
            leaves[1], in: values, namespace: SSHField.namespace))
    }
}
