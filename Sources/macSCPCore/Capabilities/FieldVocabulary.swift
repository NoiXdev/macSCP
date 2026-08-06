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
