import Foundation
import Testing
@testable import macSCPCore

@Suite("StoredSession compatibility")
struct StoredSessionCompatTests {
    /// Decoded through `LegacyStoredSession`, not `StoredSession` (M23/T8):
    /// SSH's fields left the top level, so the pre-M23 flat shape below is no
    /// longer something `StoredSession` can read at all. Retargeting rather
    /// than deleting keeps the question the test was asking — does a file this
    /// old still load — and points it at the type that now answers it, the
    /// same one `SessionStore.migrateFromLegacy` uses.
    ///
    /// Asserting on `upgraded()` rather than the raw decode is deliberate: a
    /// decoder that parsed the JSON but dropped it on the floor during the
    /// upgrade would still be a lost connection.
    @Test func decodesM3aJsonWithoutKeyPath() throws {
        let json = """
        [{"authKind":"password","host":"example.com","id":"11111111-2222-3333-4444-555555555555",
          "name":"alt","port":22,"username":"tim"}]
        """
        let sessions = try JSONDecoder()
            .decode([LegacyStoredSession].self, from: Data(json.utf8))
            .map { $0.upgraded() }
        // No `kind` key at all: the pre-M12 shape, which must land as `.ssh`
        // and therefore WITH an SSH block.
        #expect(sessions.first?.kind == .ssh)
        #expect(sessions.first?.ssh?.host == "example.com")
        #expect(sessions.first?.ssh?.username == "tim")
        #expect(sessions.first?.ssh?.keyPath == nil)
        #expect(sessions.first?.ssh?.authKind == .password)
    }

    @Test func privateKeySessionRoundtrips() throws {
        let session = sshSession(
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
        let session = sshSession(
            name: "agent-server", host: "example.com", username: "tim", authKind: .agent)
        let data = try JSONEncoder().encode([session])
        let decoded = try JSONDecoder().decode([StoredSession].self, from: data)
        #expect(decoded.first == session)
        #expect(decoded.first?.keyPath == nil)
    }

    /// M11a: a `jump` object written before `sessionID` existed must still
    /// decode (no custom decoder, same pattern as `groupID`/`loginSetID`),
    /// with the other jump fields intact.
    ///
    /// Retargeted to `LegacyStoredSession` by M23/T8 for the same reason as
    /// `decodesM3aJsonWithoutKeyPath`, and the assertions now read through
    /// `ssh` because that is where a hop lives.
    @Test func legacyJumpJSONDecodesNilSessionID() throws {
        let json = """
        [{"authKind":"password","host":"example.com","id":"11111111-2222-3333-4444-555555555555",
          "name":"web","port":22,"username":"tim",
          "jump":{"host":"bastion.example.com","port":22,"username":"jumper",
                  "authKind":"password","secretID":"22222222-3333-4444-5555-666666666666"}}]
        """
        let sessions = try JSONDecoder()
            .decode([LegacyStoredSession].self, from: Data(json.utf8))
            .map { $0.upgraded() }
        let jump = try #require(sessions.first?.ssh?.jump)
        #expect(jump.sessionID == nil)
        #expect(jump.host == "bastion.example.com")
        #expect(jump.username == "jumper")
        #expect(jump.secretID == UUID(uuidString: "22222222-3333-4444-5555-666666666666"))
    }
}
