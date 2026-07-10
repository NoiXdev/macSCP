import Foundation
import Testing
@testable import macSCPCore

@Suite("StoredSession compatibility")
struct StoredSessionCompatTests {
    @Test func decodesM3aJsonWithoutKeyPath() throws {
        let json = """
        [{"authKind":"password","host":"example.com","id":"11111111-2222-3333-4444-555555555555",
          "name":"alt","port":22,"username":"tim"}]
        """
        let sessions = try JSONDecoder().decode([StoredSession].self, from: Data(json.utf8))
        #expect(sessions.first?.keyPath == nil)
        #expect(sessions.first?.authKind == .password)
    }

    @Test func privateKeySessionRoundtrips() throws {
        let session = StoredSession(
            name: "key-server", host: "example.com", username: "tim",
            authKind: .privateKey, keyPath: "~/.ssh/id_ed25519")
        let data = try JSONEncoder().encode([session])
        let decoded = try JSONDecoder().decode([StoredSession].self, from: data)
        #expect(decoded.first == session)
    }
}
