import Foundation
import Synchronization

/// What `TunnelForegroundRun.drive` needs of a running tunnel: the states it
/// publishes, the port it bound, and the two commands.
///
/// A protocol so the loop can be driven in a test — against a real
/// `TunnelRunner` with fake seams for every sequence the runner can produce,
/// and against a scripted double for the two it cannot (a `stop()` that
/// parks, and a terminal state after a dial that already succeeded).
///
/// The App layer declares its own, `TunnelRunning`
/// (`Sources/MacSCPAppKit/TunnelManager.swift`), with `states`, `start` and
/// `stop` and no `boundPort` — it mirrors states into the UI and reads the
/// port from nothing. Two small protocols over one actor, each naming what
/// its own consumer needs, rather than one shared surface that would put a
/// port on the manager's seam and a window's concerns in Core.
public protocol ForegroundTunnel: Sendable {
    /// Every state this runner has published, in order, buffered without
    /// bound. Single consumer, and in this process that consumer is `drive`.
    nonisolated var states: AsyncStream<TunnelState> { get }

    /// The port the running forward actually bound, or `nil` when no forward
    /// is up.
    var boundPort: Int? { get async }

    /// Starts the tunnel. The decider answers for an UNKNOWN host key; a
    /// MISMATCH never reaches it.
    func start(decider: HostKeyDecider) async

    /// Stops it, returning once the connection and the forward are gone.
    func stop() async
}

extension TunnelRunner: ForegroundTunnel {}

/// Where a foreground run writes: one stream for the state lines a `--json`
/// consumer parses, one for the sentences a person reads.
///
/// Two closures rather than a protocol, because the CLI's own two
/// destinations are already two functions (`Swift.print` and
/// `OutputFormatter.note`), and a test's are two arrays.
public struct TunnelForegroundOutput: Sendable {
    /// One state line. Stdout in the command line.
    public let line: @Sendable (String) -> Void
    /// One diagnostic sentence. Stderr in the command line, so a question or
    /// a failure can never land in the middle of `--json` output someone is
    /// piping into `jq`.
    public let note: @Sendable (String) -> Void

    public init(
        line: @escaping @Sendable (String) -> Void, note: @escaping @Sendable (String) -> Void
    ) {
        self.line = line
        self.note = note
    }
}

/// What a dial failed with, as the two Sendable facts an exit needs.
///
/// The ERROR itself is only in hand inside the dial: by the time the runner
/// publishes `failed` or `needsConfirmation` it has become mapped text, and
/// it is the error that tells 10 from 11 and 12 from 13. So it is mapped
/// where it is caught, through the same `CLIErrorMapping` every other
/// subcommand exits by, and only the answer travels.
public struct TunnelDialFailure: Sendable, Equatable {
    public let code: CLIExitCode
    public let message: String

    public init(_ error: any Error) {
        code = CLIErrorMapping.exitCode(for: error)
        message = CLIErrorMapping.message(for: error)
    }

    public init(code: CLIExitCode, message: String) {
        self.code = code
        self.message = message
    }
}

/// The last dial failure, if the last dial failed.
///
/// **A success clears it**, and that is the whole reason this is a type
/// rather than a variable someone assigns to. A record that only ever grew
/// would let an error the tunnel has since recovered from — a credential
/// helper that failed on one retry and worked on the next — decide the exit
/// code of an unrelated failure minutes later. `dialing(_:)` is the only way
/// to write it, so the clear cannot be forgotten at a call site.
public final class TunnelDialFailureRecord: Sendable {
    private let value = Mutex<TunnelDialFailure?>(nil)

    public init() {}

    /// What the last dial failed with, or `nil` if the last one worked (or
    /// none has run).
    public var current: TunnelDialFailure? { value.withLock { $0 } }

    /// Runs one dial: records what it throws, clears the record when it
    /// returns.
    public func dialing<T>(_ dial: () async throws -> T) async throws -> T {
        do {
            let connection = try await dial()
            value.withLock { $0 = nil }
            return connection
        } catch {
            value.withLock { $0 = TunnelDialFailure(error) }
            throw error
        }
    }
}

/// The loop `macscp-cli tunnels start` is: print a line per published state,
/// stop when a signal says so, and leave with the code the state that ended
/// the run earns.
///
/// In Core, not in the command's own file, for the reason `CLIErrorMapping`
/// states about itself — the command-line target is an executable with no
/// test target — and because this loop is where the behaviour lives: the
/// ordering, the signal handling and the teardown are the things a reader
/// would want measured, and none of them can be measured from there. What
/// stays in `TunnelStartCommand.swift` is the composition, the stdio
/// buffering and the process exit.
public enum TunnelForegroundRun {
    /// What the loop is waiting for: the next state, or the second signal.
    private enum Event {
        case state(TunnelState)
        /// A second signal, while the stop the first one asked for is still
        /// running. See `drive`'s doc comment.
        case abandonTheStop
    }

