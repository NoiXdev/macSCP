/// One field the connection form should render for a protocol (M12). `labelKey`
/// is resolved to a localized string in the App layer (Core stays bundle-free).
public struct ConnectionField: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable { case text, number, secret, toggle }
    public let id: String            // stable key, e.g. "endpoint"
    public let labelKey: String      // L10n key
    public let labelDefault: String  // English fallback
    public let kind: Kind
    public var isSecret: Bool { kind == .secret }
    public init(id: String, labelKey: String, labelDefault: String, kind: Kind) {
        self.id = id; self.labelKey = labelKey; self.labelDefault = labelDefault; self.kind = kind
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
