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

    /// `tags` is a `var`, so any code holding a `StoredSession` can write it
    /// without going through the initializer or the decoder. The property
    /// itself owns the rule now, so a plain assignment normalizes — a write
    /// site cannot forget, which is what three separate write sites each had
    /// to remember by hand (one of them found forgetting it, live, in P3a/T3).
    @Test func aDirectAssignmentNormalizesBecauseThePropertyOwnsTheRule() {
        var session = StoredSession(name: "box")
        session.tags = ["  docker ", "docker", "", "   ", "web"]
        #expect(session.tags == ["docker", "web"])
    }

    /// The same rule for an in-place mutation, which no explicit
    /// `TagList.normalized(...)` at a write site ever covered: appending is
    /// a write, so it normalizes too.
    @Test func mutatingTheTagListInPlaceNormalizesAsWell() {
        var session = StoredSession(name: "box", tags: ["docker"])
        session.tags.append(" docker ")
        #expect(session.tags == ["docker"])
    }

    /// Property observers do NOT run during initialization, so the
    /// initializer's own `TagList.normalized` call is not redundant with the
    /// observer — deleting it would let a constructed session carry an
    /// untrimmed duplicate that no later write ever cleans up.
    @Test func theInitializerNormalizesOnItsOwnBecauseObserversSkipInitialization() {
        #expect(StoredSession(name: "box", tags: ["  docker ", "docker"]).tags == ["docker"])
    }

    @Test func tagsSurviveAnEncodeDecodeRoundTrip() throws {
        let original = StoredSession(name: "box", tags: ["docker", "web"])
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(StoredSession.self, from: data)
        #expect(restored.tags == ["docker", "web"])
    }
}
