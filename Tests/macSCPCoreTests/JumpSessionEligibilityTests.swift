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

    /// CHARACTERIZATION, not an endorsement (M23/T8).
    ///
    /// `eligible(for:in:)` filters on the edited session and on chains, and on
    /// nothing else — a `.s3` or `.webdav` session is offered as a jump host
    /// even though only SSH tunnels. `LoginResolver.resolveJump(...sessions:
    /// referencingSessionID:)` does not refuse one either: it rejects a chain
    /// and a self-reference, then reads the referenced session's host/port
    /// whatever its kind.
    ///
    /// This predates M23 and is unchanged by it — before, such a jump resolved
    /// to the literal placeholder `"unused"`; now it resolves to `""`. Both
    /// are a bastion nobody can dial, so the shape change neither introduces
    /// nor repairs the gap. Pinned here so the next task can see it rather
    /// than rediscover it, and so that ADDING a kind filter breaks a test that
    /// says why on purpose instead of one that looks like a regression.
    @Test func nonSSHSessionsAreStillOfferedAsJumpHosts() throws {
        let ssh = sshSession(name: "alpha", host: "a", username: "u")
        let bucket = s3Session(name: "Bravo")

        let eligible = JumpSessionEligibility.eligible(for: nil, in: [ssh, bucket])

        #expect(eligible == [ssh, bucket])
        // The reason it matters: the offered S3 session carries no SSH block,
        // so a jump pointing at it has no host to dial.
        #expect(bucket.ssh == nil)
    }
}
