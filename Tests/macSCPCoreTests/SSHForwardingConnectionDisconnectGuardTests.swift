import Foundation
import MacSCPTestSupport
import NIOPosix
import Testing

@testable import macSCPCore

/// Guards that a forwarding's `disconnect()` releases its dedicated
/// event-loop group only after Citadel's login timer, never at once.
///
/// Citadel's `ClientHandshakeHandler.init` (`ClientSession.swift:76-83`,
/// created at `:170-173`) schedules a 10-second login timeout on the
/// connection's event loop, once per hop, and never cancels it. An
/// `.agent`-authenticated forwarding runs on a group of its own, so a
/// forwarding stopped within ten seconds of its dial — a refused `-R` bind,
/// a quick stop after autostart — would shut that group down with the task
/// still pending: the shape `CitadelFileSystem.disconnect()` already waits
/// out for `openSFTP`'s 15-second timer.
///
/// A source guard, not a behavioural test, because the effect was NOT
/// observable (2026-09-17): three agent-authenticated forwarding dials
/// against the rig, each disconnected at once with the group shut down
/// immediately, then twelve seconds of waiting past the timer — no NIO
/// "Cannot schedule tasks" line in the test output. So there is no red to
/// measure, and the delay is pinned by what the code says instead.
///
/// Read over the source with comments and strings blanked. The positive
/// checks (the delayed release is called, and with the login timer) stand
/// beside the negative one (no immediate `shutdownGracefully` in the body),
/// and the body itself must be found.
@Suite("SSHForwardingConnection disconnect guard")
struct SSHForwardingConnectionDisconnectGuardTests {
    private static let file = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/macSCPCore/SSH/SSHForwardingConnection.swift")

    @Test func disconnectReleasesTheGroupOnlyAfterTheLoginTimer() throws {
        let strict = try SourceCorpus.code(of: Self.file)
        let body = try #require(
            Self.body(of: "func disconnect()", in: strict),
            "no `func disconnect()` body in SSHForwardingConnection.swift — re-anchor this guard")

        #expect(body.contains("try? await client.close()"), "the body scanned is not the disconnect")
        #expect(body.contains("CitadelFileSystem.releaseAfterCitadelTimer("))
        #expect(body.contains("CitadelFileSystem.citadelLoginTimer"))
        #expect(!body.contains("shutdownGracefully("), "the group is shut down at once")
    }

    /// The names the scan searches for, referenced as values: a rename fails
    /// the build rather than emptying a needle.
    @Test func theNamesTheScanSearchesForExist() {
        let timer: Duration = CitadelFileSystem.citadelLoginTimer
        let release: (MultiThreadedEventLoopGroup, Duration) -> Void =
            CitadelFileSystem.releaseAfterCitadelTimer(_:outliving:)
        _ = (timer, release)
    }

    /// The text from `signature`'s opening brace to its matching close, or
    /// `nil` when the signature is absent or unbalanced.
    static func body(of signature: String, in source: String) -> String? {
        guard let start = source.range(of: signature),
            let open = source[start.upperBound...].firstIndex(of: "{")
        else { return nil }
        var depth = 0
        var index = open
        while index < source.endIndex {
            switch source[index] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return String(source[open...index]) }
            default: break
            }
            index = source.index(after: index)
        }
        return nil
    }

    @Test func theBodyScannerFindsANestedBody() {
        let source = "func disconnect() async { if x { y() } z() }\nfunc other() {}"
        #expect(Self.body(of: "func disconnect()", in: source) == "{ if x { y() } z() }")
        #expect(Self.body(of: "func missing()", in: source) == nil)
    }
}
