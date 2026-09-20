import ArgumentParser
import Darwin
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
/// resolve, TCP, ICMP, trace — is what gets measured. A stored session with a
/// jump host is walked through it (`ConnectionDiagnostics`): the `jump.` rows,
/// then the `target.` rows as the jump reaches the server.
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
            are what you get. A session saved with a jump host is measured \
            through it: the jump host's rows (jump.*) come first, then the \
            server as the jump host reaches it (target.*). Rows print as \
            each step finishes. The exit \
            code is 0 while every step came back ok, skipped or unavailable, \
            and 16 as soon as one failed or timed out, so a script can \
            branch on the path being broken without reading a row. \
            --scope throughput is the one check that writes: it uploads a \
            test file of --payload-mib MiB to the session's start folder, \
            downloads it, compares it and deletes it, and it runs only when \
            asked for by name, never as part of complete. Ctrl-C during it \
            stops the run and still deletes the file; the exit code then \
            follows the rows kept, 0 when they are ok. A second Ctrl-C \
            leaves without waiting for the delete, names the file on \
            stderr, and exits 16, because the file may still be there. \
            --scope internet is the one check that measures no server at \
            all: it downloads \(mebibytes(DiagnosticInternetSpeedSettings.defaultDownloadBytes)) \
            from and uploads \(mebibytes(DiagnosticInternetSpeedSettings.defaultUploadBytes)) to \
            the service named by --speed-service and reports the two rates. Name no \
            session and no --host with it — it has no target — and it \
            sends nothing about any session, login or host to that service. \
            --speed-service off contacts nobody; the app's own setting is \
            not read here, so a test switched off in the app is switched \
            off here only when this flag says so.
            """)

    /// A byte count as whole mebibytes, for the help above — read off Core's
    /// own constants so the sentence cannot claim a payload the step does
    /// not move.
    private static func mebibytes(_ bytes: Int) -> String { "\(bytes / (1024 * 1024)) MiB" }

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

    /// The throughput test's payload. Optional rather than defaulted, so
    /// `validate()` can tell "not given" from "given with another scope" —
    /// the default is the app's own (`DiagnosticThroughputSettings
    /// .defaultPayloadMiB`), applied in `run()`.
    @Option(
        name: .long,
        help: "Size of the --scope throughput test file in MiB, 1 to 256. Defaults to 8.")
    var payloadMib: Int?

    /// Which service `--scope internet` measures against. Optional for
    /// `--payload-mib`'s reason — so `validate()` can tell "not given" from
    /// "given with another scope" — and the default is the app's own
    /// (`DiagnosticInternetSpeedSettings.defaultService`), applied in
    /// `run()`.
    ///
    /// A NAME, never a URL: the set is closed (`InternetSpeedService`), for
    /// the reason that type's doc comment gives.
    @Option(
        name: .long,
        help: """
            Which service --scope internet measures against. Defaults to cloudflare.
            """)
    var speedService: InternetSpeedService?

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
        // `--scope internet` has no target and refuses one. It measures the
        // link between this Mac and a third-party service
        // (`InternetSpeedProbe`); a session name or a `--host` beside it
        // would name something nothing in the run reads, and an argument
        // that is silently ignored is the shape this command already
        // refuses for `--port` and `--kind`.
        guard scope.measuresTheSession else {
            guard session == nil, host == nil else {
                throw ValidationError(
                    "--scope internet measures this Mac's internet connection and no server; "
                        + "name no session and no --host with it.")
            }
            guard port == nil, kind == nil else {
                throw ValidationError("--port and --kind describe --host.")
            }
            try validateSpeedOptions()
            return
        }
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
        if let payloadMib {
            guard scope == .throughput else {
                throw ValidationError("--payload-mib describes --scope throughput.")
            }
            let range = DiagnosticThroughputSettings.payloadMiBRange
            guard range.contains(payloadMib) else {
                throw ValidationError(
                    "--payload-mib must be between \(range.lowerBound) and \(range.upperBound).")
            }
        }
        try validateSpeedOptions()
    }

    /// The one option that describes `--scope internet`, refused beside any
    /// other scope — `--payload-mib`'s rule, for the other speed test.
    ///
    /// Called from BOTH arms of `validate()` above, because the internet
    /// arm returns before reaching the end of it.
    private func validateSpeedOptions() throws {
        if speedService != nil, scope.measuresTheSession {
            throw ValidationError("--speed-service describes --scope internet.")
        }
    }

    func run() async throws {
        // `Swift.print` writes to C `stdout`, and `stdout` is
        // block-buffered whenever its destination is not a terminal —
        // which is exactly what `diagnose --json | jq` gives it. Nothing
        // reaches the other end of that pipe until the buffer fills (a few
        // KB) or the process exits, which turns "rows print as each step
        // finishes" (this command's whole reason for streaming through
        // `onStep` instead of returning a report) into "every row prints
        // at once, at the end" for any caller that redirects or pipes.
        //
        // Set HERE, at the top of `run()`, rather than process-wide in
        // `MacSCPCLI.main()`: buffering only matters to a command that
        // prints as it goes, and TWO do — this one and `tunnels start`,
        // which prints a line per state change and then waits (recounted
        // 2026-09-06, when that verb arrived; each sets the mode at the top
        // of its own `run()`). The other six —
        // `ls`/`get`/`put`/`rm`/`mkdir`/`sessions` — compute their whole
        // answer and print it in one pass, so a row arriving early or late
        // is not something their callers can observe either way.
        // Line-buffering every subcommand from one shared spot
        // would change all eight together for a property only two of them
        // have, and it must run before this command's first `print` — which
        // "the top of `run()`" already guarantees without threading a flag
        // through `MacSCPCLI`'s shared entry point for the six commands that
        // do not need it.
        setvbuf(stdout, nil, _IOLBF, 0)
        let target = try resolveTarget()
        // Read out of `self` before the observer closure below captures
        // anything: the closure is `@Sendable`, and a `Bool` copied into it
        // is one, where the command value is not.
        let asJSON = options.json
        // Built here rather than inline, because its file name is what the
        // command prints if a second Ctrl-C leaves before the run could.
        let throughput = DiagnosticThroughputSettings(
            payloadMiB: payloadMib ?? DiagnosticThroughputSettings.defaultPayloadMiB)
        // The service is a FLAG here and not the app's setting, for the
        // reason the bandwidth comment below gives: this binary reads no
        // settings file. So a user who switched the test off in the app has
        // to say `--speed-service off` on the command line too — stated in
        // the docs, because a privacy choice that does not carry across is
        // the kind of thing a user assumes did.
        let internetSpeed = DiagnosticInternetSpeedSettings(
            service: speedService ?? DiagnosticInternetSpeedSettings.defaultService)
        // No bandwidth bucket: this binary paces no transfer — `put` and
        // `get` run unthrottled, and the app's limits live in a settings
        // file the command line does not read (`SettingsStore
        // .defaultConnectTimeoutSeconds` states that rule). The row's limit
        // column therefore says none, which is what applied.
        let diagnostics = ConnectionDiagnostics(
            descriptor: target.descriptor,
            values: target.values,
            secrets: target.secrets,
            sessionID: target.sessionID,
            jump: target.jump,
            throughput: throughput,
            internetSpeed: internetSpeed)
        // No `appVersion`: this binary reports none. It has no bundle to
        // read `CFBundleShortVersionString` from (the App's `SettingsView`
        // does that, and Core deliberately does not), and no `version:` in
        // `MacSCPCLI.configuration` — `macscp-cli --version` is an unknown
        // option, measured 2026-09-04. So the initializer's own "unknown"
        // stands, and nothing this command prints carries it anyway: the
        // version reaches paper only through `DiagnosticReport.plainText()`,
        // which the CLI does not print.
        let scope = self.scope
        let walk: @Sendable () async -> DiagnosticReport = {
            await diagnostics.run(scope: scope) { step in
                OutputFormatter.print(step: step, asJSON: asJSON)
            }
        }
        // `--scope throughput` writes a file to the user's server, so a
        // signal must cancel it — and let its removal run — rather than kill
        // the process mid-transfer (`DiagnoseForegroundRun`). The handler is
        // `tunnels start`'s own, not a second one. Every other scope only
        // reads, and keeps the default disposition: Ctrl-C ends it at once,
        // as it always has.
        let ending: DiagnoseForegroundRun.Ending =
            scope == .throughput
            ? await DiagnoseForegroundRun.drive(stops: TunnelStartCommand.interrupts(), walk)
            : .finished(await walk())
        guard case .finished(let report) = ending else {
            if let note = DiagnoseForegroundRun.leftoverNote(
                for: ending, fileName: throughput.fileName)
            {
                OutputFormatter.note(note)
            }
            Foundation.exit(DiagnoseForegroundRun.exitCode(for: ending).rawValue)
        }

        if asJSON {
            OutputFormatter.print(json: DiagnoseRendering.jsonSummary(for: report))
        } else if let completion = DiagnoseRendering.completionRow(for: report) {
            Swift.print(completion)
        }
        // AFTER the run, not before it: the chain records which of its
        // sources answered at the moment one does, and before the dial has
        // asked, `label` is honestly "none".
        //
        // And only for a scope that ASKED. `--scope ping` and `--scope
        // trace` resolve no secret through this chain (a session behind a
        // jump host looks the JUMP's up under `ping`, through its own
        // lookup, never this chain), so the chain is still on "none"
        // when they finish — a line that reads as "this session has no
        // credential" when it means "nothing looked". `resolvesASecret` is
        // Core's own answer (`DiagnosticScope`), not a list of scopes
        // written here.
        if options.verbose, scope.resolvesASecret, let secrets = target.secrets {
            OutputFormatter.note("secret source: \(secrets.label)")
        }
        // On standard error as well as in the row: a script that parses
        // stdout still gets told a file of this app's may be on the server.
        if let note = DiagnoseForegroundRun.leftoverNote(for: ending, fileName: throughput.fileName) {
            OutputFormatter.note(note)
        }
        // `Foundation.exit`, the way `MacSCPCLI.main()` leaves on a mapped
        // error: a diagnosis that found something wrong is not an error —
        // nothing was thrown, the rows are already printed, and the walk did
        // exactly what it was asked. Throwing ArgumentParser's `ExitCode` to
        // carry the number instead would go through that same catch, where
        // `CLIErrorMapping` has no case for it and would print a message and
        // exit 13.
        Foundation.exit(DiagnoseForegroundRun.exitCode(for: ending).rawValue)
    }

    /// What the diagnosis is pointed at: which backend answers, which field
    /// values the probes read, and — for a stored session only — the secret
    /// chain and the Keychain slot it answers for.
    private func resolveTarget() throws -> Target {
        // `--scope internet` has no target, and `validate()` has already
        // refused one. Nothing of this value is read by that walk — it
        // measures this Mac's link to a service and never looks at the
        // descriptor, the values or the secrets — so the placeholder is a
        // shape the initializer needs, not a session anything dials.
        guard scope.measuresTheSession else {
            let descriptor = BackendDescriptor.descriptor(for: .ssh)
            return Target(
                descriptor: descriptor, values: FieldValues(), secrets: nil, sessionID: nil,
                jump: nil)
        }
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
                sessionID: nil,
                jump: nil)
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
            sessionID: stored.secretSlot,
            jump: try jump(of: stored))
    }

    /// A stored session's jump host, resolved as the app's connect resolves
    /// it (`DiagnosticJump.stored`) — or `nil` for a session without one,
    /// which reads neither the login sets nor the other sessions.
    ///
    /// The jump's secret is the Keychain slot the app writes for it, read
    /// the same read-only way the target's is, with the managed key's slot
    /// in FRONT of it for a private-key hop (the maintainer answer of
    /// 2026-09-19, `LoginResolver.preferringManagedKeyPassphrase`): the
    /// key's own item answers first, and the hop's slot only when it has
    /// nothing. `--password-command` and `MACSCP_PASSWORD` answer the
    /// TARGET's secret only: each names one secret, and a command that
    /// printed the target's password would otherwise be sent to the bastion
    /// too. A store that cannot be read is thrown, the way `resolveSession`
    /// throws for the session store.
    private func jump(of stored: StoredSession) throws -> DiagnosticJump? {
        guard stored.jump != nil else { return nil }
        let directory = SessionStore.defaultDirectory
        return DiagnosticJump.stored(
            for: stored,
            sets: try LoginSetStore(directory: directory).all(),
            sessions: try SessionStore(directory: directory).all(),
            secrets: KeychainSecretStore(),
            keys: ManagedKeyStore(directory: directory))
    }

    /// The session argument as a reference.
    ///
    /// Through `SessionReference.parse`, the same splitter every other
    /// subcommand reads its `name:/path` with, and then the path is
    /// discarded: a diagnosis addresses a machine and never a path. Parsing
    /// is what makes `diagnose prod:/tmp` report the way `ls prod:/tmp`
    /// would — `no stored session named 'prod'` — where taking the argument
    /// whole named a PATH as the session that could not be found.
    ///
    /// The `.local` arm is the bare name, which is the form this command
    /// documents: `parse` reads a text with no colon (or with a
    /// one-character prefix, which it treats as a drive letter) as a local
    /// path, and here that text IS the session name. Its trailing colon is
    /// dropped for the same reason `.remote`'s empty path is ignored —
    /// `SessionNameCompletion` completes names WITH it, so `diagnose <tab>`
    /// types `prod:` and refusing that would make the completion this
    /// command wires up produce an argument it rejects.
    private var sessionReference: SessionReference {
        switch SessionReference.parse(session ?? "") {
        case .remote(let name, _):
            return .remote(name: name, path: "/")
        case .local(let text):
            return .remote(
                name: text.hasSuffix(":") ? String(text.dropLast()) : text, path: "/")
        }
    }

    private struct Target {
        let descriptor: BackendDescriptor
        let values: FieldValues
        /// Typed as the concrete chain rather than `any SecretSource` so
        /// `--verbose` can read `label` off it once the run is over.
        let secrets: ChainedSecretSource?
        let sessionID: UUID?
        /// The jump host a stored session dials through; never set for
        /// `--host`, which names one machine and no way to it.
        let jump: DiagnosticJump?
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
