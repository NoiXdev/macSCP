import Foundation
import Testing
@testable import macSCPCore

@Suite("Host key decider")
struct HostKeyDeciderTests {
    private func candidate() -> HostKeyCandidate {
        HostKeyCandidate(
            host: "example.com", port: 22, keyType: "ssh-ed25519",
            publicKeyBase64: "QUJD")
    }

    @Test func askingForwardsTheAnswerItWasGiven() async {
        let yes = HostKeyDecider.asking { _ in true }
        let no = HostKeyDecider.asking { _ in false }
        #expect(await yes(candidate()) == true)
        #expect(await no(candidate()) == false)
    }

    @Test func askingSeesTheCandidateItIsAskedAbout() async {
        let seen = TestBox<String?>(nil)
        let decider = HostKeyDecider.asking { candidate in
            seen.value = candidate.host
            return false
        }
        _ = await decider(candidate())
        #expect(seen.value == "example.com")
    }

    @Test func refusingAnswersNoWithoutAsking() async {
        #expect(await HostKeyDecider.refusing(candidate()) == false)
    }
}
