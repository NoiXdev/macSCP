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
    /// `AuditEvent.Kind` whose every arm names a kind, so a kind added later
    /// does not compile until it is placed. A catch-all arm would let it
    /// through, and a catch-all has more than one spelling (`default:`,
    /// `case _:`, `case let other:`), so the property is stated once, about
    /// the arms rather than about the spellings: **every pattern of every arm
    /// is a leading-dot case name, and together they are exactly the cases of
    /// `AuditEvent.Kind`, each once.** Nothing else is an arm. The kinds are
    /// read off the enum, not typed here, and the raw value of each is its
    /// case name.
    ///
    /// The scan reads the blanked view that drops comments AND string
    /// literals (`code(of:)`), so neither can satisfy or defeat it. The
    /// negative check has its positive beside it: the body found has more
    /// than a handful of arms, and they name every kind.
    @Test func everyArmOfTheClassificationNamesAKindAndTogetherTheyAreAllOfThem() throws {
        let url = SourceCorpus.packageRoot
            .appendingPathComponent("Sources/MacSCPAppKit/AuditLogSheet.swift")
        let source = try SourceCorpus.code(of: url)
        let lines = source.components(separatedBy: "\n")
        let start = try #require(lines.firstIndex { $0.contains("func segment(of") })
        let indent = String(lines[start].prefix { $0 == " " })
        let end = try #require(lines[(start + 1)...].firstIndex { $0.hasPrefix(indent + "}") })
        let body = lines[start...end].joined(separator: "\n")
        #expect(body.contains("switch kind"))

        // `default:` is not a `case`, so it is looked for as what it is.
        let hasDefault = body.contains("default:")
        #expect(!hasDefault)

        // Every arm's patterns: the text between `case ` and the colon that
        // ends the arm head, split on commas. An enum-case pattern has no
        // colon of its own, so the first colon after `case` ends the head.
        let arms = try NSRegularExpression(pattern: "\\bcase\\s+([^:]+):")
        let range = NSRange(body.startIndex..., in: body)
        let patterns: [String] = arms.matches(in: body, range: range).flatMap { match -> [String] in
            guard let head = Range(match.range(at: 1), in: body) else { return [] }
            return body[head].split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        let allKinds = AuditEvent.Kind.allCases.map { ".\($0.rawValue)" }
        // The positive half: the scan sees the arms at all.
        #expect(allKinds.count > 15)
        #expect(patterns.count > 15)

        // Not a name: `_`, `let x`, `var x`, `x`, `.a(let b)` -- anything but
        // a leading-dot case name.
        let notACaseName = patterns.filter {
            $0.range(of: "^\\.[A-Za-z]+$", options: .regularExpression) == nil
        }
        #expect(notACaseName.isEmpty, "arm patterns that are not a case name: \(notACaseName)")
        // Every kind exactly once.
        #expect(patterns.sorted() == allKinds.sorted())
    }

    /// Errors lists by outcome and nothing else: a kind's own events that did
    /// not fail are not in it. Without the negative half, `.errors` returning
    /// `true` for everything passes every test above (they only ever ask it
    /// about one failed event), and Errors becomes All. The positive half is
    /// beside it: the same kind, failed, IS in it.
    @Test(arguments: AuditEvent.Kind.allCases)
    func theErrorsSegmentListsAFailedEventAndNotASuccessfulOne(kind: AuditEvent.Kind) {
        let failed = AuditEvent(kind: kind, detail: "x", isError: true)
        let succeeded = AuditEvent(kind: kind, detail: "x", isError: false)
        let listsTheFailure = Filter.errors.includes(failed)
        let listsTheSuccess = Filter.errors.includes(succeeded)
        #expect(listsTheFailure)
        #expect(!listsTheSuccess)
    }
}
