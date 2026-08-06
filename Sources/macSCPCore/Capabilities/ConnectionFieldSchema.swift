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

/// A provider preset that pre-fills fields (M12), e.g. AWS or Hetzner.
public struct ConnectionPreset: Sendable, Equatable, Identifiable {
    public let id: String
    public let nameKey: String
    public let nameDefault: String
    /// Field id -> pre-filled value (e.g. "endpoint" -> a template).
    public let values: [String: String]
    public init(id: String, nameKey: String, nameDefault: String, values: [String: String]) {
        self.id = id; self.nameKey = nameKey; self.nameDefault = nameDefault; self.values = values
    }
}

/// The form schema a protocol contributes (M12): its fields + provider presets.
public struct ConnectionFieldSchema: Sendable, Equatable {
    public let fields: [ConnectionField]
    public let presets: [ConnectionPreset]
    public init(fields: [ConnectionField], presets: [ConnectionPreset]) {
        self.fields = fields; self.presets = presets
    }
}

extension ConnectionFieldSchema {
    /// The fields a form should render for these values. Pure, so the rule is
    /// provable without a view — the renderer walks this and nothing else.
    public func visibleFields(in values: FieldValues, namespace: String) -> [ConnectionField] {
        fields.filter { FieldVisibility.isVisible($0, in: values, namespace: namespace) }
    }

    /// A group's visible leaves. A leaf's condition is evaluated the same way
    /// as a top-level field's, so a group can show and hide its own members.
    ///
    /// Takes the OWNER's namespace and qualifies it with the group's own id
    /// here, rather than asking the caller for the qualified string. A leaf's
    /// condition names a SIBLING leaf, and `FieldValues` stores those under
    /// `owner.group.leaf` — so a caller that built the namespace itself could
    /// pass the plain owner one and silently key the group's rows off the
    /// TOP-LEVEL field of the same name (the SSH jump's key path following the
    /// TARGET's auth kind). Nothing would fail: no leaf carries a condition
    /// today, so the mistake would pass the whole suite. Doing it in here makes
    /// it unexpressible instead of merely tested.
    public static func visibleLeaves(
        of field: ConnectionField, in values: FieldValues, owner: String
    ) -> [LeafField] {
        guard case .group(let leaves) = field.kind else { return [] }
        let namespace = "\(owner).\(field.id)"
        return leaves.filter { FieldVisibility.isVisible($0, in: values, namespace: namespace) }
    }
}

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
