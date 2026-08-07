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
}
