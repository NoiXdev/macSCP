import Foundation
import Testing
@testable import macSCPCore

/// The value types of `ObjectMetadataProvider`. Pure: no transport, no store.
@Suite("Object metadata provider types")
struct ObjectMetadataProviderTests {
    @Test func aGrantWithNeitherIdNorNameHasAnUnnamedHolder() {
        let g = ACLGrant(granteeID: nil, granteeDisplayName: nil, permission: "FULL_CONTROL")
        #expect(g.holderIsUnnamed)
    }

    // This checks its own literal input, so it cannot fail on any
    // implementation: it states the type's contract, it does not measure it.
    // The boundary that must honour the contract is tested in Task 2 (a HEAD
    // carrying `x-amz-meta-note` must yield `custom["note"]`, not
    // `custom["x-amz-meta-note"]`).
    @Test func customMetadataKeysCarryNoTransportPrefix() {
        let m = ObjectMetadata(
            contentType: nil, cacheControl: nil, contentDisposition: nil,
            custom: ["note": "x"], entityTag: nil)
        let carriesPrefix = m.custom.keys.contains { $0.hasPrefix("x-amz-meta-") }
        #expect(carriesPrefix == false)
    }
}
