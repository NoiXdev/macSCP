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
}
