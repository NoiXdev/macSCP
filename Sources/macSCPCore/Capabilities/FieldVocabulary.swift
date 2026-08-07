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
/// A closed set on purpose. `managedKeys` cannot be resolved in Core — that
/// store lives in the App — so the form is handed a resolver that turns a
/// source into options. Two cases means one `switch`, in one place; an
/// open-ended "options provider" would be the dispatcher we are removing,
/// wearing a different hat.
///
/// There is deliberately no `loginSets` case. Picking a login SET is not a
/// field: it substitutes the whole credential schema, which is what
/// `FormBlock.loginSetPicker` expresses. A case for it shipped unused through
/// M22 and was removed in the milestone's final review — two mechanisms for
/// one job, one of them dead.
public enum OptionSource: Sendable, Equatable {
    case managedKeys
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
    /// Shown only when this holds; nil means always.
    ///
    /// DELIBERATELY untested-but-kept. No leaf carries a condition today —
    /// M22's final review kept this while deleting the milestone's other
    /// unused vocabulary, because it is load-bearing for a rule that has no
    /// other home: `ConnectionFieldSchema.visibleLeaves` qualifies the
    /// namespace with the GROUP's id precisely so a leaf's condition resolves
    /// against its SIBLING leaf and not against the top-level field of the
    /// same name. Without this property that rule has nothing to attach to,
    /// and the first leaf condition somebody adds would key an SSH jump's key
    /// path off the TARGET's auth kind — a mistake nothing in the suite could
    /// catch, since there is no leaf condition for a test to get wrong.
    public let visibleWhen: FieldCondition?

    public init(id: String, labelKey: String, labelDefault: String,
                kind: Kind, visibleWhen: FieldCondition? = nil) {
        self.id = id; self.labelKey = labelKey; self.labelDefault = labelDefault
        self.kind = kind; self.visibleWhen = visibleWhen
    }
}

/// Evaluates a field's visibility condition. Pure, so the rule is provable
/// without a view.
///
/// `namespace` is the owning backend's enum type name — the same qualifier
/// `FieldValues` stores keys under. Both production call sites
/// (`ConnectionFieldSchema.visibleFields` and `.visibleLeaves`) always pass
/// one; the default exists for a schema evaluated standalone, and only
/// `FieldVisibilityTests` takes it today.
///
/// PRECONDITION on the nil case: at most ONE key in `values` may end in the
/// condition's field name. Two backends' same-named fields sharing one
/// `FieldValues` make the suffix match pick whichever the dictionary yields
/// first, and `Dictionary` iteration order is unspecified — the answer is
/// then arbitrary, not merely surprising. The default is kept rather than
/// deleted because the standalone case is real and the constraint holds
/// wherever it is used; no type can express it, so it is stated here instead.
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
            // name, which is only well defined while the type-level
            // precondition holds (see `FieldVisibility`'s own doc comment):
            // with two matches this picks an arbitrary one.
            actual = values.raw.first { $0.key.hasSuffix(".\(condition.field)") }?.value
        }
        return actual == condition.equals
    }
}
