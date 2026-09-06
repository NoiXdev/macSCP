import ArgumentParser
import Darwin
import Foundation
import macSCPCore

/// Holds one saved forwarding open in THIS process, the way `ssh -L` does:
/// the command dials, binds, prints a line per state change and stays until
/// Ctrl-C. There is no daemon and no way to talk to a running app — a tunnel
/// started from a terminal belongs to that terminal and ends with it
/// (`docs/superpowers/specs/2026-09-06-cli-store-and-tunnels-design.md`,
/// point 4).
///
/// The one verb of the `tunnels` group that DIALS, which is why it declares
/// `GlobalOptions` where the four store verbs declare none, and why it sits
/// in its own file. Everything it decides about the connection is decided by
/// the same functions `ls` uses: the secret chain is
/// `secretChain(for:options:)` — `--password-command`, then the environment
/// variable, then the keychain entry the app stored, read and never written
/// — and the host-key question goes to the shared decider builder, so
/// `--accept-new`/`--non-interactive` mean here exactly what they mean
/// there. `CLITunnelStartDeciderGuardTests` walks that second claim out of
/// `LsCommand.swift` rather than trusting this sentence.
///
/// What it prints, what it exits with and the loop that holds it open are
/// not decided here either: `TunnelStateLine`, `TunnelExit` and
/// `TunnelForegroundRun` (Core) own all three, measured in
/// `CLITunnelStartTests` and `CLITunnelForegroundRunTests`. This file is the
/// composition — resolve, compose, hand over two signals, leave.
struct TunnelStartCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "Hold a saved forwarding open until Ctrl-C.",
        discussion: """
            The forwarding runs in this process: nothing is handed to the \
            app, and closing this terminal closes the tunnel. One line is \
            printed per state change — connecting, active (with the bound \
            port where the forward has one, and the live connection count as \
            it changes), reconnecting attempt=N when the profile reconnects, \
            stopped — or one JSON object per line with --json. Ctrl-C (or \
            SIGTERM) stops the forwarding and exits 0; a second one leaves \
            at once, without waiting for a teardown that is taking its time. \
            A tunnel that cannot be held open exits 13 with the reason on \
            stderr; an unknown host key exits 11 (rerun with --accept-new), \
            a key MISMATCH exits 12 and no flag makes it pass, and a session \
            whose secret this tool cannot resolve exits 10.
            """)

    @OptionGroup var options: GlobalOptions
    @OptionGroup var target: TunnelTargetOptions

    @Argument(help: "The forwarding to run, matched without case.")
    var name: String

    /// Declared only so a second name is refused in this tool's own words.
    ///
    /// ArgumentParser would refuse it anyway — "Unexpected argument" and its
    /// own exit 64 — which says the shape was wrong without saying what to
    /// do instead. A person asking for two forwardings at once has a real
    /// intention and a real answer (two terminals), and the refusal is worth
    /// wording rather than inheriting.
    @Argument(help: "Refused: one forwarding per invocation, so run two terminals.")
    var alsoNamed: [String] = []

    /// Everything that can be answered before anything is dialled: one name,
    /// a session that exists and can carry a forwarding at all, and a
    /// forwarding of that name on it.
    ///
    /// A `ValidationError` here leaves with ArgumentParser's own 64, for the
    /// reason `TunnelsAddCommand` states: thrown from `run()` the same
    /// complaint would reach `CLIErrorMapping` and be reported as a
    /// connection failure, telling a script the server was unreachable when
    /// its arguments were wrong.
    func validate() throws {
        guard alsoNamed.isEmpty else {
            throw ValidationError("one forwarding per invocation; run two terminals")
        }
        let session = try target.requireSession()
        try target.requireItCanCarryAForwarding(session)
        _ = try StoreEditing.requireProfile(named: name, on: session)
    }

    func run() async throws {
        // Line-buffered for the reason `DiagnoseCommand.run()` spells out at
        // length: `Swift.print` writes to C `stdout`, which is
        // block-buffered whenever its destination is not a terminal, so
        // `tunnels start --json | jq` would see nothing until the buffer
        // filled — and a forwarding that is up prints one line and then
        // waits, possibly for hours. Two places in this tool print as they
        // go and both set the mode at the top of their own `run()`:
        // `diagnose`, a subcommand, and this verb (counted 2026-09-06).
        setvbuf(stdout, nil, _IOLBF, 0)
        // Re-resolved rather than carried over from `validate()`: a
        // `ParsableCommand` is handed to `validate()` as a copy and has
        // nowhere to put a result (`TunnelsAddCommand.run()`'s own reason).
        let session = try target.requireSession()
        let profile = try StoreEditing.requireProfile(named: name, on: session)
        let code = await Self.hold(
            profile: profile, session: session, options: options,
            stops: Self.interrupts())
        // `Foundation.exit`, the way `diagnose` leaves: nothing was thrown —
        // the tunnel ran and ended — and throwing ArgumentParser's `ExitCode`
        // to carry the number would go through `MacSCPCLI.main()`'s catch,
        // where `CLIErrorMapping` has no case for it and would print a
        // message and exit 13.
        Foundation.exit(code.rawValue)
    }

    // MARK: - The composition

    /// Builds the runner this tool dials with and hands it to the foreground
    /// loop.
    ///
    /// The same composition `TunnelManager.liveRunner` makes for a window,
    /// with this tool's own pieces in place of the app's. FOUR differences,
    /// counted 2026-09-07 by reading `TunnelManager.liveRunner` against the
    /// `TunnelRunner(` call below, argument by argument:
    ///
    /// 1. **The secret chain.** The app's is keychain-only
    ///    (`TunnelSecretSources.chain`: the session's item, plus a managed
    ///    key's passphrase for a key session) and may prompt in a sheet;
    ///    this one walks the command line's chain
    ///    (`--password-command`, the environment variable, then that same
    ///    keychain item, read-only).
    /// 2. **The host-key decider.** The app's may prompt in a sheet; this
    ///    one asks on the terminal, and refuses under `--non-interactive`.
    /// 3. **The connect timeout.** This one names
    ///    `SettingsStore.defaultConnectTimeoutSeconds`, a constant, so every
    ///    dial of a run uses the same bound; the app calls a
    ///    `connectTimeout` closure that reads
    ///    `SettingsStore.connectTimeoutSeconds` per dial, so a setting
    ///    changed between two dials reaches the second one.
    /// 4. **The session.** This one resolves it once in `run()` and captures
    ///    the value; the app re-reads its store per dial, so a session
    ///    edited between two dials reaches the second one.
    ///
    /// The runtime factory and the backoff sleeper are `TunnelRunner`'s own
    /// defaults — the live factory and `Task.sleep` — which is what the app
    /// takes too.
    ///
    /// Differences 3 and 4 are the same shape and the same consequence: a
    /// CLI run is a process with a fixed lifetime, and it dials the
    /// forwarding it was started for with the settings it was started
    /// under. Re-reading either mid-run would make a long-lived `start`
    /// silently change what it is doing.
    ///
    /// `stops` is a parameter rather than a call to `interrupts()` inside,
    /// so a run can be ended without raising a real signal at a real
    /// process.
    static func hold(
        profile: TunnelProfile, session: StoredSession, options: GlobalOptions,
        stops: AsyncStream<Void>
    ) async -> CLIExitCode {
        // Read out of `options` before the dial closure captures anything:
        // it is `@Sendable`, and these values are, where the command value
        // is not (`DiagnoseCommand.run()`'s own note).
        let secrets = secretChain(for: session, options: options)
        let knownHosts = KnownHostsStore(directory: SessionStore.defaultDirectory)
        let dialFailure = TunnelDialFailureRecord()
        let runner = TunnelRunner(
            profile: profile,
            connect: { hostKey in
                // Through the record, which is what makes a failed dial's
                // own error decide the exit code — and what clears it again
                // when a later dial works.
                try await dialFailure.dialing {
                    try await TunnelConnection.connect(
                        session: session,
                        secrets: secrets,
                        knownHosts: knownHosts,
                        decider: hostKey,
                        connectTimeoutSeconds: SettingsStore.defaultConnectTimeoutSeconds)
                }
            })
        return await TunnelForegroundRun.drive(
            runner: runner,
            stops: stops,
            decider: makeDecider(policy: options.hostKeyPolicy),
            json: options.json,
            verbose: options.verbose,
            dialFailure: dialFailure,
            output: TunnelForegroundOutput(
                line: { Swift.print($0) },
                note: { OutputFormatter.note($0) }))
    }

    // MARK: - The two signals

    /// SIGINT and SIGTERM, as an `AsyncStream` the foreground loop can
    /// await. Every element is one signal, so a second Ctrl-C is a second
    /// element — which is the whole reason the stream is not a one-shot.
    ///
    /// `signal(n, SIG_IGN)` FIRST, then a `DispatchSourceSignal`: the
    /// default disposition for both is to kill the process outright, which
    /// would leave the forward bound and the connection open in the server's
    /// eyes until it noticed. Ignoring the default disposition does not stop
    /// the source from seeing the signal — that is the documented pairing —
    /// and the source's handler runs on a queue of its own, so nothing about
    /// this blocks a cooperative-pool thread or runs inside the signal
    /// handler's own restricted context.
    ///
    /// **A `--password-command` child inherits the ignore**, and that is
    /// accepted rather than worked around. `SIG_IGN` is set here, at the top
    /// of the run, and the secret is resolved synchronously inside the dial
    /// afterwards — so a credential helper that hangs cannot be Ctrl-C'd,
    /// and neither can the dial that is waiting for it. What makes it
    /// acceptable is the second signal: it is read while the first stop is
    /// still going, whatever the dial is blocked on, and the run leaves at
    /// once. Restoring `SIG_DFL` around the spawn would need Core's
    /// `PasswordCommandSecretSource` to do it (it owns the `Process`), and
    /// it would trade this for a window in which the first Ctrl-C kills the
    /// process outright.
    ///
    /// The sources are held by the stream's own termination handler, which
    /// is the only reference to them: without it they would be released at
    /// the end of this function and never fire.
    static func interrupts(_ numbers: [Int32] = [SIGINT, SIGTERM]) -> AsyncStream<Void> {
        AsyncStream { continuation in
            var sources: [any DispatchSourceSignal] = []
            for number in numbers {
                signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(
                    signal: number,
                    queue: DispatchQueue(label: "dev.noidee.macscp-cli.signal.\(number)"))
                source.setEventHandler { continuation.yield(()) }
                source.resume()
                sources.append(source)
            }
            let held = sources
            continuation.onTermination = { _ in
                for source in held { source.cancel() }
            }
        }
    }
}
