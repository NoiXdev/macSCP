import Foundation

/// How an archive run ended, as far as the runner can tell.
public enum ArchiveOutcome: Sendable, Equatable {
    case finished
    case cancelled
}

/// Why an archive run did not finish. Each case maps to one sentence the
/// user is shown; none of them carries a tool's raw output, because that
/// output is a far side's text and belongs in no `reason:` string.
public enum ArchiveFailure: Error, Equatable, Sendable {
    /// Exit 127, or a local executable that is not there.
    case toolMissing(tool: String)
    /// Any other non-zero status.
    case exited(status: Int)
    /// The run outlived its budget and was ended. Carries no text: the
    /// runner's own timeout error embeds the tool's stderr so far, which
    /// names files, and that is a far side's text.
    case timedOut
}

/// The budget an archive run gets. Far above `SubprocessRunner.run`'s own
/// 60-second default, which is sized for short CLI calls: compressing a
/// large folder legitimately takes many minutes, and a budget that cuts it
/// off would be a wall-clock ceiling on the USER's machine.
public enum ArchiveBudget {
    public static let run: Duration = .seconds(60 * 60)
}

/// Runs a plan. Holds no policy: which command to run was decided by
/// `ArchivePlan`.
public protocol ArchiveRunner: Sendable {
    func run(_ plan: ArchivePlan) async throws -> ArchiveOutcome
}

/// The local pane's runner. No shell anywhere on this path.
public struct LocalArchiveRunner: ArchiveRunner {
    private let timeout: Duration

    public init() { timeout = ArchiveBudget.run }

    /// Internal: a test needs a budget it can outlive without waiting an hour.
    init(timeout: Duration) { self.timeout = timeout }

    public func run(_ plan: ArchivePlan) async throws -> ArchiveOutcome {
        let invocation = try plan.localInvocation(resolvingToolWith: Self.resolve(_:))
        guard FileManager.default.isExecutableFile(atPath: invocation.executable.path) else {
            throw ArchiveFailure.toolMissing(tool: plan.tool)
        }
        let result: SubprocessResult
        do {
            result = try await SubprocessRunner.run(
                invocation.executable,
                arguments: invocation.arguments,
                currentDirectory: invocation.currentDirectory,
                stdin: invocation.stdin,
                timeout: timeout)
        } catch is SubprocessCancelled {
            // The runner has ended the child. Reported as an outcome rather
            // than rethrown as `CancellationError`: a user cancelling a long
            // archive did nothing wrong, and `ArchiveOutcome.cancelled`
            // exists so the caller need not tell a cancel from a failure by
            // catching. The error is dropped unread: its description embeds
            // the tool's stderr.
            return .cancelled
        } catch is SubprocessTimeout {
            throw ArchiveFailure.timedOut
        }
        // Status first, then cancellation: a cancel arriving after a failed
        // exit must not hide the failure.
        switch result.status {
        case 0: return Task.isCancelled ? .cancelled : .finished
        case 127: throw ArchiveFailure.toolMissing(tool: plan.tool)
        case let status: throw ArchiveFailure.exited(status: Int(status))
        }
    }

    /// `/usr/bin/<tool>` for every tool this feature names. Spelled as a
    /// path rather than found through `PATH`, because a `PATH` lookup is a
    /// second way for this process to choose an executable and macOS ships
    /// all five at that location.
    static func resolve(_ tool: String) -> String { "/usr/bin/" + tool }
}

/// The remote pane's runner, over whichever backend answered the capability.
public struct RemoteArchiveRunner: ArchiveRunner {
    private let channel: any ArchiveCommandChannel

    /// Internal, not `package` and not `public`: Swift refuses a `package`
    /// initializer whose parameter is an internal type, and the choice was
    /// between widening this initializer's access and widening
    /// `ArchiveCommandChannel`. The protocol stays internal because its
    /// narrowness is the design (no parameter is a `String`, so no caller can
    /// phrase a command), and every consumer of the module would otherwise
    /// gain a second conformance surface to watch. Code outside Core reaches
    /// this runner through `init?(backend:)`, which does the capability
    /// question inside the module.
    init(channel: any ArchiveCommandChannel) {
        self.channel = channel
    }

    /// The runner over `backend`, or `nil` when the backend does not answer
    /// the archive capability.
    ///
    /// The cost of this seam, stated so nobody discovers it: `any Sendable`
    /// accepts ANY argument, so a wrong argument at a call site compiles and
    /// yields `nil` forever. The only guard is a test that passes a real
    /// conforming backend and a real non-conforming one.
    ///
    /// The `as?` happens here, inside the module that
    /// owns the protocol, so a caller in another target asks "can this
    /// backend do it" without ever naming the seam.
    package init?(backend: any Sendable) {
        guard let channel = backend as? any ArchiveCommandChannel else { return nil }
        self.channel = channel
    }

    public func run(_ plan: ArchivePlan) async throws -> ArchiveOutcome {
        do {
            let status = try await channel.run(plan.remoteCommandLine(), stdin: plan.stdin)
            guard status == 0 else { throw ArchiveFailure.exited(status: status) }
            return Task.isCancelled ? .cancelled : .finished
        } catch let failure as ArchiveCommandExitFailure {
            if failure.isToolMissing { throw ArchiveFailure.toolMissing(tool: plan.tool) }
            throw ArchiveFailure.exited(status: failure.exitCode)
        }
    }
}