    /// Holds the tunnel open until a signal, a failure, or a state that
    /// needs a person.
    ///
    /// **Two signals mean two different things.** The first asks for a
    /// clean stop: it starts `stop()` and lets the loop print the `stopped`
    /// the runner publishes when the teardown is done. The second says the
    /// caller is not waiting any longer, and it is answered by returning at
    /// once — leaving the stop in flight — so a teardown blocked on a server
    /// that has stopped answering cannot trap a person in their own
    /// terminal. The signal stream is CONSUMED throughout, not abandoned
    /// after the first element, which is what makes the second one arrive at
    /// all.
    ///
    /// The abandoned path still writes the `stopped` line, so both endings
    /// look the same to a `--json` consumer, and it still exits 0: the user
    /// asked for the tunnel to end and it ended. Not 130 — that is the
    /// shell's convention for a process the signal KILLED, and this one
    /// leaves deliberately, having been asked.
    ///
    /// **The port is read when the state arrives**, not when the runner
    /// published it, and there is a window between the two. If the forward
    /// is torn down inside it, `boundPort` reads `nil` and that `active`
    /// line loses its `port=`; the line describes a state that is already
    /// over either way, and the next line follows immediately. It is read
    /// once per active EPISODE and reused for the connection-count lines
    /// under it, so the port cannot change spelling under a tunnel that
    /// never moved — and a read that came back `nil` is retried on the next
    /// line rather than remembered.
    public static func drive(
        runner: some ForegroundTunnel,
        stops: AsyncStream<Void>,
        decider: HostKeyDecider,
        json: Bool,
        verbose: Bool,
        dialFailure: TunnelDialFailureRecord,
        output: TunnelForegroundOutput
    ) async -> CLIExitCode {
        let (events, publish) = AsyncStream.makeStream(of: Event.self)
        let mirror = Task {
            for await state in runner.states { publish.yield(.state(state)) }
            publish.finish()
        }
        let signals = Task {
            var seen = 0
            for await _ in stops {
                seen += 1
                guard seen == 1 else {
                    publish.yield(.abandonTheStop)
                    return
                }
                // NOT awaited here: this task's job is to keep reading the
                // stream, and a stop that parks would otherwise take the
                // reader with it — which is exactly the case the second
                // signal exists for.
                Task { await runner.stop() }
            }
        }
        await runner.start(decider: decider)

        var code = CLIExitCode.success
        var abandoned = false
        var port: Int?
        loop: for await event in events {
            switch event {
            case .abandonTheStop:
                output.line(TunnelStateLine.render(.stopped, json: json))
                abandoned = true
                break loop

            case .state(let state):
                if case .active = state {
                    if port == nil { port = await runner.boundPort }
                } else {
                    port = nil
                }
                output.line(TunnelStateLine.render(state, port: port, json: json))
                if verbose, case .reconnecting(let attempt) = state {
                    output.note(backoffNote(attempt: attempt))
                }
                let failure = dialFailure.current
                guard let terminal = TunnelExit.code(for: state, dialFailure: failure?.code)
                else { continue }
                if let note = TunnelExit.note(for: state, dialMessage: failure?.message) {
                    output.note(note)
                }
                code = terminal
                break loop
            }
        }

        mirror.cancel()
        signals.cancel()
        guard !abandoned else { return .success }
        // Awaited on every other path out, including the ones that ended
        // themselves: `stop()` is idempotent, and on `TunnelRunner` it is
        // queued behind the stop a signal may already have started — so
        // awaiting this one awaits that one too, and the connection and the
        // forward are gone before the code is returned.
        await runner.stop()
        return code
    }

    /// What `--verbose` says when a reconnect is announced.
    ///
    /// Derived from the attempt number the state carries, through the same
    /// `BackoffPlan.delay(attempt:)` the runner itself passes to its sleeper
    /// (`TunnelRunner.run`, the `try await sleeper(BackoffPlan.delay(attempt:
    /// attempt))` in its `.lost` arm — one call site, counted 2026-09-06).
    /// Reading the plan rather than intercepting the sleep is what keeps the
    /// line honest without a second seam: the number printed is the number
    /// the runner asks for, and `TunnelRunnerTests.aFailedRetryKeepsClimbing`
    /// is what pins the runner to that plan.
    public static func backoffNote(attempt: Int) -> String {
        "backoff seconds=\(BackoffPlan.delay(attempt: attempt).components.seconds)"
    }
}
