import Foundation
import Testing
@testable import macSCPCore

struct StoredSessionTagsTests {
    @Test func aStoredSessionWithoutTheTagsKeyDecodesAsUntagged() throws {
        let json = """
        {"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","name":"box","kind":"ssh"}
        """
        let session = try JSONDecoder().decode(StoredSession.self, from: Data(json.utf8))
        #expect(session.tags.isEmpty)
    }

    @Test func decodingNormalizesTagsSoAHandEditedFileCannotSmuggleDuplicates() throws {
        let json = """
        {"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","name":"box","kind":"ssh",
         "tags":["  docker ","docker",""]}
        """
        let session = try JSONDecoder().decode(StoredSession.self, from: Data(json.utf8))
        #expect(session.tags == ["docker"])
    }

    @Test func tagsSurviveAnEncodeDecodeRoundTrip() throws {
        let original = StoredSession(name: "box", tags: ["docker", "web"])
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(StoredSession.self, from: data)
        #expect(restored.tags == ["docker", "web"])
    }
}
