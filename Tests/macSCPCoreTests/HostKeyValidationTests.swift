import Foundation
import Testing
@testable import macSCPCore

@Suite("HostKeyValidation")
struct HostKeyValidationTests {
    private let candidate = HostKeyCandidate(
        host: "example.com", port: 22,
        keyType: "ssh-ed25519", publicKeyBase64: "QUJDREVG")

    @Test func unknownHostAsksUser() {
        #expect(HostKeyValidation.evaluate(candidate: candidate, known: nil) == .askUser)
    }

    @Test func knownIdenticalKeyAccepts() {
        let known = KnownHostKey(host: "example.com", port: 22,
                                 keyType: "ssh-ed25519", publicKeyBase64: "QUJDREVG")
        #expect(HostKeyValidation.evaluate(candidate: candidate, known: known) == .accept)
    }

    @Test func knownDifferentKeyIsMismatch() {
        let known = KnownHostKey(host: "example.com", port: 22,
                                 keyType: "ssh-ed25519", publicKeyBase64: "TEVFUlpFSUxF")
        #expect(HostKeyValidation.evaluate(candidate: candidate, known: known)
            == .mismatch(expected: known.fingerprintSHA256))
    }
}
