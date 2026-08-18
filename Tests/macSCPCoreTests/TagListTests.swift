import Testing
@testable import macSCPCore

struct TagListTests {
    @Test func normalizationTrimsDropsEmptiesAndDeduplicatesKeepingOrder() {
        #expect(TagList.normalized(["  docker ", "", "web", "docker", "   "])
                == ["docker", "web"])
    }

    @Test func normalizationKeepsCaseSoTwoSpellingsStayTwoTags() {
        #expect(TagList.normalized(["Docker", "docker"]) == ["Docker", "docker"])
    }

    @Test func normalizationIsIdempotent() {
        let once = TagList.normalized([" a ", "b", "a"])
        #expect(TagList.normalized(once) == once)
    }
}
