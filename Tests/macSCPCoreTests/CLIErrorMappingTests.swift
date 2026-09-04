import Foundation
import Testing
@testable import macSCPCore

/// Pins `CLIErrorMapping` — previously shipped without a single test (M20
/// Task 10). The one distinction a script actually branches on is host-key
/// mismatch (12, hard stop) vs. unknown/rejected (11, a work item); the rest
/// of these lock down the other cases this task's `get`/`put` newly rely on.
@Suite("CLIErrorMapping")
struct CLIErrorMappingTests {
    @Test func hostKeyMismatchExitsWithTheAlarmCode() {
        let error = HostKeyError.mismatch(host: "prod", expected: "AA:BB", presented: "CC:DD")
        #expect(CLIErrorMapping.exitCode(for: error) == .hostKeyMismatch)
    }

    @Test func rejectedUnknownHostKeyExitsWithTheWorkItemCode() {
        #expect(CLIErrorMapping.exitCode(for: HostKeyError.rejectedByUser) == .hostKeyUnknown)
    }

    @Test func directorySourceIsAUsageError() {
        let error = TransferSourceError.isDirectory(path: "/var/logs")
        #expect(CLIErrorMapping.exitCode(for: error) == .usage)
    }

    @Test func deleteDirectoryWithoutRecursiveIsAUsageError() {
        let error = DeleteSourceError.isDirectory(path: "/var/logs")
        #expect(CLIErrorMapping.exitCode(for: error) == .usage)
    }

    @Test func destinationConflictExitsWithTheConflictCode() {
        let error = TransferPlanError.conflict("/tmp/dist.tar.gz")
        #expect(CLIErrorMapping.exitCode(for: error) == .conflict)
    }

    /// Distinct from `.conflict` (M20 Task 10 fix): a blank destination
    /// directory is a malformed argument, not "the destination already has
    /// something there" — conflating the two would make a script's `== 15`
    /// branch fire for a typo instead of a real collision.
    @Test func emptyDestinationDirectoryIsAUsageErrorNotAConflict() {
        #expect(CLIErrorMapping.exitCode(for: TransferPlanError.emptyDestinationDirectory) == .usage)
    }

    @Test func messageForDeleteDirectoryWithoutRecursiveMentionsTheFlag() {
        let message = CLIErrorMapping.message(for: DeleteSourceError.isDirectory(path: "/var/logs"))
        #expect(message.contains("/var/logs"))
        #expect(message.contains("--recursive"))
    }

    @Test func messageForHostKeyMismatchNamesBothFingerprints() {
        let message = CLIErrorMapping.message(
            for: HostKeyError.mismatch(host: "prod", expected: "AA:BB", presented: "CC:DD"))
        #expect(message.contains("AA:BB"))
        #expect(message.contains("CC:DD"))
    }

    /// `PasswordCommandError`'s own doc comment promises it "carries no
    /// trace of the command's input or output" specifically so a printed
    /// error can never disclose a secret. This locks the promise down at
    /// the point where the error becomes user-visible text: an associated
    /// `String` capturing stdout would still compile here but would change
    /// this literal, so the test would have to be edited (and re-justified)
    /// to let one through.
    @Test func passwordCommandFailureMessageNeverEchoesCommandOutput() {
        let message = CLIErrorMapping.message(for: PasswordCommandError.commandFailed(status: 1))
        #expect(message == "Error: --password-command failed: commandFailed(status: 1)")
    }

    // MARK: - The S3 bucket-list outcomes (Task 3 review, I-2)

    /// None of the three S3 cases had a test, so their sentences had never
    /// been read by anything but their author — which is how
    /// "macSCP does not createDirectory buckets" shipped.
    @Test func theBucketListOutcomesExitWithTheirOwnCodesAndSayWhy() {
        #expect(CLIErrorMapping.exitCode(for: RemoteFSError.bucketListForbidden) == .auth)
        #expect(CLIErrorMapping.exitCode(for: RemoteFSError.bucketListEmpty) == .remote)

        let forbidden = CLIErrorMapping.message(for: RemoteFSError.bucketListForbidden)
        #expect(forbidden == "Error: this key may not list the account's buckets")
        let empty = CLIErrorMapping.message(for: RemoteFSError.bucketListEmpty)
        #expect(empty == "Error: this key may list buckets, but the account has none")
    }

