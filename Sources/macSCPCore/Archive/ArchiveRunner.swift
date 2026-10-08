import Foundation
import Synchronization

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

/// A listing's standard output outgrew the byte bound its caller set.
/// Nothing of the output is kept: a truncated list would under-report how
/// many entries an extraction collides with, which is the one direction the
/// extract dialog must not be wrong in. Carries the bound and no text.
///
/// Separate from `ArchiveFailure` on purpose: that enum is what a RUN ends
/// in, and each of its cases has a sentence the pane shows. A listing that
/// is too large is not a failed run, it is a preview that cannot be offered.
public struct ArchiveListingTooLarge: Error, Equatable, Sendable {
    /// The bound, in BYTES of standard output.
    public let limit: Int
}

extension ArchiveBudget {
    /// The bound the extract dialog passes to a listing: **bytes of
    /// standard output**, not a number of entries. The output is held in
    /// memory while it is read, so an archive past this is refused a
    /// preview rather than read in full.
    public static let listingBytes = 4 * 1024 * 1024
}

/// Runs a plan. Holds no policy: which command to run was decided by
/// `ArchivePlan`.
public protocol ArchiveRunner: Sendable {
    func run(_ plan: ArchivePlan) async throws -> ArchiveOutcome

    /// The entries `plan` lists, one per element, bounded in BYTES of
    /// standard output.
    ///
    /// **`limit` is a number of bytes, not of entries.** Past it the call
    /// THROWS rather than truncating, because a truncated listing
    /// under-reports collisions, and that is the one direction the extract
    /// dialog must not be wrong in. A non-zero exit is an `ArchiveFailure`,
    /// exactly as `run` maps it.
    func listing(_ plan: ArchivePlan, limit: Int) async throws -> [String]
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

    /// The entries `plan` lists, bounded in BYTES of standard output.
    ///
    /// The same contract as `ArchiveCommandChannel.listing(of:limit:)`, which
    /// is the remote half of it: past the bound the call throws
    /// `ArchiveListingTooLarge` rather than truncating.
    ///
    /// `SubprocessRunner` collects a child's whole output, so the bound is
    /// enforced from its `onStdoutChunk` seam: the moment the running total
    /// passes `limit`, the run's task is cancelled, which ends the child, and
    /// what is held is the bound plus at most one chunk instead of an
    /// archive's whole table of contents. The total is also checked once the
    /// run returns, so a child that finishes before the cancel lands is
    /// still refused.
    public func listing(_ plan: ArchivePlan, limit: Int) async throws -> [String] {
        let invocation = try plan.localInvocation(resolvingToolWith: Self.resolve(_:))
        guard FileManager.default.isExecutableFile(atPath: invocation.executable.path) else {
            throw ArchiveFailure.toolMissing(tool: plan.tool)
        }
        let watch = ListingBound(limit: limit)
        let timeout = self.timeout
        let child = Task {
            try await SubprocessRunner.run(
                invocation.executable,
                arguments: invocation.arguments,
                currentDirectory: invocation.currentDirectory,
                stdin: invocation.stdin,
                timeout: timeout,
                onStdoutChunk: { watch.observe($0.count) })
        }
        watch.attach(child)
        let result: SubprocessResult
        do {
            result = try await withTaskCancellationHandler {
                try await child.value
            } onCancel: {
                child.cancel()
            }
        } catch is SubprocessCancelled {
            // Either this call's caller cancelled, or the bound did. Only the
            // bound leaves a mark.
            if watch.exceeded { throw ArchiveListingTooLarge(limit: limit) }
            throw CancellationError()
        } catch is SubprocessTimeout {
            throw ArchiveFailure.timedOut
        }
        // Status first: a tool that failed is a failure whatever it printed
        // before it did.
        switch result.status {
        case 0: break
        case 127: throw ArchiveFailure.toolMissing(tool: plan.tool)
        case let status: throw ArchiveFailure.exited(status: Int(status))
        }
        guard !watch.exceeded, result.stdout.count <= limit else {
            throw ArchiveListingTooLarge(limit: limit)
        }
        return String(decoding: result.stdout, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    /// Counts a listing's standard output as it arrives and ends the run the
    /// moment the count passes the bound.
    private final class ListingBound: Sendable {
        private struct State {
            var seen = 0
            var exceeded = false
            var child: Task<SubprocessResult, any Error>?
        }
        private let limit: Int
        private let state = Mutex(State())

        init(limit: Int) { self.limit = limit }

        var exceeded: Bool { state.withLock { $0.exceeded } }

        /// Called from the stdout reader. The child is cancelled outside the
        /// lock; cancelling is idempotent.
        func observe(_ count: Int) {
            let toCancel: Task<SubprocessResult, any Error>? = state.withLock { state in
                state.seen += count
                guard state.seen > limit, !state.exceeded else { return nil }
                state.exceeded = true
                return state.child
            }
            toCancel?.cancel()
        }

        /// A chunk can land before the task is stored; the bound then
        /// cancels it on arrival.
        func attach(_ child: Task<SubprocessResult, any Error>) {
            let cancelNow: Bool = state.withLock { state in
                state.child = child
                return state.exceeded
            }
            if cancelNow { child.cancel() }
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

    /// The entries `plan` lists, bounded in BYTES of standard output by the
    /// channel. A non-zero exit maps exactly as `run` maps it. A listing
    /// past the bound is the channel's own throw, not an `ArchiveFailure`:
    /// the far side's command succeeded and it is this side that will not
    /// keep the answer.
    public func listing(_ plan: ArchivePlan, limit: Int) async throws -> [String] {
        do {
            return try await channel.listing(of: plan.remoteCommandLine(), limit: limit)
        } catch let failure as ArchiveCommandExitFailure {
            if failure.isToolMissing { throw ArchiveFailure.toolMissing(tool: plan.tool) }
            throw ArchiveFailure.exited(status: failure.exitCode)
        }
    }
}
