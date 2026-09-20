import Foundation
import macSCPCore
import Testing

/// `diagnose`'s argument shape, driven through the BUILT binary — the same
/// way `CLISessionsEditingTests` drives the `sessions` verbs' refusals, and
/// ungated for the same reason: every case here is answered by
/// `DiagnoseCommand.validate()`, which runs before anything opens a socket,
/// reads a store or looks at a keychain.
///
/// `MacSCPCLI` is an executable target and no test target imports it (the
/// recorded open item "no test for `validate()`"), so the argument rules
/// cannot be called in process. The binary can be, and that is the surface
/// the rules exist on anyway: what the person typing the command is told.
///
/// Every refusal is asserted as exit code **64** — ArgumentParser's own
/// `exit(withError:)` for a `ValidationError`, the same number the
/// `sessions` suite pins for the same reason. A refusal arriving as
/// anything else would mean the check moved out of `validate()` and into
/// `run()`, where `CLIErrorMapping` classifies it as a connection failure
/// and tells a script the network was at fault when the arguments were.
@Suite("CLI diagnose argument shape")
struct CLIDiagnoseArgumentTests {
    /// ArgumentParser's `ExitCode.validationFailure`. Written here rather
    /// than imported for the reason `CLISessionsEditingTests` gives: it is
    /// ArgumentParser's number, not this project's, and `CLIExitCode`
    /// deliberately does not carry it.
    private static let validationFailure: Int32 = 64

    /// `--payload-mib` describes `--scope throughput` and nothing else.
    ///
    /// The internet arm of `validate()` returns before the payload guard
    /// the rest of the command reaches, so this pair was ACCEPTED and the
    /// value read by nobody (final review, I-3). That is the shape the same
    /// function refuses for `--port` and `--kind` three lines above its own
    /// early return, and the shape the released reference page states
    /// ("`--payload-mib` … is accepted only with `--scope throughput`").
    ///
    /// The second run is the POSITIVE beside the refusal: without
    /// `--payload-mib` the very same command line is accepted and walks.
    /// Without it, a build that had stopped understanding `--scope
    /// internet` at all — an unknown flag, a renamed service name — would
    /// also exit 64 and read as this rule holding.
    ///
    /// `--speed-service off` throughout: this suite contacts no third
    /// party, and the accepted run proves it by measuring nothing.
    @Test func theInternetScopeRefusesAPayloadSize() async throws {
        let binary = URL(fileURLWithPath: try CLIMatrix.binaryPath())
        let refused = try await SubprocessRunner.run(
            binary,
            arguments: [
                "diagnose", "--scope", "internet", "--speed-service", "off", "--payload-mib", "5",
            ])
        #expect(refused.status == Self.validationFailure, """
            --payload-mib with --scope internet exited \(refused.status), not a validation \
            failure: \(refused.stderrText)
            """)
        #expect(refused.stderrText.contains("--payload-mib describes --scope throughput."), """
            the refusal must say which scope the option describes: \(refused.stderrText)
            """)

        let accepted = try await SubprocessRunner.run(
            binary,
            arguments: ["diagnose", "--scope", "internet", "--speed-service", "off"])
        #expect(accepted.status == 0, """
            the same command without --payload-mib must still run: \(accepted.stderrText)
            """)
    }
}
