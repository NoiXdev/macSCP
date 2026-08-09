import Foundation
import Testing
@testable import macSCPCore

@Suite("JumpLoginSetEligibility")
struct JumpLoginSetEligibilityTests {
    /// The jump block's login-set picker used to list every set regardless of
    /// `kind`, so a WebDAV or S3 login could be bound to a bastion. Only SSH
    /// sets are offered now — the same rule `JumpSessionEligibility` applies
    /// to saved connections, for the same reason.
    @Test func onlySSHSetsAreOfferedForAJump() throws {
        let ssh = LoginSet(name: "Bastion", username: "jumper")
        let share = LoginSet(name: "Share", username: "dav", kind: .webdav)
        let bucket = LoginSet(
            name: "Bucket", username: "", kind: .s3, accessKeyID: "AKIAEXAMPLE")

        let eligible = JumpLoginSetEligibility.eligible(in: [ssh, share, bucket])

        #expect(eligible == [ssh])
    }

    /// Every SSH auth kind stays offered: the filter is about the PROTOCOL a
    /// set's credentials are for, not about what they contain. An agent set
    /// holds no secret at all and is still a perfectly good bastion login.
    @Test func everySSHAuthKindStaysOffered() throws {
        let password = LoginSet(name: "Pass", username: "u")
        let key = LoginSet(name: "Key", username: "u", authKind: .privateKey, keyPath: "/k")
        let agent = LoginSet(name: "Agent", username: "u", authKind: .agent)

        let eligible = JumpLoginSetEligibility.eligible(in: [password, key, agent])

        #expect(eligible == [password, key, agent])
    }
}