    /// Every operation, iterated rather than enumerated: a case added to
    /// `BucketLevelOperation` cannot reach the CLI without a sentence,
    /// because the mapping's own `switch` is exhaustive — and it cannot
    /// reach it with a RAW one, because of the check below.
    ///
    /// "Raw" is decided by CASE, not by the whole identifier: `write`,
    /// `delete` and `rename` are ordinary English words that a written
    /// sentence may legitimately contain, while a rawValue carrying an
    /// interior capital (`createDirectory`, `deleteTree`, `presignedURL`,
    /// `readStream` — four, counted against the enum in this pass)
    /// can only ever be an identifier that leaked. That is exactly the
    /// defect this replaces ("macSCP does not createDirectory buckets"),
    /// and the floor below keeps the rule from scanning nothing if the
    /// enum ever loses its multi-word cases.
    @Test func everyBucketLevelRefusalPrintsProseAndNamesThePath() {
        var camelCased = 0
        for operation in RemoteFSError.BucketLevelOperation.allCases {
            let error = RemoteFSError.bucketLevelRefused(
                operation: operation, path: "/mybucket")
            #expect(CLIErrorMapping.exitCode(for: error) == .remote)

            let message = CLIErrorMapping.message(for: error)
            #expect(message.contains("/mybucket"))
            #expect(message.hasPrefix("Error: "))

            guard operation.rawValue.contains(where: \.isUppercase) else { continue }
            camelCased += 1
            #expect(!message.contains(operation.rawValue), """
                the CLI sentence for \(operation) still carries the raw identifier: \(message)
                """)
        }
        #expect(camelCased >= 3, """
            only \(camelCased) operation(s) carry an interior capital — the identifier-leak \
            half of this check scanned almost nothing.
            """)
    }

    /// …and no two operations share a sentence, so the `switch` is really
    /// one answer per case and not one answer written N times. Deliberately
    /// carries no cardinality: the count is `allCases`, and a name that
    /// spells it is a second copy that goes stale the next time a case is
    /// added (it did, when `readStream` made six seven).
    @Test func everyRefusalSentenceIsItsOwnSentence() {
        let messages = RemoteFSError.BucketLevelOperation.allCases.map {
            CLIErrorMapping.message(for: RemoteFSError.bucketLevelRefused(
                operation: $0, path: "/mybucket"))
        }
        #expect(Set(messages).count == messages.count)
        #expect(messages.count == RemoteFSError.BucketLevelOperation.allCases.count)
    }

    /// The cross-bucket rename has its OWN frame, and deliberately not the
    /// "<path> is a bucket" one: neither end of such a rename is a bucket,
    /// so borrowing that sentence would print something false.
    @Test func aCrossBucketRenameSaysWhatItRefusedAndNamesBothEnds() {
        let error = RemoteFSError.crossBucketRenameRefused(
            from: "/one/a.txt", to: "/two/a.txt")

        #expect(CLIErrorMapping.exitCode(for: error) == .remote)

        let message = CLIErrorMapping.message(for: error)
        #expect(message.contains("/one/a.txt"))
        #expect(message.contains("/two/a.txt"))
        #expect(!message.contains("is a bucket"))
    }

    // MARK: - diagnose

    /// The refusal exists so the exit code is 2 and not ArgumentParser's own
    /// 64 — see `DiagnoseUsageError`'s doc comment. This is the half of that
    /// argument a test can hold.
    @Test(arguments: [DiagnosticScope.dial, .contributions])
    func aScopeThatNeedsASessionIsAUsageError(scope: DiagnosticScope) throws {
        let error = try #require(DiagnoseUsageError.refusal(forEndpointScope: scope))
        #expect(CLIErrorMapping.exitCode(for: error) == .usage)
        // The scope names itself in the message, so a script's user can see
        // WHICH scope was refused without re-reading their own command line.
        #expect(CLIErrorMapping.message(for: error).contains(scope.rawValue))
    }

    /// The positive half of the check above: the three scopes a bare
    /// endpoint may run are not refused. Without this, a `refusal` that
    /// returned an error for everything would still satisfy the case above.
    @Test(arguments: [DiagnosticScope.complete, .ping, .trace])
    func aScopeAnEndpointCanRunIsNotRefused(scope: DiagnosticScope) {
        #expect(DiagnoseUsageError.refusal(forEndpointScope: scope) == nil)
    }

    /// Every scope is on exactly one of the two lists above — derived from
    /// `allCases` rather than from the two enumerations, so a sixth scope
    /// turns this red instead of quietly joining neither.
    @Test func everyScopeIsEitherRefusedOrPermitted() {
        let refused = DiagnosticScope.allCases.filter {
            DiagnoseUsageError.refusal(forEndpointScope: $0) != nil
        }
        #expect(refused.count == 2, "refused: \(refused.map(\.rawValue))")
        #expect(DiagnosticScope.allCases.count == 5)
    }
}
