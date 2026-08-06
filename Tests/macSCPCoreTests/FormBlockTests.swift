import Foundation
import Testing
@testable import macSCPCore

/// The guard the `schemas: [ConnectionFieldSchema]` parameter could not give.
/// A list documents the invariant; it does not enforce it — a section that
/// renders two views with one schema each is a legal call, and deleting one of
/// them still compiles and still passes. Putting the block ORDER in Core moves
/// the mistake somewhere a test can see it.
@Suite("Form blocks")
struct FormBlockTests {
    @Test func manualModeRendersEveryFieldExactlyOnce() {
        for kind in ConnectionKind.allCases {
            let descriptor = BackendDescriptor.descriptor(for: kind)
            let rendered = descriptor.formBlocks(usingLoginSet: false).compactMap {
                if case .schema(let s) = $0 { return s } else { return nil }
            }
            #expect(rendered == [descriptor.connectionSchema, descriptor.credentialSchema])
        }
    }

    /// A field named by BOTH schemas draws two rows in manual mode — the block
    /// list concatenates them — and in login-set mode the connection copy
    /// keeps asking for what the chosen set already supplies. SSH carried four
    /// such overlaps (user name, auth kind, key path, managed key) until
    /// M22/T8 made the form render both schemas and the duplication visible.
    @Test func aFieldBelongsToExactlyOneSchema() {
        for kind in ConnectionKind.allCases {
            let descriptor = BackendDescriptor.descriptor(for: kind)
            let connection = Set(descriptor.connectionSchema.fields.map(\.id))
            let credential = Set(descriptor.credentialSchema.fields.map(\.id))
            let both = connection.intersection(credential).sorted()
            #expect(both.isEmpty, "\(kind) names \(both) in both schemas")
        }
    }

    /// With a login set chosen the credential schema is deliberately absent —
    /// the set supplies it. The connection schema must still be there.
    @Test func loginSetModeSubstitutesTheCredentialSchema() {
        for kind in ConnectionKind.allCases {
            let descriptor = BackendDescriptor.descriptor(for: kind)
            let blocks = descriptor.formBlocks(usingLoginSet: true)
            #expect(blocks.contains(.schema(descriptor.connectionSchema)))
            #expect(!blocks.contains(.schema(descriptor.credentialSchema)))
            #expect(blocks.contains(.loginSetPicker))
        }
    }
}
