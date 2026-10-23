import Foundation
import Testing

@testable import macSCPCore

/// The trail the five S3 bucket-settings writes leave (S3 bucket settings,
/// Task 12): which kind each is recorded under, what its line says, and that
/// a refused write does not read as done.
///
/// These pin the Core half -- the line a recorder composes from the values
/// the sheet hands it. That the sheets hand it anything at all is
/// `BucketSettingsAuditTests` in the App's test target.
@Suite("AuditRecorder bucket settings")
struct AuditRecorderBucketSettingsTests {
    /// 2027-01-15T08:00:00Z. Checked with
    /// `python3 -c "import datetime; print(datetime.datetime.utcfromtimestamp(1_800_000_000).isoformat())"`.
    private static let someDate = Date(timeIntervalSince1970: 1_800_000_000)
    private static let someDateText = "2027-01-15T08:00:00Z"

    private func recorded(_ record: (AuditRecorder) -> Void) -> [AuditEvent] {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AuditRecorderBucketSettingsTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sessionID = UUID()
        let store = AuditLogStore(directory: dir)
        record(AuditRecorder(sessionID: sessionID, store: store))
        return store.events(for: sessionID)
    }

    @Test func theFourNewKindsAreDeclaredWithTheSpellingsTheCatalogueUses() {
        let declared = Set(AuditEvent.Kind.allCases.map(\.rawValue))
        #expect(
            declared.isSuperset(of: ["bucketCreated", "versioningChanged", "corsChanged", "objectLockChanged"]))
    }

    // MARK: - One kind per operation

    @Test func aCreatedBucketIsRecordedAsBucketCreatedWithItsProtection() {
        let plain = recorded { $0.recordBucketCreated(
            bucket: "macscp-third", protection: .none, bucketDefault: nil, failure: nil)
        }
        let versioned = recorded {
            $0.recordBucketCreated(
                bucket: "macscp-third", protection: .versioned, bucketDefault: nil, failure: nil)
        }
        let locked = recorded {
            $0.recordBucketCreated(
                bucket: "macscp-third", protection: .lockedAndVersioned, bucketDefault: nil,
                failure: nil)
        }
        #expect(plain.map(\.kind) == [.bucketCreated])
        #expect(plain.first?.detail == "created bucket macscp-third")
        #expect(versioned.first?.detail == "created bucket macscp-third with versioning")
        #expect(locked.first?.detail == "created bucket macscp-third with versioning and Object Lock")
        #expect(plain.first?.isError == false)
    }

    @Test func aVersioningChangeNamesTheBucketAndTheStateItMovedTo() {
        let enabled = recorded { $0.recordVersioningChanged(bucket: "b1", to: .enabled, failure: nil) }
        let suspended = recorded { $0.recordVersioningChanged(bucket: "b1", to: .suspended, failure: nil) }
        #expect(enabled.map(\.kind) == [.versioningChanged])
        #expect(enabled.first?.detail == "versioning of bucket b1 set to enabled")
        #expect(suspended.first?.detail == "versioning of bucket b1 set to suspended")
    }

    @Test func aCORSSaveNamesTheBucketAndHowManyRules() {
        let some = recorded { $0.recordCORSChanged(bucket: "b1", ruleCount: 2, failure: nil) }
        let one = recorded { $0.recordCORSChanged(bucket: "b1", ruleCount: 1, failure: nil) }
        let cleared = recorded { $0.recordCORSChanged(bucket: "b1", ruleCount: 0, failure: nil) }
        #expect(some.map(\.kind) == [.corsChanged])
        #expect(some.first?.detail == "CORS rules of bucket b1 set to 2 rules")
        #expect(one.first?.detail == "CORS rules of bucket b1 set to 1 rule")
        // An empty save is not "0 rules": the store reads it back as no
        // configuration at all (`S3BucketSettings.setCORS`), and the line says
        // what happened.
        #expect(cleared.first?.detail == "CORS configuration of bucket b1 cleared")
    }

    // MARK: - One kind, three operations

    @Test func anObjectLockLineNamesWhichOfTheThreeOperationsItWas() {
        let compliance = ObjectRetention(mode: .compliance, retainUntil: Self.someDate)
        let retention = recorded {
            $0.recordObjectLockChanged(
                .retention(compliance, key: "reports/q3.pdf", bucket: "b1"), failure: nil)
        }
        let hold = recorded {
            $0.recordObjectLockChanged(.legalHold(true, key: "reports/q3.pdf", bucket: "b1"), failure: nil)
        }
        let bucketDefault = recorded {
            $0.recordObjectLockChanged(.bucketDefault(days: 30, mode: .compliance, bucket: "b1"), failure: nil)
        }
        // All three are one kind: the kind cannot separate them, the detail
        // has to.
        #expect(retention.map(\.kind) == [.objectLockChanged])
        #expect(hold.map(\.kind) == [.objectLockChanged])
        #expect(bucketDefault.map(\.kind) == [.objectLockChanged])

        let details = [retention, hold, bucketDefault].compactMap { $0.first?.detail }
        #expect(details.count == 3)
        #expect(Set(details).count == 3)

        // The one assertion the 2026-10-19 decision rests on: a COMPLIANCE
        // retention's line names the mode and the date, and the object.
        #expect(
            retention.first?.detail
                == "retention of b1/reports/q3.pdf set to COMPLIANCE until \(Self.someDateText)")
        #expect(hold.first?.detail == "legal hold on b1/reports/q3.pdf placed")
        #expect(bucketDefault.first?.detail == "default retention of bucket b1 set to COMPLIANCE for 30 days")
    }

    @Test func aGovernanceRetentionNamesItsModeSoItCannotBeReadAsTheOtherOne() {
        // The positive control for the test above: the mode in the line is the
        // mode that was written, not a constant.
        let governance = recorded {
            $0.recordObjectLockChanged(
                .retention(
                    ObjectRetention(mode: .governance, retainUntil: Self.someDate), key: "k", bucket: "b1"),
                failure: nil)
        }
        let detail = governance.first?.detail ?? ""
        #expect(detail.contains("GOVERNANCE"))
        #expect(detail.contains("COMPLIANCE") == false)
    }

    @Test func aReleasedLegalHoldIsNotRecordedAsAPlacedOne() {
        let released = recorded {
            $0.recordObjectLockChanged(.legalHold(false, key: "k", bucket: "b1"), failure: nil)
        }
        #expect(released.first?.detail == "legal hold on b1/k released")
    }

    @Test func aRetentionDateIsWrittenInUTCWhateverTheMachinesZoneIs() {
        // Fixed to UTC and to the internet date-time form, so the line reads
        // the same wherever and whenever it is read back.
        let cases = [Date(timeIntervalSince1970: 0), Self.someDate]
        let texts = cases.map { date in
            recorded {
                $0.recordObjectLockChanged(
                    .retention(ObjectRetention(mode: .governance, retainUntil: date), key: "k", bucket: "b"),
                    failure: nil)
            }.first?.detail ?? ""
        }
        #expect(texts[0].hasSuffix("until 1970-01-01T00:00:00Z"))
        #expect(texts[1].hasSuffix("until \(Self.someDateText)"))
    }

    // MARK: - A refusal

    @Test func aRefusedOperationRecordsTheFailureAndNotASuccess() {
        let sentence = "The store refused the change."
        let events = recorded {
            $0.recordBucketCreated(
                bucket: "b1", protection: .none, bucketDefault: nil, failure: sentence)
            $0.recordVersioningChanged(bucket: "b1", to: .enabled, failure: sentence)
            $0.recordCORSChanged(bucket: "b1", ruleCount: 1, failure: sentence)
            $0.recordObjectLockChanged(.bucketDefault(days: 1, mode: .governance, bucket: "b1"), failure: sentence)
        }
        #expect(events.count == 4)
        #expect(events.allSatisfy { $0.isError })
        #expect(events.allSatisfy { $0.errorMessage == sentence })
        // The line still says WHAT was attempted -- the same text a success
        // would have carried -- so the error row is findable by what it was.
        #expect(events.first?.detail == "created bucket b1")
    }

    @Test func aSuccessCarriesNoErrorMessage() {
        // The positive control for the test above.
        let events = recorded {
            $0.recordVersioningChanged(bucket: "b1", to: .enabled, failure: nil)
        }
        #expect(events.first?.isError == false)
        #expect(events.first?.errorMessage == nil)
    }
}
