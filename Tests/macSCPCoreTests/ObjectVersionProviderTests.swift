import Foundation
import Testing
@testable import macSCPCore

/// The value types and the capability protocol of one object's version
/// history. This suite pins what the types themselves promise; the XML
/// mapping and the S3 conformance will be tested beside the code that adds
/// them.
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

    @Test func aPageCarriesItsVersionsInExactlyTheOrderTheyWereGiven() {
        // Deliberately neither by id nor by date, ascending or descending.
        let given = [
            ObjectVersion(
                versionId: "m", key: "doc.txt", isLatest: false, isDeleteMarker: false,
                size: 3, modifiedAt: Date(timeIntervalSince1970: 200), entityTag: nil),
            ObjectVersion(
                versionId: "z", key: "doc.txt", isLatest: true, isDeleteMarker: true,
                size: nil, modifiedAt: Date(timeIntervalSince1970: 100), entityTag: nil),
            ObjectVersion(
                versionId: "b", key: "doc.txt", isLatest: false, isDeleteMarker: false,
                size: 7, modifiedAt: Date(timeIntervalSince1970: 300), entityTag: nil),
            ObjectVersion(
                versionId: "a", key: "doc.txt", isLatest: false, isDeleteMarker: false,
                size: 1, modifiedAt: nil, entityTag: nil),
        ]
        let page = ObjectVersionPage(versions: given, nextKeyMarker: nil, nextVersionIdMarker: nil)
        #expect(page.versions == given)
    }
}
