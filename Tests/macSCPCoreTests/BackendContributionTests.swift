import Foundation
import Testing

@testable import macSCPCore

/// The connection-level action list on `BackendDescriptor` (S3 bucket
/// settings, Task 7).
///
/// This is the seam M22's final review deleted for being empty, rebuilt with
/// four callers present. The guard that holds it to that is
/// `theSeamIsNotEmptyInEveryBackend`: if every backend's list ever empties
/// again, the seam has become the thing M22 removed and should go with it.
@Suite("Backend contributions")
struct BackendContributionTests {
    @Test func onlyS3ContributesConnectionActions() {
        #expect(BackendDescriptor.descriptor(for: .ssh).connectionActions.isEmpty)
        #expect(BackendDescriptor.descriptor(for: .webdav).connectionActions.isEmpty)
        #expect(BackendDescriptor.descriptor(for: .s3).connectionActions.count == 4)
    }

    @Test func theSeamIsNotEmptyInEveryBackend() {
        // The anti-goal, as a test: if every descriptor's list empties, the
        // seam has become the thing M22 removed and should go with it.
        let total = ConnectionKind.allCases
            .map(BackendDescriptor.descriptor(for:))
            .reduce(0) { $0 + $1.connectionActions.count }
        #expect(total > 0)
    }

    @Test func s3OffersTheFourBucketActionsInTheOrderTheMenuShowsThem() {
        let ids = BackendDescriptor.descriptor(for: .s3).connectionActions.map(\.id)
        #expect(ids == ["s3.createBucket", "s3.versioning", "s3.cors", "s3.objectLock"])
    }

    /// The window dispatches a contribution by its id, so two entries sharing
    /// one would make the second unreachable. Paired with a total: an empty
    /// list is trivially duplicate-free.
    @Test func everyActionIdIsUniqueWithinItsBackend() {
        var inspected = 0
        for kind in ConnectionKind.allCases {
            let ids = BackendDescriptor.descriptor(for: kind).connectionActions.map(\.id)
            inspected += ids.count
            #expect(Set(ids).count == ids.count)
        }
        #expect(inspected > 0)
    }

    /// An id is a dispatch key and a title key is a catalogue key; a blank in
    /// either, or an icon-less entry, renders as an empty menu row.
    @Test func everyActionCarriesAllFourFields() {
        var inspected = 0
        for kind in ConnectionKind.allCases {
            for action in BackendDescriptor.descriptor(for: kind).connectionActions {
                inspected += 1
                #expect(!action.id.isEmpty)
                #expect(!action.titleKey.isEmpty)
                #expect(!action.titleDefault.isEmpty)
                #expect(!action.systemImage.isEmpty)
            }
        }
        #expect(inspected > 0)
    }
}
