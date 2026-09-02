import Foundation
import Testing

/// Generates a runtime key and installs the public key in the container.
/// `type`/`bits` default to the original M3b ed25519 shape; M10d/T2
/// reuses this for RSA (`-t rsa -b 2048`) so the gated agent tests share
/// the exact same docker-exec authorized_keys installation pattern.
/// `passphrase`, when non-nil, is passed to `ssh-keygen -N` so the
/// generated private key is encrypted (T4: the passphrase-protected
/// agent route).
///
/// Shared by `CitadelFileSystemIntegrationTests` and
/// `FileKeyTypeIntegrationTests` (counted 2026-09-02). It lived as a
/// private method on the first of those until the second needed the same
/// installation; the body is unchanged by the move.
///
/// A key generated here is authorized against the rig for as long as the
/// container lives — `authorized_keys` grows across runs, which the rig
/// accepts by design (see the note inside).
func makeInstalledKey(type: String = "ed25519", bits: Int? = nil, passphrase: String? = nil) throws -> (dir: URL, keyPath: String) {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("macscp-itest-key-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let keyURL = dir.appendingPathComponent("id_\(type)")

    do {
        let keygen = Process()
        keygen.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        var arguments = ["-t", type, "-f", keyURL.path(percentEncoded: false),
                         "-N", passphrase ?? "", "-q", "-C", "macscp-itest"]
        if let bits {
            arguments += ["-b", String(bits)]
        }
        keygen.arguments = arguments
        try keygen.run()
        keygen.waitUntilExit()
        #expect(keygen.terminationStatus == 0)

        let pubKey = try String(contentsOfFile: keyURL.path(percentEncoded: false) + ".pub",
                                encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Note: authorized_keys grows across runs on a long-lived container —
        // acceptable for the test rig.
        let install = Process()
        install.executableURL = URL(fileURLWithPath: "/usr/local/bin/docker")
        install.arguments = [
            "exec", "macscp-test-sshd", "sh", "-c",
            "mkdir -p /config/.ssh && echo '\(pubKey)' >> /config/.ssh/authorized_keys"
                + " && chmod 700 /config/.ssh && chmod 600 /config/.ssh/authorized_keys"
                + " && chown -R 1000:1000 /config/.ssh",
        ]
        try install.run()
        install.waitUntilExit()
        #expect(install.terminationStatus == 0)

        return (dir, keyURL.path(percentEncoded: false))
    } catch {
        try? FileManager.default.removeItem(at: dir)
        throw error
    }
}
