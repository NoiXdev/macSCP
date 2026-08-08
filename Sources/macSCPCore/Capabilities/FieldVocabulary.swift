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

/// A parse rule a field's raw string must satisfy (M23).
///
/// Exactly one case, and deliberately so: the port is the only format rule in
/// the entire pre-M23 validation code. A second case should arrive with a
/// second real need, not in anticipation of one — the same discipline that
/// keeps `FieldCondition` from growing into an expression language.
public enum FieldFormat: Sendable, Equatable {
    case numeric
}

/// How a field takes part in a connection's IDENTITY (M23/P3) — the answer to
/// "are these two sessions the same connection?", which `SessionImportPlanner`
/// asks of every entry in an import file.
///
/// Two cases, because there are two real behaviours and no third. A host name
/// is case-insensitive (DNS says so, and SSH import has folded it since M9a);
/// a bucket name, a URL path and an access key ID are not, and folding them
/// would merge connections that are genuinely different. Which of the two a
/// field wants is a property of the FIELD, not of the backend, which is why it
/// is declared here rather than decided by whoever builds the key.
///
/// Trimming is deliberately NOT among the cases: an identity key is derived
/// from raw stored/file values, and a value that needs trimming is trimmed by
/// the backend's own `apply` long before it is ever stored.
public enum FieldIdentity: Sendable, Equatable {
    /// Byte for byte, exactly as the file or the store spells it.
    case verbatim
    /// Case-folded — the DNS rule, and only for what DNS actually governs.
    case caseInsensitive

    /// This field's raw value as it enters an identity key.
    public func normalized(_ raw: String) -> String {
        switch self {
        case .verbatim: return raw
        case .caseInsensitive: return raw.lowercased()
        }
    }
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

/// What a secret field's value MEANS for the identity of a login (M24) — the
/// answer to "do these two sessions log in as the same principal?", which
/// `LoginMergePlanner` asks before offering to fold them into one login set.
///
/// Two cases, because there are two real behaviours. A password and an S3
/// secret access key ARE the credential: two logins with different ones are
/// different logins, and merging them would bind both to a set that can only
/// carry one — destroying the other's Keychain entry. An SSH passphrase is
/// not: it unlocks a key file that another field (`keyPath`) already names, so
/// two sessions on the same key file are the same login whether or not either
/// happens to have the passphrase stored.
///
/// NOT derivable from `isRequired`, which was the first thing tried. That
/// gives the right answer for SSH and S3 and the WRONG one for WebDAV, whose
/// password is optional since M23 so that anonymous shares work — a WebDAV
/// password would then leave the identity key, and two sessions with the same
/// user name and DIFFERENT passwords would collide.
public enum SecretRole: Sendable, Equatable {
    /// The secret is the credential itself.
    case credential
    /// The secret unlocks a credential named by another field.
    case passphrase
}
