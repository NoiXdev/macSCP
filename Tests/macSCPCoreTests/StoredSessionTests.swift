import Foundation
import Testing
@testable import macSCPCore

@Suite("StoredSession kind/s3 (M12)")
struct StoredSessionTests {
    @Test func legacyJSONWithoutKindDecodesAsSSH() throws {
        let legacy = """
        {"id":"\(UUID().uuidString)","name":"old","host":"h","port":22,"username":"u","authKind":"password"}
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(StoredSession.self, from: legacy)
        #expect(s.kind == .ssh)
        #expect(s.s3 == nil)
    }

    @Test func s3SessionRoundtrips() throws {
        let s = s3Session(
            name: "obj",
            config: StoredS3Config(accessKeyID: "AK", region: "us-east-1",
                endpoint: "https://s3.amazonaws.com", bucket: "b", usePathStyle: false))
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(StoredSession.self, from: data)
        #expect(back.kind == .s3)
        #expect(back.s3 == s.s3)
        // The persisted session JSON never contains the secret access key.
        #expect(!String(data: data, encoding: .utf8)!.lowercased().contains("secretaccesskey"))
    }
}
