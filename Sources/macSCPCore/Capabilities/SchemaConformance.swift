import Foundation

/// Checks that a backend's field enum and its two schemas agree (M22).
///
/// This catches the one gap an exhaustive `switch` in the factory cannot: a
/// field the enum declares and the factory handles, but that appears in
/// NEITHER schema — so no form renders an input for it and the user can
/// never set it. Nothing about that is a compile error.
public enum SchemaConformance {
    /// Returns one complaint per problem; empty means conformant.
    public static func check<F: BackendFieldID>(
        _ descriptor: BackendDescriptor, fields: F.Type
    ) -> [String] {
        let declared = Set(F.allCases.map(\.rawValue))
        let inSchemas = Set(
            ids(in: descriptor.connectionSchema) + ids(in: descriptor.credentialSchema))

        var complaints: [String] = []
        for missing in declared.subtracting(inSchemas).sorted() {
            complaints.append(
                "\(F.self).\(missing) is declared but appears in neither schema, "
                + "so no form can render it")
        }
        for unknown in inSchemas.subtracting(declared).sorted() {
            complaints.append("schema field \"\(unknown)\" is not a case of \(F.self)")
        }
        return complaints
    }

    private static func ids(in schema: ConnectionFieldSchema) -> [String] {
        schema.fields.flatMap { field -> [String] in
            if case .group(let leaves) = field.kind {
                return [field.id] + leaves.map(\.id)
            }
            return [field.id]
        }
    }
}
