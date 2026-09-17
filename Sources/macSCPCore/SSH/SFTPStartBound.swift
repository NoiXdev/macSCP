import Foundation

/// A tab's dial authenticated, asked the server for SFTP, and heard nothing
/// back inside the dial's connect timeout.
///
/// One case, and no payload: nothing the server said is carried, because the
/// server said nothing — that silence is the whole finding. The commonest
/// cause is a server without the SFTP subsystem: OpenSSH refuses the
/// subsystem request with a channel failure Citadel's SFTP handlers ignore,
/// so the only symptom a client can observe is the missing version reply.
public enum SFTPStartError: Error, Equatable, Sendable {
    case noResponse
}

/// Bounds a tab's SFTP start (`CitadelFileSystem.connect`'s step after
/// authentication) by a deadline, because Citadel does not.
///
/// Citadel's `openSFTP` ends its chain on
/// `client.responses.sftpVersion.futureResult`
/// (`.build/checkouts/Citadel/Sources/Citadel/SFTP/Client/SFTPClient.swift:566-567`),
/// which only the server's version reply completes. Its own 15-second timer
/// fails the channel and client promises, not that one — and by the time the
/// wait begins both of those have already succeeded, so the timer changes
/// nothing. `.get()` on the future does not answer task cancellation either.
/// Against a server that never replies, the call is not slow; it does not
/// end.
///
/// ## The shape: a structured race that closes the client
///
/// The open and the deadline run as two children of one task group. The
/// first to finish decides:
///
/// - the open finishes (with a session or with its own error): the deadline
///   child is cancelled, and that result is the start's result;
/// - the deadline fires: the client is closed, and the start throws
///   `SFTPStartError.noResponse`;
/// - the deadline child throws — the dial's task was cancelled, and the
///   sleeper answers cancellation: the client is closed, and the start
///   rethrows that error.
///
/// In both of the last two arms the group then waits for the open child to
/// end before the start returns, so no suspended task outlives the dial.
/// What ends that child is the close, and this is read from the code, not
/// assumed: `SSHClient.close()` closes the connection's channel; NIOSSH's
/// `NIOSSHHandler.channelInactive` (`NIOSSHHandler.swift:154-156`) calls the
/// multiplexer's `parentChannelInactive()`, which puts every child channel
/// through `errorEncountered` (`SSHChildChannel.swift:1008-1015`), and that
/// fails the child's close promise (`:594`); Citadel's SFTP client runs
/// `responses.close()` when that close future completes
/// (`SFTPClient.swift:57-60`), and `responses.close()` fails `sftpVersion`
/// with `SFTPError.connectionClosed` (`:604-606`). So the pending wait fails,
/// `openSFTP` throws, and the child ends.
/// `SFTPStartBoundTests.aTabDialAgainstAServerThatNeverStartsSFTPEndsWithItsOwnError`
/// runs that path against a real NIOSSH server: a close that did not fail
/// the future would leave that test waiting inside its hang bound.
///
/// The trade the structured shape makes, stated: the start's return depends
/// on that close ending the open. An unstructured child resumed through a
/// continuation would return regardless, but it would leave a task behind
/// whenever the close did NOT end the open — silently, which is the defect
/// this type exists to remove.
///
/// ## What happens to the connection
///
/// Closing here does not replace the dial's own clean-up: the error still
/// unwinds through `attemptConnect`'s `catch`, which closes the client (a
/// second close of a closed channel fails and is swallowed) and the jump
/// client, and through `connectAuthenticated`'s `catch`, which releases a
/// dedicated event-loop group after Citadel's timer — the SFTP open was
/// attempted, so the R-1 flag is marked.
enum SFTPStartBound {
    /// Waits out a duration. **Must answer cancellation** — the dial's
    /// cancellation reaches the start only through this sleeper.
    typealias Sleeper = @Sendable (Duration) async throws -> Void

    /// Test hook for the sleeper `CitadelFileSystem.connect` hands to `run`,
    /// in the shape of `CitadelFileSystem.AgentClientFactory`: a
    /// `@TaskLocal`, so a test can fire the deadline by hand without the
    /// dial's signature growing a parameter no production caller passes, and
    /// without parallel tests racing on shared state.
    @TaskLocal static var sleeperOverride: Sleeper?

    /// `Task.sleep` unless a test overrides it.
    static var sleeper: Sleeper {
        sleeperOverride ?? { try await Task.sleep(for: $0) }
    }

    /// Runs `open` against `deadline` — see the type's comment for the three
    /// arms and why the start waits for `open` to end.
    ///
    /// `closeClient` must end a pending `open`; for Citadel it is the SSH
    /// client's close.
    static func run<Session: Sendable>(
        deadline: Duration,
        sleeper: @escaping Sleeper,
        open: @escaping @Sendable () async throws -> Session,
        closeClient: @escaping @Sendable () async -> Void
    ) async throws -> Session {
        let outcome = await withTaskGroup(
            of: Child<Session>.self, returning: Result<Session, any Error>.self
        ) { group in
            group.addTask {
                do {
                    return .opened(.success(try await open()))
                } catch {
                    return .opened(.failure(error))
                }
            }
            group.addTask {
                do {
                    try await sleeper(deadline)
                    return .deadline(nil)
                } catch {
                    return .deadline(error)
                }
            }
            // Two children, so the group cannot be empty on the first call.
            guard let first = await group.next() else {
                return .failure(SFTPStartError.noResponse)
            }
            switch first {
            case .opened(let result):
                group.cancelAll()
                return result
            case .deadline(let sleeperError):
                await closeClient()
                // The open child ends because of the close above; wait for
                // it here rather than leave it suspended.
                while await group.next() != nil {}
                return .failure(sleeperError ?? SFTPStartError.noResponse)
            }
        }
        return try outcome.get()
    }

    private enum Child<Session: Sendable>: Sendable {
        case opened(Result<Session, any Error>)
        /// `nil` when the deadline fired; the sleeper's error when it threw.
        case deadline((any Error)?)
    }
}
