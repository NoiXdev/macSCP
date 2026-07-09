import Foundation
import Testing
@testable import macSCPCore

/// Der Fingerprint-Vertrag wird gegen das System-ssh-keygen verifiziert —
/// Laufzeit-Keys, kein Schlüsselmaterial im Repo.
@Suite("HostKeyFingerprint")
struct HostKeyFingerprintTests {
    /// Erzeugt einen ed25519-Key und liefert (Base64-Blob, ssh-keygen-Fingerprint).
    private func makeReference() throws -> (blob: String, expected: String) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-fp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let keyURL = dir.appendingPathComponent("id_ed25519")

        let keygen = Process()
        keygen.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        keygen.arguments = ["-t", "ed25519", "-f", keyURL.path(percentEncoded: false),
                            "-N", "", "-q", "-C", "fp-test"]
        try keygen.run(); keygen.waitUntilExit()
        #expect(keygen.terminationStatus == 0)

        let pubLine = try String(
            contentsOfFile: keyURL.path(percentEncoded: false) + ".pub", encoding: .utf8)
        let blob = pubLine.split(separator: " ")[1]

        let lf = Process()
        let pipe = Pipe()
        lf.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        lf.arguments = ["-lf", keyURL.path(percentEncoded: false) + ".pub"]
        lf.standardOutput = pipe
        try lf.run(); lf.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                         encoding: .utf8) ?? ""
        // Format: "256 SHA256:xxxx fp-test (ED25519)"
        let expected = out.split(separator: " ")
            .first { $0.hasPrefix("SHA256:") }.map(String.init) ?? ""
        return (String(blob), expected)
    }

    @Test func matchesSshKeygenFingerprint() throws {
        let (blob, expected) = try makeReference()
        #expect(!expected.isEmpty)
        #expect(HostKeyFingerprint.sha256(ofKeyBlobBase64: blob) == expected)
    }

    @Test func invalidBase64YieldsNil() {
        #expect(HostKeyFingerprint.sha256(ofKeyBlobBase64: "kein base64 !!!") == nil)
    }

    @Test func fingerprintHasNoPadding() throws {
        let (blob, _) = try makeReference()
        let fp = HostKeyFingerprint.sha256(ofKeyBlobBase64: blob)
        #expect(fp?.hasSuffix("=") == false)
        #expect(fp?.hasPrefix("SHA256:") == true)
    }
}
