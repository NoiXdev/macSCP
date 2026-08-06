import Foundation

/// A backend's field identifiers (M22). Each backend declares one of these,
/// and it is the SINGLE source for its connection schema, its credential
/// schema, its config factory and its persistence adapter.
///
/// The point is that there are no loose strings anywhere: a field that does
/// not exist cannot be written into a schema, read from `FieldValues`, or
/// forgotten by the factory — the last one because the factory switches over
/// this enum and the compiler checks exhaustiveness.
public protocol BackendFieldID: RawRepresentable, CaseIterable, Hashable, Sendable
where RawValue == String {
    /// The stable prefix this backend's stored keys carry.
    ///
    /// Declared explicitly rather than derived from the type name, for two
    /// reasons. Swift's `"\(F.self)"` yields the UNQUALIFIED name, so two
    /// backends that each nest their enum as `Backend.Field` would both
    /// produce `"Field"` and silently share storage — verified, not assumed.
    /// And a derived name would make renaming the enum a silent format
    /// change, breaking every session already on disk.
    static var namespace: String { get }
}

/// The values a form collected, keyed by field.
///
/// Storage is flat and prefixed with the field enum's declared `namespace`,
/// so two backends may both call a field `username` without colliding. Group
/// members live in the same flat map under `namespace.group.leaf`, which
/// keeps persistence a plain string map rather than a tree.
///
/// Keys are joined with `.`, so a field's raw value must not contain one.
/// Swift derives raw values from the case names, which cannot — only an
/// explicit `case foo = "a.b"` could, and no backend writes one.
public struct FieldValues: Equatable, Sendable {
    private var storage: [String: String]

    public init() { storage = [:] }

    public init(raw: [String: String]) { storage = raw }

    /// The flat map, for the per-backend persistence adapters.
    public var raw: [String: String] { storage }

    private static func key<F: BackendFieldID>(_ field: F) -> String {
        "\(F.namespace).\(field.rawValue)"
    }

    private static func key<G: BackendFieldID, L: BackendFieldID>(
        _ group: G, _ leaf: L
    ) -> String {
        "\(G.namespace).\(group.rawValue).\(leaf.rawValue)"
    }

    /// An unset field reads as the empty string — absence and "cleared by the
    /// user" are the same thing for a form field, and making every call site
    /// unwrap an optional would buy nothing.
    public subscript<F: BackendFieldID>(field: F) -> String {
        get { storage[Self.key(field)] ?? "" }
        set { storage[Self.key(field)] = newValue }
    }

    public subscript<G: BackendFieldID, L: BackendFieldID>(
        group: G, leaf: L
    ) -> String {
        get { storage[Self.key(group, leaf)] ?? "" }
        set { storage[Self.key(group, leaf)] = newValue }
    }

    /// Toggles. Only the exact string "true" is true: a half-written or
    /// hand-edited file must not be able to flip a toggle on by accident.
    public subscript<F: BackendFieldID>(bool field: F) -> Bool {
        get { storage[Self.key(field)] == "true" }
        set { storage[Self.key(field)] = newValue ? "true" : "false" }
    }
}
