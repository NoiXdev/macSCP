import Foundation
import Testing
@testable import macSCPCore

@Suite("ConnectionKind & ConnectionConfig")
struct ConnectionKindTests {
    @Test func kindRawValues() {
        #expect(ConnectionKind.ssh.rawValue == "ssh")
        #expect(ConnectionKind.s3.rawValue == "s3")
        #expect(ConnectionKind.webdav.rawValue == "webdav")
        // Pinned count (M21/T8 added `.webdav`): a change here should be a
        // deliberate decision, not a silent side effect of adding a case.
        #expect(ConnectionKind.allCases.count == 3)
    }

    @Test func configReportsKind() {
        let ssh = ConnectionConfig.ssh(try! SSHConnectionConfig(host: "h", port: 22, username: "u", auth: .password("p")))
        let s3 = ConnectionConfig.s3(S3ConnectionConfig(
            accessKeyID: "AK", secretAccessKey: "SK", region: "us-east-1",
            endpoint: "https://s3.amazonaws.com", bucket: "b", usePathStyle: false, sessionToken: nil))
        #expect(ssh.kind == .ssh)
        #expect(s3.kind == .s3)
    }

    // The PERSISTED S3 shape is secret-free and Codable.
    @Test func storedS3ConfigRoundtripsCodableWithoutSecret() throws {
        let cfg = StoredS3Config(accessKeyID: "AK", region: "eu-central-1",
            endpoint: "https://fsn1.your-objectstorage.com", bucket: "b", usePathStyle: true)
        let data = try JSONEncoder().encode(cfg)
        let back = try JSONDecoder().decode(StoredS3Config.self, from: data)
        #expect(back == cfg)
        // Belt-and-braces: the encoded JSON contains no secret-ish key.
        let json = String(data: data, encoding: .utf8)!
        #expect(!json.lowercased().contains("secret"))
    }
}
