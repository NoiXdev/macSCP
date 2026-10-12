import Foundation
import Observation

/// Runs one invocation of a local file action and reports how it ended.
/// Holds no policy: which invocations to run was decided by
/// `FileActionPlanner`.
///
/// Returns the exit status. Throws `CancellationError` when the run was
/// cancelled, `FileActionTimedOut` when it outlived its budget, and anything
/// else when the program could not be started.
public protocol FileActionRunner: Sendable {
    func run(_ invocation: FileActionInvocation) async throws -> Int32
}

/// The run outlived its budget and was ended. Carries no text: the
/// subprocess runner's own timeout error embeds what the program wrote to
/// stderr, and that can name files.
public struct FileActionTimedOut: Error, Equatable, Sendable {}

/// The one local file action a pane may have running, and how the last one
/// ended.
///
/// **Why the work is started here.** The pane's teardown calls `cancel()`
/// on this object, and nothing else. A run started by an unstructured
/// `Task` in the pane would be owned by nothing: a tab closed mid-run would
/// find no operation to cancel, and the program would run on in a pane that
/// no longer existed. `ArchiveActivity` carries the measurement; this type
/// copies its shape, and `FileActionPaneWiringGuardTests` forbids the pane
/// from spelling a `Task` of its own.
///
/// **Only the local path comes here.** A remote action is TYPED into the
/// user's own shell by the pane, through the snippet send path, so nothing in
/// Core executes it. `run` therefore refuses `.shellLines` outright rather
/// than treating it as a plan with something to do: an activity that could
/// run a shell line would be the execution entry point the design withdrew.
///
/// **At most one per pane.** `run` answers `false` while one runs. Nothing
/// queues.
///
/// **A failed invocation stops the rest.** This differs from the remote
/// path, where the shell runs every typed line whatever the one before did,
/// because nothing there reads a status. Here the status is known, and
/// carrying on over a selection after one file failed would hide the failure
/// under the successes that follow it.
///
/// **No output is kept.** The program's standard output and standard error
/// are drained and dropped: they are a far side's text (they can name the
/// files of a listing) and the ending is a sentence the App layer owns.
@Observable
@MainActor
public final class FileActionActivity {
    public enum State: Equatable, Sendable {
        case idle
        /// `title` is the action's name.
        case running(title: String)
    }

    public enum Ending: Equatable, Sendable {
        case finished
        /// A cancel is an ending of its own, never a failure: the user did
        /// nothing wrong.
        case cancelled
        /// A program ended with a non-zero status. 127 also stands for a
        /// program that was not found, as in a shell.
        case failed(status: Int)
        case timedOut
        /// The runner could not start the program, or failed for a reason
        /// that is not a status. Deliberately one case, and carries no text.
        case couldNotRun
        /// The plan was `.shellLines`, which only a shell can run.
        case notRunnableHere
    }

    public struct Outcome: Equatable, Sendable {
        /// The action the ending is about.
        public let title: String
        public let ending: Ending

        public init(title: String, ending: Ending) {
            self.title = title
            self.ending = ending
        }
    }

    public private(set) var state: State = .idle
    /// The last ending, kept until the next `run` or `dismissOutcome()` so the
    /// pane can show one sentence about it.
    public private(set) var lastOutcome: Outcome?

    private var task: Task<Void, Never>?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public var isRunning: Bool { state != .idle }

