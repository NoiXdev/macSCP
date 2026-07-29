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

    /// M10d: `.agent` carries no secret and no key path — the session only
    /// remembers the username, exactly like a legacy password session would,
    /// but with the third raw value.
    @Test func agentSessionRoundtrips() throws {
        let session = StoredSession(
            name: "agent-server", host: "example.com", username: "tim", authKind: .agent)
        let data = try JSONEncoder().encode([session])
        let decoded = try JSONDecoder().decode([StoredSession].self, from: data)
        #expect(decoded.first == session)
        #expect(decoded.first?.keyPath == nil)
    }

    /// M11a: a `jump` object written before `sessionID` existed must still
    /// decode (no custom decoder, same pattern as `groupID`/`loginSetID`),
    /// with the other jump fields intact.
    @Test func legacyJumpJSONDecodesNilSessionID() throws {
        let json = """
        [{"authKind":"password","host":"example.com","id":"11111111-2222-3333-4444-555555555555",
          "name":"web","port":22,"username":"tim",
          "jump":{"host":"bastion.example.com","port":22,"username":"jumper",
                  "authKind":"password","secretID":"22222222-3333-4444-5555-666666666666"}}]
        """
        let sessions = try JSONDecoder().decode([StoredSession].self, from: Data(json.utf8))
        #expect(sessions.first?.jump?.sessionID == nil)
        #expect(sessions.first?.jump?.host == "bastion.example.com")
        #expect(sessions.first?.jump?.username == "jumper")
    }
}
