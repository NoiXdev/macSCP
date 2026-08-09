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

    /// The single-set question the picker's filter is built from, and the one
    /// the App's fill-before-submit path asks about the set it is ABOUT to
    /// copy credentials out of (`ContentView.resolveSelectedJumpLoginSet`,
    /// M28 final review): a picker filter shapes what can be chosen next,
    /// while a binding already on disk arrives at the fill unfiltered.
    @Test func isEligibleAnswersTheSameQuestionAsTheFilter() throws {
        let ssh = LoginSet(name: "Bastion", username: "jumper")
        let share = LoginSet(name: "Share", username: "dav", kind: .webdav)
        let bucket = LoginSet(
            name: "Bucket", username: "", kind: .s3, accessKeyID: "AKIAEXAMPLE")

        #expect(JumpLoginSetEligibility.isEligible(ssh))
        #expect(JumpLoginSetEligibility.isEligible(share) == false)
        #expect(JumpLoginSetEligibility.isEligible(bucket) == false)
        // Not two rules that happen to agree today: the filter is defined in
        // terms of this predicate.
        let sets = [ssh, share, bucket]
        #expect(JumpLoginSetEligibility.eligible(in: sets) == sets.filter(JumpLoginSetEligibility.isEligible))
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
