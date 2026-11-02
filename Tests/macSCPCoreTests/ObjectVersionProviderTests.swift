import Foundation
import Testing
@testable import macSCPCore

/// The value types and the capability protocol of one object's version
/// history. The conformance and the XML mapping are tested where they are
/// written; this suite pins what the types themselves promise.
@Suite("Object version provider types")
struct ObjectVersionProviderTests {
    @Test func anObjectVersionIsIdentifiedByItsVersionId() {
        let v = ObjectVersion(
            versionId: "abc", key: "doc.txt", isLatest: true, isDeleteMarker: false,
            size: 19, modifiedAt: nil, entityTag: nil)
        #expect(v.id == "abc")
    }

    @Test func aPageWithoutANextKeyMarkerIsNotTruncated() {
        let page = ObjectVersionPage(versions: [], nextKeyMarker: nil, nextVersionIdMarker: nil)
        #expect(page.isTruncated == false)
    }

    @Test func aPageWithANextKeyMarkerIsTruncatedEvenWithoutAVersionIdMarker() {
        let page = ObjectVersionPage(versions: [], nextKeyMarker: "doc.txt", nextVersionIdMarker: nil)
        #expect(page.isTruncated)
    }
}
