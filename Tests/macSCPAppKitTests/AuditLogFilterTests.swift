import Foundation
import MacSCPTestSupport
import Testing

@testable import MacSCPAppKit
@testable import macSCPCore

/// Which audit-log segment shows which kind of event.
///
/// The question this suite exists for: a kind the filter does not mention
/// is invisible under every segment but All and Errors, and nothing says so.
/// `ConnectionHistory.rows` answers the same question the other way round --
/// it spells every kind out, with no `default`, so a kind added later has to
/// be classified there. The segment filter used to carry four `default:`
/// arms instead, and the four S3 bucket-settings kinds fell through them:
/// after a COMPLIANCE retention (the one write macSCP makes that cannot be
/// undone) the File Ops segment did not list the line.
@Suite("Audit-log filter segments")
struct AuditLogFilterTests {
    typealias Filter = AuditLogSheet.Filter

    /// The segments that name a kind of thing, as opposed to All (shows
    /// everything) and Errors (shows by outcome, whatever the kind).
    private static let kindSegments: [Filter] = [.transfers, .fileOps, .terminal, .connection]

    private static func event(_ kind: AuditEvent.Kind) -> AuditEvent {
        AuditEvent(kind: kind, detail: "x")
    }

    /// The four kinds `Task 12` added. File Ops is a coordinator ruling
    /// (Ruling 19), not something the brief or the review asked for.
    private static let bucketSettingsKinds: [AuditEvent.Kind] = [
        .bucketCreated, .versioningChanged, .corsChanged, .objectLockChanged,
    ]

    @Test(arguments: bucketSettingsKinds)
    func aBucketSettingsWriteIsListedUnderFileOps(kind: AuditEvent.Kind) {
        let listed = Filter.fileOps.includes(Self.event(kind))
        #expect(listed)
    }

    @Test(arguments: bucketSettingsKinds)
    func aBucketSettingsWriteIsListedUnderNoOtherKindSegment(kind: AuditEvent.Kind) {
        let others = Self.kindSegments.filter { $0 != .fileOps }
        // The positive half: the segments are really being asked.
        #expect(others.count == 3)
        let listedElsewhere = others.filter { $0.includes(Self.event(kind)) }
        #expect(listedElsewhere.isEmpty)
    }

    @Test(arguments: bucketSettingsKinds)
    func aBucketSettingsWriteIsListedUnderAll(kind: AuditEvent.Kind) {
        let listed = Filter.all.includes(Self.event(kind))
        #expect(listed)
    }

    @Test func aFailedBucketSettingsWriteIsListedUnderErrorsToo() {
        let failed = AuditEvent(kind: .objectLockChanged, detail: "x", isError: true)
        let listed = Filter.errors.includes(failed)
        #expect(listed)
    }

    /// The classification as it stood before the four kinds, pinned so that
    /// moving to an exhaustive `switch` is shown not to have moved anything
    /// else.
    @Test(arguments: [
        (AuditEvent.Kind.transferFinished, Filter.transfers),
        (.transferFailed, .transfers),
        (.transferCancelled, .transfers),
        (.editUpload, .transfers),
        (.crossSessionTransfer, .transfers),
        (.rename, .fileOps),
        (.delete, .fileOps),
        (.permissions, .fileOps),
        (.newFolder, .fileOps),
        (.newFile, .fileOps),
        (.snippetExecuted, .terminal),
        (.connected, .connection),
        (.disconnected, .connection),
        (.connectFailed, .connection),
    ])
    func theKindsClassifiedBeforeTheBucketSettingsKindsStayWhereTheyWere(
        kind: AuditEvent.Kind, segment: Filter
    ) {
        let own = Self.kindSegments.filter { $0.includes(Self.event(kind)) }
        #expect(own == [segment])
    }

    /// Every kind is in AT MOST one kind segment, and the kinds in none are a
    /// short, named list. `plaintextConfirmed` is in none and always was: it
    /// shows under All and Errors only. That is a recorded gap in the
    /// classification, not a decision anyone made for it.
    @Test func everyKindIsInAtMostOneKindSegmentAndTheUnplacedAreNamed() {
        let all = AuditEvent.Kind.allCases
        // The positive half: the scan sees the kinds at all.
        #expect(all.count > 15)
        var unplaced: [AuditEvent.Kind] = []
        for kind in all {
            let segments = Self.kindSegments.filter { $0.includes(Self.event(kind)) }
            #expect(segments.count <= 1, "\(kind) is in more than one kind segment")
            if segments.isEmpty { unplaced.append(kind) }
        }
        #expect(unplaced == [.plaintextConfirmed])
    }

    /// The structural half: the classification is a `switch` over
    /// `AuditEvent.Kind` with no `default`, so a kind added later does not
    /// compile until it is placed. A `default` arm would let it through.
    /// The negative check ("no `default`") has its positive beside it: the
    /// body found is the one that names the last kind.
    @Test func theClassificationHasNoDefaultArm() throws {
        let url = SourceCorpus.packageRoot
            .appendingPathComponent("Sources/MacSCPAppKit/AuditLogSheet.swift")
        let source = try SourceCorpus.commentFree(of: url)
        let lines = source.components(separatedBy: "\n")
        let start = try #require(lines.firstIndex { $0.contains("func segment(of") })
        let indent = String(lines[start].prefix { $0 == " " })
        let end = try #require(lines[(start + 1)...].firstIndex { $0.hasPrefix(indent + "}") })
        let body = lines[start...end].joined(separator: "\n")
        #expect(body.contains("switch kind"))
        #expect(body.contains(".objectLockChanged"))
        let hasDefault = body.contains("default:")
        #expect(!hasDefault)
    }
}
