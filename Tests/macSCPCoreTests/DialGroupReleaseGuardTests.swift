import Foundation
import MacSCPTestSupport
import NIOPosix
import Testing

@testable import macSCPCore

/// Guards that the two files which dial SSH on a dedicated event-loop group
/// shut that group down in exactly one place:
/// `CitadelFileSystem.releaseAfterCitadelTimer`, which outlives the timer
/// Citadel left pending on the group's loop.
///
/// Three paths hand a group to it, and each is checked by name: a failed
/// dial (`connectAuthenticated`'s clean-up, for tabs and forwardings alike),
/// a tab's `disconnect()`, and a forwarding's `disconnect()`. The failed
/// dial must name `citadelLoginTimer`, the timer every handshake schedules
/// whether or not it got as far as `openSFTP`.
///
/// Read over the source with comments and strings blanked. The negative
/// check — no `shutdownGracefully(` outside the release's own body — stands
/// beside a positive one that finds that spelling inside the body, so a
/// scan that stopped seeing it would go red rather than quiet. The
/// behavioural twin is `DialFailureGroupReleaseTests`.
@Suite("Dial group release guard")
struct DialGroupReleaseGuardTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let citadel = root.appendingPathComponent(
        "Sources/macSCPCore/SSH/CitadelFileSystem.swift")
    private static let forwarding = root.appendingPathComponent(
        "Sources/macSCPCore/SSH/SSHForwardingConnection.swift")

    private static let release = "releaseAfterCitadelTimer("
    private static let shutdown = "shutdownGracefully("

    private static func strict(_ file: URL) throws -> String {
        try SwiftSource.blankingCommentsAndStrings(try String(contentsOf: file, encoding: .utf8))
    }

    private static func body(_ signature: String, in source: String) -> String? {
        SSHForwardingConnectionDisconnectGuardTests.body(of: signature, in: source)
    }

    @Test func theReleaseIsTheOnlyShutdownInEitherFile() throws {
        let citadel = try Self.strict(Self.citadel)
        let releaseBody = try #require(
            Self.body("static func releaseAfterCitadelTimer(", in: citadel),
            "no `releaseAfterCitadelTimer` body in CitadelFileSystem.swift — re-anchor this guard")
        #expect(releaseBody.contains(Self.shutdown), "the scan no longer sees the release's own shutdown")

        let citadelOutside = citadel.replacingOccurrences(of: releaseBody, with: "")
        #expect(citadelOutside.count < citadel.count, "the release's body was not cut out of the scan")
        #expect(!citadelOutside.contains(Self.shutdown),
                "CitadelFileSystem.swift shuts a group down outside releaseAfterCitadelTimer")

        let forwarding = try Self.strict(Self.forwarding)
        #expect(forwarding.contains("CitadelFileSystem." + Self.release),
                "the forwarding file no longer hands its group to the release")
        #expect(!forwarding.contains(Self.shutdown),
                "SSHForwardingConnection.swift shuts a group down outside releaseAfterCitadelTimer")
    }

    @Test func aFailedDialReleasesThroughTheReleaseAfterTheLoginTimer() throws {
        let citadel = try Self.strict(Self.citadel)
        let connect = try #require(
            Self.body("static func connectAuthenticated<", in: citadel),
            "no `connectAuthenticated` body in CitadelFileSystem.swift — re-anchor this guard")
        #expect(connect.contains("connectWithTOFURetries("), "the body scanned is not the dial")
        #expect(connect.contains(Self.release))
        #expect(connect.contains("citadelLoginTimer"))
    }

    @Test func bothDisconnectsReleaseThroughTheRelease() throws {
        let tab = try #require(
            Self.body("public func disconnect()", in: try Self.strict(Self.citadel)),
            "no `disconnect()` body in CitadelFileSystem.swift — re-anchor this guard")
        #expect(tab.contains("closeBounded()"), "the tab body scanned is not the disconnect")
        #expect(tab.contains(Self.release))

        let forwarding = try #require(
            Self.body("func disconnect()", in: try Self.strict(Self.forwarding)),
            "no `disconnect()` body in SSHForwardingConnection.swift — re-anchor this guard")
        #expect(forwarding.contains("client.close()"), "the forwarding body scanned is not the disconnect")
        #expect(forwarding.contains(Self.release))
    }

    /// The names the scan searches for, referenced as values: a rename fails
    /// the build rather than emptying a needle.
    @Test func theNamesTheScanSearchesForExist() {
        let timer: Duration = CitadelFileSystem.citadelLoginTimer
        let release: (MultiThreadedEventLoopGroup, Duration) -> Void =
            CitadelFileSystem.releaseAfterCitadelTimer(_:outliving:)
        _ = (timer, release)
    }
}
