import Foundation
import MacSCPTestSupport
import Synchronization
import Testing

@testable import macSCPCore

/// The command line's connection scope (`CLIConnectionScope`) against an
/// upload abort still running when the command is done (final review I1 of
/// the 2026-09-19 plan): the process exits right after, and an abort still
/// running dies with it. So the scope waits for the connection's pending
/// aborts before it disconnects, and names each one that did not confirm.
///
/// The connection holds its pending aborts until the case releases them, so
/// the ordering is fixed without a clock; the time limit is a hang bound.
@Suite("The command line's connection scope", .timeLimit(.minutes(2)))
struct CLIConnectionScopeTests {
    @Test(arguments: [true, false])
    func theScopeWaitsForPendingAbortsBeforeItDisconnectsAndNamesTheUnconfirmed(
        bodyThrows: Bool
    ) async throws {
        let fs = PendingAbortFileSystem()
        let run = Task { () -> (any Error)? in
            defer { fs.record("returned") }
            do {
                try await CLIConnectionScope.run(fs, noteUnconfirmedAbort: fs.note) { fs in
                    if bodyThrows { throw RemoteFSError.authenticationFailed }
                }
                return nil
            } catch {
                return error
            }
        }

        #expect(await fs.waitingOrReturned.wait() == .signalled)
        let returnedBeforeTheAbortsAnswered = fs.events.contains("returned")
        #expect(returnedBeforeTheAbortsAnswered == false, """
            the scope returned without waiting for the pending aborts: \(fs.events)
            """)
        fs.release.signal()
        let error = await run.value

        if bodyThrows {
            #expect(error as? RemoteFSError == .authenticationFailed)
        } else {
            #expect(error == nil)
        }
        #expect(fs.events == ["waiting", "answered", "disconnected", "returned"])
        #expect(fs.notes == ["big.bin"])
    }

    /// The command-line target has no test target, so `withConnection`'s
    /// hand-over is pinned by reading it: its body calls the scope. A
    /// POSITIVE check, spelled from the type rather than as a literal.
    /// Comments and strings are blanked first, so this doc comment and the
    /// function's own cannot satisfy it.
    @Test func withConnectionHandsItsConnectionToTheScope() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MacSCPCLI/SessionConnecting.swift")
        let code = try SwiftSource.blankingCommentsAndStrings(
            String(contentsOf: file, encoding: .utf8))
        let start = try #require(code.range(of: "func withConnection("))
        let end = code.range(of: "\nfunc ", range: start.upperBound..<code.endIndex)?.lowerBound
            ?? code.endIndex
        let body = code[start.upperBound..<end]
        #expect(body.contains("\(String(describing: CLIConnectionScope.self)).run("))
    }
}

/// A connection with one pending upload abort, which answers "not
/// confirmed" for `big.bin` once the case releases it. Records what was
/// asked of it, in order.
final class PendingAbortFileSystem: RemoteFileSystem {
    private struct State {
        var events: [String] = []
        var notes: [String] = []
    }

    private let state = Mutex(State())
    /// Raised when the scope starts waiting for the aborts, or by the case
    /// when the scope returned — whichever comes first.
    let waitingOrReturned = AsyncSignal()
    let release = AsyncSignal()

    var events: [String] { state.withLock { $0.events } }
    var notes: [String] { state.withLock { $0.notes } }

    func record(_ event: String) {
        state.withLock { $0.events.append(event) }
        if event == "returned" { waitingOrReturned.signal() }
    }

    func note(_ objectKey: String) {
        state.withLock { $0.notes.append(objectKey) }
    }

    func awaitUnconfirmedAborts() async -> [String] {
        record("waiting")
        waitingOrReturned.signal()
        _ = await release.wait()
        record("answered")
        return ["big.bin"]
    }

    func disconnect() async { record("disconnected") }

    func list(path: String) async throws -> [RemoteFileItem] { throw Self.unused }
    func stat(path: String) async throws -> RemoteFileItem { throw Self.unused }
    func readStream(
        path: String, fromOffset offset: UInt64
    ) async throws -> AsyncThrowingStream<Data, Error> { throw Self.unused }
    func write(
        path: String, mode: WriteMode, contents: AsyncThrowingStream<Data, Error>
    ) async throws { throw Self.unused }
    func delete(path: String) async throws { throw Self.unused }
    func createDirectory(at path: String) async throws { throw Self.unused }
    func rename(from: String, to: String) async throws { throw Self.unused }
    func setPermissions(path: String, permissions: UInt32) async throws { throw Self.unused }
    func deleteTree(at path: String) async throws { throw Self.unused }
    func homeDirectoryPath() async throws -> String { throw Self.unused }

    private static let unused = RemoteFSError.protocolError(reason: "not used here")
}
