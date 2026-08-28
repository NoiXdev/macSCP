import Foundation
import Testing
@testable import macSCPCore

@Suite("Certificate decider")
struct CertificateDeciderTests {
    private func candidate(
        host: String = "nas.example.com", derBase64: String = "QUJD"
    ) -> ServerCertificateCandidate {
        ServerCertificateCandidate(
            host: host, port: 443, derBase64: derBase64,
            subject: "CN=nas.example.com", issuer: "CN=nas.example.com", notAfter: nil)
    }

    @Test func askingForwardsTheAnswerItWasGiven() async {
        let yes = WebDAVSessionDelegate.CertificateDecider.asking { _ in true }
        let no = WebDAVSessionDelegate.CertificateDecider.asking { _ in false }
        #expect(await yes(candidate()) == true)
        #expect(await no(candidate()) == false)
    }

    /// The fingerprint is what a person actually compares against a NAS
    /// admin page, and it is DERIVED from the DER bytes rather than passed
    /// in — so a decider that received a candidate but not its bytes would
    /// be asking about a certificate it cannot name.
    @Test func askingSeesTheFingerprintItIsAskedToConfirm() async {
        let subject = candidate()
        let seen = TestBox<String?>(nil)
        let decider = WebDAVSessionDelegate.CertificateDecider.asking { candidate in
            seen.value = candidate.fingerprintSHA256
            return false
        }
        _ = await decider(subject)
        #expect(seen.value == subject.fingerprintSHA256)
        #expect(seen.value != "SHA256:?")
    }

    /// What the command line does for want of an interactive prompt: every
    /// unknown certificate is refused, whichever one it is. Two candidates
    /// that differ in host AND in bytes, because a refusal that happened to
    /// depend on either would still pass a single-candidate check.
    @Test func refusingAnswersNoForEveryCertificate() async {
        let refusing = WebDAVSessionDelegate.CertificateDecider.refusing
        #expect(await refusing(candidate()) == false)
        #expect(await refusing(candidate(host: "other.example.com", derBase64: "WFla")) == false)
    }
}
