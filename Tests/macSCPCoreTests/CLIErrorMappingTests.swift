import Foundation
import MacSCPTestSupport
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
    @Test(arguments: [DiagnosticScope.dial, .contributions, .throughput])
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
        #expect(refused.count == 3, "refused: \(refused.map(\.rawValue))")
        #expect(DiagnosticScope.allCases.count == 6)
    }

    /// An unreadable forwarding store exits the way an unreadable SESSION
    /// store already does — the code is read off the error `SessionStore`
    /// really throws for a garbage file, not written down here, so the two
    /// store failures cannot drift apart unnoticed.
    @Test func anUnreadableForwardingStoreExitsLikeAnUnreadableSessionStore() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-cli-error-mapping-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: dir.appendingPathComponent("sessions-v2.json"))
        var sessionStoreFailure: (any Error)?
        do {
            _ = try SessionStore(directory: dir).all()
        } catch {
            sessionStoreFailure = error
        }
        let reference = try #require(sessionStoreFailure, "a garbage sessions-v2.json decoded")

        let error = TunnelStoreError.unreadable(path: "/tmp/store/tunnels.json")
        #expect(CLIErrorMapping.exitCode(for: error) == CLIErrorMapping.exitCode(for: reference))
    }

    /// The message names the file and says it was not changed, so the person
    /// reading stderr knows which file to look at and that nothing was lost.
    @Test func anUnreadableForwardingStoreNamesTheFile() {
        let message = CLIErrorMapping.message(
            for: TunnelStoreError.unreadable(path: "/tmp/store/tunnels.json"))
        #expect(message.contains("/tmp/store/tunnels.json"))
        #expect(message.contains("could not be read"))
        #expect(message.contains("not changed"))
    }

    // MARK: - No raw error reaches stderr (final review of 2026-09-19, the CLI fix)

    /// A backend's own reason reaches stderr filtered — kept, because the CLI
    /// is where a person or a script debugs a connection, but with every
    /// URL's userinfo cut out, the way the transfer queue shows it. The
    /// credential lives in `TransferErrorSecrecyTests`' named constants, and
    /// each leak `Bool` is computed before its `#expect`.
    @Test func aBackendsReasonReachesStderrWithoutUserinfo() {
        let reason = "S3 request failed at \(TransferErrorSecrecyTests.credentialURL)"
        let kept = "S3 request failed at https://s3.example.test/macscp-seed/remote.bin"
        for error in [
            RemoteFSError.connectionFailed(reason: reason), .protocolError(reason: reason),
        ] {
            let message = CLIErrorMapping.message(for: error)
            let leaks = TransferErrorSecrecyTests.leaks(message)
            let keepsTheReason = message.contains(kept)
            #expect(leaks == false, "stderr carries the credential")
            #expect(keepsTheReason, "stderr lost the backend's reason")
        }
        // The frames themselves are unchanged.
        #expect(CLIErrorMapping.message(for: RemoteFSError.connectionFailed(reason: "x"))
            == "Error: connection failed: x")
        #expect(CLIErrorMapping.message(for: RemoteFSError.protocolError(reason: "x")) == "Error: x")
    }

    /// An error no arm names — a raw `URLError` a backend forgot to wrap —
    /// used to reach stderr as its whole description, which prints the
    /// failing URL out of its `userInfo`, credential and all. It now reads
    /// `DialSupport.reason(for:)`'s sentence (a foreign error's localized
    /// sentence, never its description), filtered, and exits as before.
    @Test func anUnmappedErrorReachesStderrWithoutItsDescription() {
        let raw = TransferErrorSecrecyTests.lostConnectionCarryingTheCredential
        let message = CLIErrorMapping.message(for: raw)
        let leaks = TransferErrorSecrecyTests.leaks(message)
        let readsTheSentence =
            message == "Error: " + URLText.withoutUserinfo(DialSupport.reason(for: raw))
        #expect(leaks == false, "stderr carries the credential")
        #expect(readsTheSentence)
        #expect(CLIErrorMapping.exitCode(for: raw) == .connection)
    }

    /// The same fallback for an error whose localized sentence itself quotes
    /// the URL: the filter is what stands between it and stderr.
    @Test func anUnmappedErrorsOwnSentenceReachesStderrWithoutUserinfo() {
        let foreign = NSError(
            domain: NSURLErrorDomain, code: URLError.badServerResponse.rawValue,
            userInfo: [
                NSLocalizedDescriptionKey: "no answer from \(TransferErrorSecrecyTests.credentialURL)",
                NSURLErrorFailingURLStringErrorKey: TransferErrorSecrecyTests.credentialURL,
            ])
        let message = CLIErrorMapping.message(for: foreign)
        let leaks = TransferErrorSecrecyTests.leaks(message)
        let readsTheFilteredSentence =
            message == "Error: no answer from https://s3.example.test/macscp-seed/remote.bin"
        #expect(leaks == false, "stderr carries the credential")
        #expect(readsTheFilteredSentence)
    }

    /// The case that fires in practice: an S3 endpoint whose secret holds a
    /// `/` does not parse, and `URLText.withoutUserinfo` cannot clean it —
    /// so the CLI filter alone would be false assurance here. The throw
    /// sites carry a fixed sentence instead (`S3EndpointReason`), and that
    /// is what reaches stderr.
    @Test func anUnparseableS3EndpointReachesStderrWithoutTheCredential() {
        let config = S3EndpointSecrecyTests.config(
            endpoint: S3EndpointSecrecyTests.unparseableEndpoint, usePathStyle: true)
        var message = ""
        do {
            _ = try S3FileSystem.signedRequest(.bucketRoot(bucket: "macscp-seed"), method: "GET", config: config)
        } catch {
            message = CLIErrorMapping.message(for: error)
        }
        let leaks = S3EndpointSecrecyTests.leaks(message)
        let readsTheRefusal = message == "Error: connection failed: \(S3EndpointReason.unparseable)"
        #expect(leaks == false, "stderr carries the endpoint's credential")
        #expect(readsTheRefusal)
    }

    /// The source guard over `message(for:)`'s body, read with comments
    /// blanked and strings KEPT (an interpolation is inside a literal):
    /// no description, no interpolated error outside the two allowlisted
    /// arms, no localized sentence and no backend `reason` that skips
    /// `URLText.withoutUserinfo`.
    ///
    /// `PasswordCommandError` and `KeychainError` keep `\(error)`: neither
    /// carries command output or a secret — the password command's stdout
    /// never enters an error, and `KeychainError` is a status code. They are
    /// allowed by type, and each allowed arm must still exist and still
    /// interpolate, or the allowance is stale.
    @Test func noCLIMessagePathRendersARawError() throws {
        let body = try #require(
            try TransferErrorSecrecyTests.body(opening: Self.declaration, in: Self.file),
            "`\(Self.declaration)` is gone — renamed?")
        #expect(body.contains(TransferErrorSecrecyTests.filter), "the mapping no longer filters")
        let lines = body.split(separator: "\n").map(String.init)
        var allowed: Set<String> = []
        for type in Self.allowlisted {
            let arm = "case is \(type):"
            guard let index = lines.firstIndex(where: { $0.contains(arm) }) else {
                Issue.record("the allowlisted arm `\(arm)` is gone — drop it from the allowlist")
                continue
            }
            let next = lines[(index + 1)...].first { !$0.allSatisfy(\.isWhitespace) }
            guard let next, next.contains("\\(error") else {
                Issue.record("the allowlisted arm `\(arm)` no longer interpolates the error — drop it")
                continue
            }
            allowed.insert(next)
        }
        var found = TransferErrorSecrecyTests.violations(in: body).filter { !allowed.contains($0) }
        found += lines.filter { $0.contains("\\(reason") }
        #expect(found.isEmpty, "\(found)")
    }

    static let declaration = "public static func message(for error: Error) -> String"
    static let allowlisted = [
        String(describing: PasswordCommandError.self), String(describing: KeychainError.self),
    ]
    static let file = SourceCorpus.url(of: .sources)
        .appendingPathComponent("macSCPCore/CLI/CLIErrorMapping.swift")
}
