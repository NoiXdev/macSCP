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
    }

    /// The App refuses a jump set with `isEligible`, Core refuses it with
    /// `LoginResolver.resolveJump`'s own `kind` guard — two separate pieces of
    /// code answering one question. This holds them together: for every set,
    /// the predicate says exactly what the resolver does. Loosening either one
    /// alone turns this red, which is the point — an App that still offers to
    /// fill from a set the resolver will refuse (or worse, an App that fills
    /// from one the resolver would have stopped) is how a WebDAV password
    /// reached an SSH bastion in the first place.
    @Test func theResolverRefusesExactlyTheSetsThePredicateRejects() throws {
        let sets = [
            LoginSet(name: "Bastion", username: "jumper"),
            LoginSet(name: "Key", username: "u", authKind: .privateKey, keyPath: "/k"),
            LoginSet(name: "Agent", username: "u", authKind: .agent),
            LoginSet(name: "Share", username: "dav", kind: .webdav),
            LoginSet(name: "Bucket", username: "", kind: .s3, accessKeyID: "AKIAEXAMPLE"),
        ]
        let secrets = InMemorySecretStore()

        for set in sets {
            let spec = StoredSession.JumpSpec(
                host: "bastion.example.com", username: "unused", loginSetID: set.id)
            var resolverRefused = false
            do {
                _ = try LoginResolver.resolveJump(spec: spec, sets: [set], secrets: secrets)
            } catch LoginResolveError.jumpSetNotSSH {
                resolverRefused = true
            }
            #expect(
                resolverRefused == !JumpLoginSetEligibility.isEligible(set),
                "\(set.kind.rawValue)/\(set.authKind.rawValue): resolver refused \(resolverRefused), predicate eligible \(JumpLoginSetEligibility.isEligible(set))")
        }
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
