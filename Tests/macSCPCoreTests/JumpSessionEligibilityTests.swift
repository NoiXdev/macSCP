import Foundation
import Testing
@testable import macSCPCore

@Suite("JumpSessionEligibility")
struct JumpSessionEligibilityTests {
    @Test func excludesEditedSessionAndChains() throws {
        let a = sshSession(name: "Beta", host: "a", username: "u")
        let b = sshSession(name: "alpha", host: "b", username: "u")
        let jump = StoredSession.JumpSpec(host: "j", username: "u")
        let c = sshSession(name: "Chain", host: "c", username: "u", jump: jump)
        let d = sshSession(name: "Edited", host: "d", username: "u")

        let eligible = JumpSessionEligibility.eligible(for: d.id, in: [a, b, c, d])
        // Case-insensitive name order: "alpha" before "Beta".
        #expect(eligible == [b, a])
    }

    @Test func nilEditingIDKeepsAll() throws {
        let a = sshSession(name: "Beta", host: "a", username: "u")
        let jump = StoredSession.JumpSpec(host: "j", username: "u")
        let c = sshSession(name: "Chain", host: "c", username: "u", jump: jump)

        let eligible = JumpSessionEligibility.eligible(for: nil, in: [a, c])
        #expect(eligible == [a])
    }

    /// Formerly `nonSSHSessionsAreStillOfferedAsJumpHosts`, a CHARACTERIZATION
    /// test that documented a bug: `eligible(for:in:)` used to filter only on
    /// the edited session and on chains, so a `.s3` or `.webdav` session was
    /// offered as a jump host even though only SSH tunnels. As of M24/T4 the
    /// picker also filters on `kind == .ssh`, so the bucket is excluded here.
    ///
    /// The picker filter alone does not close the gap for sessions saved
    /// before this change: `LoginResolver.resolveJump(...sessions:
    /// referencingSessionID:)` carries the actual hard stop
    /// (`.jumpSessionNotSSH`), covered separately in `LoginResolverTests`.
    @Test func onlySSHSessionsAreOfferedAsJumpHosts() throws {
        let ssh = sshSession(name: "alpha", host: "a", username: "u")
        let bucket = s3Session(name: "Bravo")

        let eligible = JumpSessionEligibility.eligible(for: nil, in: [ssh, bucket])

        #expect(eligible == [ssh])
    }
}
