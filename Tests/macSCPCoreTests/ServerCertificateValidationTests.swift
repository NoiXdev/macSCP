import Foundation
import Testing
@testable import macSCPCore

@Suite("ServerCertificateValidation")
struct ServerCertificateValidationTests {
    private func candidate(_ der: String) -> ServerCertificateCandidate {
        ServerCertificateCandidate(
            host: "nas.local", port: 5006, derBase64: der,
            subject: "CN=nas.local", issuer: "CN=nas.local", notAfter: nil)
    }

    private func trusted(_ der: String) -> TrustedCertificate {
        TrustedCertificate(
            host: "nas.local", port: 5006, derBase64: der,
            subject: "CN=nas.local", issuer: "CN=nas.local", notAfter: nil)
    }

    @Test func unknownCertificateAsksTheUser() {
        #expect(ServerCertificateValidation.evaluate(
            candidate: candidate("QUJD"), known: nil) == .askUser)
    }

    @Test func knownIdenticalCertificateIsAccepted() {
        #expect(ServerCertificateValidation.evaluate(
            candidate: candidate("QUJD"), known: trusted("QUJD")) == .accept)
    }

    /// The invariant. A changed certificate on a remembered host is a hard
    /// stop: the outcome carries no path that reaches the user decider.
    @Test func knownDifferentCertificateIsAMismatch() {
        let outcome = ServerCertificateValidation.evaluate(
            candidate: candidate("WFla"), known: trusted("QUJD"))
        guard case .mismatch(let expected) = outcome else {
            Issue.record("expected .mismatch, got \(outcome)")
            return
        }
        #expect(expected == trusted("QUJD").fingerprintSHA256)
        #expect(outcome != .askUser)
        #expect(outcome != .accept)
    }

    @Test func fingerprintIsStableAndPrefixed() {
        #expect(candidate("QUJD").fingerprintSHA256.hasPrefix("SHA256:"))
        #expect(candidate("QUJD").fingerprintSHA256 == trusted("QUJD").fingerprintSHA256)
    }
}
