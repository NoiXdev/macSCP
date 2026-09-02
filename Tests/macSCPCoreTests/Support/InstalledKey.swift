import Foundation
import Testing

/// Generates a runtime key pair in a fresh temporary directory and hands back
/// both the private key's path and the public key's single line.
///
/// Extracted from `makeInstalledKey` on 2026-09-02, when
/// `makeSFTPGoInstalledKey` needed the same generation with a different
/// installation. The body is unchanged by the move; the two installers below
/// differ only in where they put the public key.
///
/// `passphrase`, when non-nil, is passed to `ssh-keygen -N` so the generated
/// private key is encrypted — one of the two documented places a test
/// passphrase is allowed to reach.
private func generateKeyPair(
    type: String, bits: Int?, passphrase: String?
) throws -> (dir: URL, keyPath: String, publicKey: String) {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("macscp-itest-key-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let keyURL = dir.appendingPathComponent("id_\(type)")

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

    return (dir, keyURL.path(percentEncoded: false), pubKey)
}

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
    let generated = try generateKeyPair(type: type, bits: bits, passphrase: passphrase)
    do {
        // Note: authorized_keys grows across runs on a long-lived container —
        // acceptable for the test rig.
        let install = Process()
        install.executableURL = URL(fileURLWithPath: "/usr/local/bin/docker")
        install.arguments = [
            "exec", "macscp-test-sshd", "sh", "-c",
            "mkdir -p /config/.ssh && echo '\(generated.publicKey)' >> /config/.ssh/authorized_keys"
                + " && chmod 700 /config/.ssh && chmod 600 /config/.ssh/authorized_keys"
                + " && chown -R 1000:1000 /config/.ssh",
        ]
        try install.run()
        install.waitUntilExit()
        #expect(install.terminationStatus == 0)

        return (generated.dir, generated.keyPath)
    } catch {
        try? FileManager.default.removeItem(at: generated.dir)
        throw error
    }
}

// MARK: - SFTPGo

/// The rig constants for the `sftpgo` service (see
/// `docker/test-server/README.md`). None of these is a real credential — they
/// exist only inside the test rig, exactly like MinIO's `macscpsecretkey`.
enum SFTPGoRig {
    /// The admin REST API, published on the host by `compose.yml`.
    static let apiBase = "http://127.0.0.1:18091/api/v2"
    static let adminUsername = "macscpadmin"
    static let adminPassword = "macscpsecretkey"
    /// The SFTP user `sftpgo-init` creates; its home is the same read-only
    /// `./seed` mount `sshd` serves, so `hello.txt` is there too.
    static let username = "testuser"
    /// The published SFTP port.
    static let sftpPort = 2240
    static let containerName = "macscp-test-sftpgo"
}

struct SFTPGoAPIError: Error, CustomStringConvertible {
    let detail: String
    var description: String { "SFTPGo admin API: \(detail)" }
}

/// The SFTPGo twin of `makeInstalledKey`: generates a runtime key and installs
/// the public key on the rig's SFTPGo `testuser`.
///
/// SFTPGo keeps a user's authorized keys in its data provider, not in a file,
/// so there is no `authorized_keys` to append to and no `docker exec` that
/// would do it — the supported way is the admin REST API. The flow is the one
/// SFTPGo documents: `GET /api/v2/token` with the admin's basic auth for a
/// bearer token, `GET /api/v2/users/<name>` for the current user object, then
/// `PUT` the same object back with the new key APPENDED to `public_keys`. The
/// append is what makes this behave like sshd's `authorized_keys`: keys from
/// earlier runs stay valid for as long as the container lives.
///
/// The whole exchange goes through `URLSession`'s async API — no process, no
/// `.wait()`, nothing that blocks a cooperative-pool thread.
func makeSFTPGoInstalledKey(
    type: String = "ed25519", bits: Int? = nil, passphrase: String? = nil
) async throws -> (dir: URL, keyPath: String) {
    let generated = try generateKeyPair(type: type, bits: bits, passphrase: passphrase)
    do {
        let token = try await sftpGoAdminToken()
        var user = try await sftpGoUser(token: token)
        var keys = (user["public_keys"] as? [String]) ?? []
        keys.append(generated.publicKey)
        user["public_keys"] = keys
        try await sftpGoPutUser(user, token: token)
        return (generated.dir, generated.keyPath)
    } catch {
        try? FileManager.default.removeItem(at: generated.dir)
        throw error
    }
}

/// A bearer token for the admin REST API, from the documented
/// `GET /api/v2/token` endpoint with HTTP basic auth.
private func sftpGoAdminToken() async throws -> String {
    var request = URLRequest(url: URL(string: "\(SFTPGoRig.apiBase)/token")!)
    let basic = Data("\(SFTPGoRig.adminUsername):\(SFTPGoRig.adminPassword)".utf8)
        .base64EncodedString()
    request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
        throw SFTPGoAPIError(detail: "GET /token returned \(statusDescription(response))")
    }
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let token = json["access_token"] as? String
    else {
        throw SFTPGoAPIError(detail: "GET /token carried no access_token")
    }
    return token
}

private func sftpGoUser(token: String) async throws -> [String: Any] {
    var request = URLRequest(
        url: URL(string: "\(SFTPGoRig.apiBase)/users/\(SFTPGoRig.username)")!)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
        throw SFTPGoAPIError(
            detail: "GET /users/\(SFTPGoRig.username) returned \(statusDescription(response))"
                + " — is `sftpgo-init` done? (docker logs macscp-test-sftpgo-init)")
    }
    guard let user = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw SFTPGoAPIError(detail: "GET /users/\(SFTPGoRig.username) was not a JSON object")
    }
    return user
}

private func sftpGoPutUser(_ user: [String: Any], token: String) async throws {
    var request = URLRequest(
        url: URL(string: "\(SFTPGoRig.apiBase)/users/\(SFTPGoRig.username)")!)
    request.httpMethod = "PUT"
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: user)
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
        throw SFTPGoAPIError(
            detail: "PUT /users/\(SFTPGoRig.username) returned \(statusDescription(response)):"
                + " \(String(decoding: data, as: UTF8.self))")
    }
}

private func statusDescription(_ response: URLResponse) -> String {
    (response as? HTTPURLResponse).map { "HTTP \($0.statusCode)" } ?? "a non-HTTP response"
}
