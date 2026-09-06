import ArgumentParser
import Darwin
import Foundation
import Synchronization
import macSCPCore

/// Holds one saved forwarding open in THIS process, the way `ssh -L` does:
/// the command dials, binds, prints a line per state change and stays until
/// Ctrl-C. There is no daemon and no way to talk to a running app — a tunnel
/// started from a terminal belongs to that terminal and ends with it
/// (`docs/superpowers/specs/2026-09-06-cli-store-and-tunnels-design.md`,
/// point 4).
///
/// The one verb of the `tunnels` group that DIALS, which is why it declares
/// `GlobalOptions` where the four store verbs declare nothing, and why it
/// sits in its own file. Everything it decides about the connection is
/// decided by the same functions `ls` uses: the secret chain is
/// `secretChain(for:options:)` and the host-key question goes to
/// `makeDecider(policy:)`, so `--accept-new`/`--non-interactive` mean here
/// exactly what they mean there. `CLITunnelStartDeciderGuardTests` walks
/// that second claim out of `LsCommand.swift` rather than trusting this
/// sentence.
///
/// What it prints and what it exits with are not decided here either:
/// `TunnelStateLine` and `TunnelExit` (Core) own both, table-tested in
/// `CLITunnelStartTests`. This file is the wiring — resolve, compose, watch
/// two signals, leave.
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
            SIGTERM) stops the forwarding and exits 0. A tunnel that cannot \
            be held open exits 13 with the reason on stderr; an unknown host \
            key exits 11 (rerun with --accept-new), a key MISMATCH exits 12 \
            and no flag makes it pass, and a session with no secret this \
            tool can reach exits 10.
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
        // waits, possibly for hours. `diagnose` and this command are the two
        // of the eight subcommands that print as they go (counted
        // 2026-09-06); the other six compute their whole answer and print it
        // in one pass.
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

    // MARK: - The run

    /// What the dial failed with, kept as the two Sendable facts the exit
    /// needs rather than as the error itself.
    ///
    /// The ERROR is only ever in hand inside the connect closure — by the
    /// time the runner publishes `failed` or `needsConfirmation` it has
    /// become mapped text — and it is the error that tells 10 from 11 and 12
    /// from 13. So it is mapped where it is caught, through the same
    /// `CLIErrorMapping` every other subcommand exits by, and only the
    /// answer travels.
    private struct DialFailure: Sendable {
        let code: CLIExitCode
        let message: String

        init(_ error: any Error) {
            code = CLIErrorMapping.exitCode(for: error)
            message = CLIErrorMapping.message(for: error)
        }
    }

    /// Dials, holds the forwarding open, and returns the code to leave with.
    ///
    /// The loop is the whole command: `TunnelRunner.states` publishes only
    /// states that CHANGED, so one line per element is one line per change,
    /// and `TunnelExit.code(for:dialFailure:)` answering non-`nil` is what
    /// ends the run. A signal reaches this loop the same way everything else
    /// does — through a state: the watcher awaits `runner.stop()`, which
    /// publishes `.stopped`, which the loop prints and leaves on with 0.
    ///
    /// `stops` is a parameter rather than a call to `interrupts()` inside,
    /// so the ending can be driven without raising a real signal at a real
    /// process.
    static func hold(
        profile: TunnelProfile, session: StoredSession, options: GlobalOptions,
        stops: AsyncStream<Int32>
    ) async -> CLIExitCode {
        let asJSON = options.json
        let verbose = options.verbose
        // Read out of `options` before the closures below capture anything:
        // they are `@Sendable`, and a `Bool` copied into one is Sendable
        // where the command value is not (`DiagnoseCommand.run()`'s own
        // note).
        let secrets = secretChain(for: session, options: options)
        let knownHosts = KnownHostsStore(directory: SessionStore.defaultDirectory)
        let failure = Mutex<DialFailure?>(nil)
        let runner = TunnelRunner(
            profile: profile,
            connect: { decider in
                do {
                    // The same composition `TunnelManager.liveRunner` makes
                    // for a window, with this tool's own chain and decider
                    // in place of the app's: the app resolves through the
                    // keychain and may prompt in a sheet, and this one walks
                    // the command line's sources and asks on the terminal.
                    return try await TunnelConnection.connect(
                        session: session,
                        secrets: secrets,
                        knownHosts: knownHosts,
                        decider: decider,
                        connectTimeoutSeconds: SettingsStore.defaultConnectTimeoutSeconds)
                } catch {
                    failure.withLock { $0 = DialFailure(error) }
                    throw error
                }
            },
            runtimes: LiveTunnelRuntimeFactory(),
            sleeper: { delay in
                // The real `Task.sleep`, cancellable as the `Sleeper`
                // contract requires — `stop()` cancels the run task, and a
                // backoff that ignored that would hold Ctrl-C for up to a
                // minute.
                if verbose {
                    OutputFormatter.note("backoff seconds=\(delay.components.seconds)")
                }
                try await Task.sleep(for: delay)
            })

        let watcher = Task {
            for await _ in stops { break }
            await runner.stop()
        }
        await runner.start(decider: makeDecider(policy: options.hostKeyPolicy))

        var code = CLIExitCode.success
        for await state in runner.states {
            Swift.print(
                TunnelStateLine.render(state, port: await runner.boundPort, json: asJSON))
            let dialFailure = failure.withLock { $0 }
            guard let terminal = TunnelExit.code(for: state, dialFailure: dialFailure?.code)
            else { continue }
            if let note = TunnelExit.note(for: state, dialMessage: dialFailure?.message) {
                OutputFormatter.note(note)
            }
            code = terminal
            break
        }

        watcher.cancel()
        // Awaited on every path out, including the ones that already ended
        // the run: `stop()` is idempotent (a runner with no task releases
        // nothing and publishes nothing), and it is what guarantees the SSH
        // connection and the forward are actually gone before the process
        // leaves. The UI owns lifecycles explicitly here too — no `deinit`
        // does this.
        await runner.stop()
        return code
    }

    // MARK: - The two signals

    /// SIGINT and SIGTERM, as an `AsyncStream` the run loop can await.
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
    /// The sources are held by the stream's own termination handler, which
    /// is the only reference to them: without it they would be released at
    /// the end of this function and never fire.
    static func interrupts(_ numbers: [Int32] = [SIGINT, SIGTERM]) -> AsyncStream<Int32> {
        AsyncStream { continuation in
            var sources: [any DispatchSourceSignal] = []
            for number in numbers {
                signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(
                    signal: number,
                    queue: DispatchQueue(label: "dev.noidee.macscp-cli.signal.\(number)"))
                source.setEventHandler { continuation.yield(number) }
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
