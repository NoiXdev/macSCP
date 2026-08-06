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
            connect: { _, _, _ in throw RemoteFSError.protocolError(reason: "unused") },
            badgeLabelKey: "b", badgeLabelDefault: "B",
            secretEnvironmentVariable: nil, requiresSecret: { _ in false },
            fileActions: [])
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
}
