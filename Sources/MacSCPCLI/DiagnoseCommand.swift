import ArgumentParser
import Foundation
import macSCPCore

/// Runs the connection diagnostics from a terminal — the same walk the app's
/// diagnostics panel runs, rendered as rows instead of a list
/// (`docs/superpowers/specs/2026-09-04-cli-diagnose-design.md`).
///
/// Two forms, and the difference between them is what a secret can be
/// resolved for. A stored session names a Keychain slot, so its dial and its
/// contributions authenticate exactly as a connect would; a bare `--host`
/// names none, so those two steps report `skipped` and the universal half —
/// resolve, TCP, ICMP, trace — is what gets measured.
///
/// This command decides nothing about what a row SAYS: every word printed
/// comes from `DiagnoseRendering`, which carries Core's own text through
/// (see that type's doc comment). What lives here is the argument shape, the
/// two refusals, and the exit.
struct DiagnoseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diagnose",
        abstract: "Measure the path to a server, step by step.",
        discussion: """
            Name a stored session — the name in the first column of \
            sessions, with or without the trailing colon the other commands \
            need for their path — to diagnose exactly what the app would \
            dial. Pass --host instead to point at a machine no session was \
            saved for: nothing resolves a secret for it, so the dial and the \
            server's own claims come back skipped and the universal steps \
            are what you get. Rows print as each step finishes. The exit \
            code is 0 while every step came back ok, skipped or unavailable, \
            and 16 as soon as one failed or timed out, so a script can \
            branch on the path being broken without reading a row.
            """)

    @OptionGroup var options: DiagnoseOptions

    @Argument(
        help: "Stored session to diagnose, e.g. prod. Omit when passing --host.",
        completion: SessionNameCompletion.kind)
    var session: String?

    @Option(name: .long, help: "Diagnose this host instead of a stored session.")
    var host: String?

    @Option(name: .long, help: "Port on --host. Defaults to the backend's own (SSH 22, HTTPS 443).")
    var port: Int?

    @Option(name: .long, help: "Which protocol --host speaks. Defaults to ssh.")
    var kind: ConnectionKind?

    @Option(name: .long, help: "Which steps to run.")
    var scope: DiagnosticScope = .complete

    /// The ARGUMENT SHAPE only: exactly one target, and the two options that
    /// describe the `--host` form are not accepted without it.
    ///
    /// A `ValidationError` here exits with ArgumentParser's own 64, the same
    /// as a missing argument on any other subcommand, because that is what
    /// this is. The one refusal the design fixes at exit 2 —
    /// `--host --scope dial`/`contributions` — is NOT here: it is thrown
    /// from `run()` as a `DiagnoseUsageError`, which is the only way it
    /// reaches `CLIErrorMapping` (see that type's doc comment).
    func validate() throws {
        switch (session, host) {
        case (nil, nil):
            throw ValidationError("Name a stored session, or pass --host.")
        case (.some, .some):
            throw ValidationError("Name a stored session or pass --host, not both.")
        default:
            break
        }
        if host == nil, port != nil || kind != nil {
            throw ValidationError("--port and --kind describe --host.")
        }
    }

    func run() async throws {
        let target = try resolveTarget()
        // Read out of `self` before the observer closure below captures
        // anything: the closure is `@Sendable`, and a `Bool` copied into it
        // is one, where the command value is not.
        let asJSON = options.json
        let diagnostics = ConnectionDiagnostics(
            descriptor: target.descriptor,
            values: target.values,
            secrets: target.secrets,
            sessionID: target.sessionID)
        // No `appVersion`: this binary reports none. It has no bundle to
        // read `CFBundleShortVersionString` from (the App's `SettingsView`
        // does that, and Core deliberately does not), and no `version:` in
        // `MacSCPCLI.configuration` — `macscp-cli --version` is an unknown
        // option, measured 2026-09-04. So the initializer's own "unknown"
        // stands, and nothing this command prints carries it anyway: the
        // version reaches paper only through `DiagnosticReport.plainText()`,
        // which the CLI does not print.
        let report = await diagnostics.run(scope: scope) { step in
            OutputFormatter.print(step: step, asJSON: asJSON)
        }

        if asJSON {
            OutputFormatter.print(json: DiagnoseRendering.jsonSummary(for: report))
        } else if let completion = DiagnoseRendering.completionRow(for: report) {
            Swift.print(completion)
        }
        // AFTER the run, not before it: the chain records which of its
        // sources answered at the moment one does, and before the dial has
        // asked, `label` is honestly "none".
        if options.verbose, let secrets = target.secrets {
            OutputFormatter.note("secret source: \(secrets.label)")
        }
        // `Foundation.exit`, the way `MacSCPCLI.main()` leaves on a mapped
        // error: a diagnosis that found something wrong is not an error —
        // nothing was thrown, the rows are already printed, and the walk did
        // exactly what it was asked. Throwing ArgumentParser's `ExitCode` to
        // carry the number instead would go through that same catch, where
        // `CLIErrorMapping` has no case for it and would print a message and
        // exit 13.
        Foundation.exit(DiagnoseRendering.exitCode(for: report).rawValue)
    }

    /// What the diagnosis is pointed at: which backend answers, which field
    /// values the probes read, and — for a stored session only — the secret
    /// chain and the Keychain slot it answers for.
    private func resolveTarget() throws -> Target {
        if let host {
            if let refusal = DiagnoseUsageError.refusal(forEndpointScope: scope) { throw refusal }
            let descriptor = BackendDescriptor.descriptor(for: kind ?? .ssh)
            // No session id and no secret source, which is the difference
            // this form is FOR: `ConnectionDiagnostics` skips whatever needs
            // a credential rather than dialling without one.
            return Target(
                descriptor: descriptor,
                values: descriptor.endpointValues(host: host, port: port),
                secrets: nil,
                sessionID: nil)
        }

        let (stored, sources) = try resolveSession(sessionReference, options: options)
        let descriptor = BackendDescriptor.descriptor(for: stored.kind)
        // `editBaseline` then `sessionValues`, the same pair the app's own
        // entry merges (`ContentView.showDiagnostics`) and the same one
        // `ConnectionViewModel.beginEditing` uses to fill an edit form: the
        // baseline leaves every secret field blank, and the stored record
        // fills in what it holds. The secret is not merged in from anywhere
        // — the dial resolves it through `sessionID` below.
        var values = descriptor.editBaseline
        values.merge(descriptor.sessionValues(stored))
        return Target(
            descriptor: descriptor,
            values: values,
            secrets: ChainedSecretSource(sources),
            sessionID: stored.secretSlot)
    }

    /// The session argument as a reference.
    ///
    /// A NAME, not the `name:/path` the transferring subcommands parse: a
    /// diagnosis addresses a machine and never a path, so there is nothing
    /// after the colon to carry. The trailing colon is accepted and dropped
    /// anyway, because `SessionNameCompletion` completes names WITH it —
    /// `diagnose <tab>` types `prod:`, and refusing that would make the
    /// completion this command wires up produce an argument it rejects.
    private var sessionReference: SessionReference {
        let name = session ?? ""
        return .remote(name: name.hasSuffix(":") ? String(name.dropLast()) : name, path: "/")
    }

    private struct Target {
        let descriptor: BackendDescriptor
        let values: FieldValues
        /// Typed as the concrete chain rather than `any SecretSource` so
        /// `--verbose` can read `label` off it once the run is over.
        let secrets: ChainedSecretSource?
        let sessionID: UUID?
    }
}

/// `diagnose` resolves a secret (so `--password-command` and `--verbose`
/// apply) but never decides a host key: its SSH dial answers the host-key
/// question with `HostKeyDecider.refusing` inside Core
/// (`DialProbes.sshConnect`), on the argument that a probe must not write a
/// TOFU consent nobody gave. `--accept-new` and `--non-interactive` would
/// therefore be two flags this command advertises and never reads, which is
/// the finding that gave `sessions` its own `JSONOptions` (final-branch
/// review, 2026-09-02).
///
/// The help text of each option below is copied verbatim from
/// `GlobalOptions`' rather than shared, for the reason `JSONOptions` states:
/// the options agree today, not by construction.
struct DiagnoseOptions: ParsableArguments, SecretChainOptions {
    @Flag(name: .long, help: "Emit one JSON object per line instead of columns.")
    var json = false

    @Flag(name: .long, help: "Report which secret source answered, and other diagnostics.")
    var verbose = false

    @Option(name: .long, help: "Command whose stdout is the secret. Wins over all other sources.")
    var passwordCommand: String?

    init() {}
}