    /// Starts `plan` on `runner`, one invocation after another. Returns
    /// `false`, and starts nothing, while an action is already running, and
    /// for a plan that is not a list of invocations.
    ///
    /// A cancel landing between two invocations is honoured before the next
    /// one starts, whether or not the runner noticed it: `Task.checkCancellation()`
    /// stands between them.
    @discardableResult
    public func run(_ plan: FileActionPlan, title: String, using runner: any FileActionRunner)
        -> Bool
    {
        guard state == .idle else { return false }
        guard case .invocations(let invocations) = plan else {
            lastOutcome = Outcome(title: title, ending: .notRunnableHere)
            return false
        }
        state = .running(title: title)
        lastOutcome = nil
        task = Task { [self] in
            let ending: Ending
            do {
                var stopped: Ending?
                for invocation in invocations {
                    try Task.checkCancellation()
                    let status = try await runner.run(invocation)
                    // Status first, then cancellation: a cancel arriving after
                    // a failed exit must not hide the failure.
                    if status != 0 {
                        stopped = .failed(status: Int(status))
                        break
                    }
                }
                ending = stopped ?? (Task.isCancelled ? .cancelled : .finished)
            } catch is FileActionTimedOut {
                ending = .timedOut
            } catch {
                // A cancelled run may surface as any error at all; the task's
                // own flag is the reliable witness.
                ending = error is CancellationError || Task.isCancelled
                    ? .cancelled : .couldNotRun
            }
            finish(title: title, with: ending)
        }
        return true
    }

    /// Cancels the running action. Its ending arrives through its task, as
    /// `.cancelled`.
    public func cancel() { task?.cancel() }

    /// Forgets the last ending, so the pane stops showing it.
    public func dismissOutcome() { lastOutcome = nil }

    /// Returns once nothing is running. An `await` over a continuation the
    /// finishing task raises: no polling and no sleeping, which would be a
    /// wall-clock wait in a suite that is not allowed one.
    public func waitUntilIdle() async {
        guard state != .idle else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    private func finish(title: String, with ending: Ending) {
        task = nil
        lastOutcome = Outcome(title: title, ending: ending)
        state = .idle
        let waiters = idleWaiters
        idleWaiters = []
        for waiter in waiters { waiter.resume() }
    }
}

/// The local pane's runner. No shell anywhere on this path: the argv is
/// handed to the kernel as it stands.
public struct LocalFileActionRunner: FileActionRunner {
    private let currentDirectory: URL?
    private let timeout: Duration

    /// `currentDirectory` is where the program starts: the directory the pane
    /// shows, so a `{{NAME}}` (the file name alone) means the file the user
    /// selected.
    public init(currentDirectory: URL?) {
        self.currentDirectory = currentDirectory
        timeout = Self.budget
    }

    /// An hour, like an archive run: a program that legitimately takes
    /// minutes must not be cut off by a budget sized for short CLI calls.
    static let budget: Duration = .seconds(60 * 60)

    /// Where a bare program name is looked for: the system's own
    /// directories, in this order, and nowhere else. This process's `PATH`
    /// is not consulted, because a `PATH` lookup is a second way to choose
    /// an executable, and a program elsewhere (a package manager's) is
    /// named by its absolute path in the template.
    static let searchDirectories = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    /// The path to run for `name`, or `nil` when there is none.
    ///
    /// An absolute `name` is used as written. A name with any other `/` is a
    /// relative path, which would depend on a working directory, and is not
    /// resolved. `isExecutable` is a seam so the order is testable without
    /// the file system.
    static func resolve(_ name: String, isExecutable: (String) -> Bool) -> String? {
        if name.hasPrefix("/") { return isExecutable(name) ? name : nil }
        guard !name.isEmpty, !name.contains("/") else { return nil }
        for directory in searchDirectories {
            let candidate = directory + "/" + name
            if isExecutable(candidate) { return candidate }
        }
        return nil
    }

    public func run(_ invocation: FileActionInvocation) async throws -> Int32 {
        guard
            let path = Self.resolve(
                invocation.executable,
                isExecutable: { FileManager.default.isExecutableFile(atPath: $0) })
        else { return 127 }
        do {
            let result = try await SubprocessRunner.run(
                URL(fileURLWithPath: path),
                arguments: invocation.arguments,
                currentDirectory: currentDirectory,
                timeout: timeout)
            return result.status
        } catch is SubprocessCancelled {
            // The runner has ended the child. The error is dropped unread:
            // its description embeds the program's stderr.
            throw CancellationError()
        } catch is SubprocessTimeout {
            throw FileActionTimedOut()
        }
    }
}
