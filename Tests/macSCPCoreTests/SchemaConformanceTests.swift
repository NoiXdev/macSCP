import Foundation
import Testing
@testable import macSCPCore

private enum SampleField: String, CaseIterable, BackendFieldID {
    case alpha, beta, orphan

    static let namespace = "sample"
}

@Suite("SchemaConformance")
struct SchemaConformanceTests {
    private func descriptor(fieldIDs: [String]) -> BackendDescriptor {
        BackendDescriptor(
            kind: .s3,
            capabilities: BackendDescriptor.descriptor(for: .s3).capabilities,
            connectionSchema: ConnectionFieldSchema(
                fields: fieldIDs.map {
                    ConnectionField(id: $0, labelKey: "k", labelDefault: "L", kind: .text)
                },
                presets: []),
            credentialSchema: ConnectionFieldSchema(fields: [], presets: []),
            makeConfig: { _, _ in throw RemoteFSError.protocolError(reason: "unused") },
            displaySummary: { _ in "" },
            apply: { _, _ in },
            connect: { _, _, _, _ in throw RemoteFSError.protocolError(reason: "unused") },
            badgeLabelKey: "b", badgeLabelDefault: "B",
            secretEnvironmentVariable: nil, requiresSecret: { _ in false },
            fileActions: [],
            endpoint: { _ in nil }, dial: nil, diagnostics: [])
    }

    /// The gap the compiler cannot see: a field the enum declares, that the
    /// factory may well handle, but that appears in NEITHER schema — so no
    /// form ever renders an input for it and the user cannot set it.
    @Test func reportsAFieldMissingFromBothSchemas() {
        let complaints = SchemaConformance.check(
            descriptor(fieldIDs: ["alpha", "beta"]), fields: SampleField.self)
        #expect(complaints.contains { $0.contains("orphan") })
    }

    @Test func acceptsADescriptorCoveringEveryField() {
        let complaints = SchemaConformance.check(
            descriptor(fieldIDs: ["alpha", "beta", "orphan"]), fields: SampleField.self)
        #expect(complaints.isEmpty)
    }

    /// The reverse gap: a schema entry whose id is not in the enum at all.
    /// Impossible to write today from typed call sites, but a decoded or
    /// hand-built schema could carry one.
    @Test func reportsASchemaFieldThatIsNotInTheEnum() {
        let complaints = SchemaConformance.check(
            descriptor(fieldIDs: ["alpha", "beta", "orphan", "ghost"]),
            fields: SampleField.self)
        #expect(complaints.contains { $0.contains("ghost") })
    }

    /// Every field that can FAIL validation must say what to tell the user.
    /// Without this the validator falls back to a generic message and a field
    /// silently loses the specific text it used to have — the exact regression
    /// "the port must be a number" flattening into "this field is required".
    @Test func everyValidatableFieldDeclaresItsMessage() {
        for kind in ConnectionKind.allCases {
            let descriptor = BackendDescriptor.descriptor(for: kind)
            for schema in [descriptor.connectionSchema, descriptor.credentialSchema] {
                for field in schema.fields where field.isRequired || field.format != nil {
                    #expect(
                        field.invalidMessageKey != nil,
                        "\(kind).\(field.id) can fail validation but declares no message key")
                }
            }
        }
    }

    /// The port is the ONE numeric field in the app. Pinned so that adding a
    /// second `.numeric` field is a deliberate act with a test to update, not a
    /// drive-by.
    @Test func onlyTheSSHPortIsNumeric() {
        let numeric = ConnectionKind.allCases.flatMap { kind -> [String] in
            let descriptor = BackendDescriptor.descriptor(for: kind)
            return [descriptor.connectionSchema, descriptor.credentialSchema]
                .flatMap(\.fields)
                .filter { $0.format == .numeric }
                .map { "\(kind).\($0.id)" }
        }
        #expect(numeric == ["ssh.port"])
    }
}
