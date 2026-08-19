import Foundation
import Testing

@testable import macSCPCore

@Suite("SnippetMenuModel")
struct SnippetMenuModelTests {
    /// A snippet carrying two tags is reachable under both — that is what a tag
    /// is for. The duplicate entry is deliberate, not an oversight.
    @Test func aSnippetWithTwoTagsAppearsUnderBoth() throws {
        let snippet = Snippet(name: "n", command: "c", tags: ["a", "b"])

        let model = SnippetMenuModel.build(
            snippets: [snippet], isConnected: true, supportsShell: true)

        #expect(model.groups.map(\.tag) == ["a", "b"])
        #expect(model.groups.allSatisfy { $0.snippets == [snippet] })
    }

    /// Untagged snippets are last, never dropped — otherwise the ones nobody
    /// has sorted yet become unreachable, which is the state every new snippet
    /// starts in.
    @Test func untaggedSnippetsComeLastAndAreNeverDropped() throws {
        let tagged = Snippet(name: "t", command: "c", tags: ["a"])
        let untagged = Snippet(name: "u", command: "c")

        let model = SnippetMenuModel.build(
            snippets: [untagged, tagged], isConnected: true, supportsShell: true)

        #expect(model.groups.map(\.tag) == ["a", nil])
        #expect(model.groups.last?.snippets == [untagged])
    }

    /// Order inside a group is store order, not alphabetical — the user's own
    /// arrangement survives.
    @Test func orderInsideAGroupIsStoreOrder() throws {
        let second = Snippet(name: "zeta", command: "c", tags: ["a"])
        let first = Snippet(name: "alpha", command: "c", tags: ["a"])

        let model = SnippetMenuModel.build(
            snippets: [second, first], isConnected: true, supportsShell: true)

        #expect(model.groups.first?.snippets.map(\.name) == ["zeta", "alpha"])
    }

    /// Without a connection there is no shell to send to. The entries stay
    /// visible — a disabled entry teaches where the feature lives; a missing
    /// one teaches nothing — but they carry the reason.
    @Test func aDisconnectedTabDisablesTheEntriesWithoutHidingThem() throws {
        let snippet = Snippet(name: "n", command: "c")

        let model = SnippetMenuModel.build(
            snippets: [snippet], isConnected: false, supportsShell: true)

        #expect(model.disabledReason == .notConnected)
        #expect(model.groups.isEmpty == false)
    }

    /// S3 and WebDAV have no shell at all. That is a different reason from "not
    /// connected yet" and the two must not collapse — the first is permanent
    /// for this backend, the second goes away when the user connects.
    @Test func aBackendWithoutAShellIsADistinctReason() throws {
        let snippet = Snippet(name: "n", command: "c")

        let model = SnippetMenuModel.build(
            snippets: [snippet], isConnected: true, supportsShell: false)

        #expect(model.disabledReason == .backendHasNoShell)
    }

    /// The brief's own test above for `backendHasNoShell` never asserts that
    /// the entries stay visible (unlike the disconnected case, which does) —
    /// so a `build` that returned an empty menu whenever `supportsShell` was
    /// `false` would pass it unnoticed. This closes that gap.
    @Test func aBackendWithoutAShellAlsoKeepsTheEntriesVisible() throws {
        let snippet = Snippet(name: "n", command: "c")

        let model = SnippetMenuModel.build(
            snippets: [snippet], isConnected: true, supportsShell: false)

        #expect(model.groups.isEmpty == false)
    }

    /// When both a shell-less backend and a missing connection apply at once,
    /// `backendHasNoShell` wins: it is a permanent property of the backend
    /// that connecting can never fix, while `notConnected` implies the
    /// feature starts working once the user connects — which would be false
    /// here. Reporting `notConnected` would promise a fix that does not
    /// exist.
    @Test func aShellLessBackendTakesPrecedenceOverNotConnected() throws {
        let snippet = Snippet(name: "n", command: "c")

        let model = SnippetMenuModel.build(
            snippets: [snippet], isConnected: false, supportsShell: false)

        #expect(model.disabledReason == .backendHasNoShell)
    }

    /// No snippets means no groups — the surfaces show their own empty hint
    /// rather than an empty group box.
    @Test func noSnippetsMeansNoGroups() {
        let model = SnippetMenuModel.build(
            snippets: [], isConnected: true, supportsShell: true)

        #expect(model.isEmpty)
        #expect(model.disabledReason == nil)
    }

    /// Tags supplied out of alphabetical order still come back sorted. Every
    /// test above happens to supply tags already in sorted order (`["a",
    /// "b"]`, or a single tag), so none of them would notice `.sorted(by:)`
    /// being dropped from `build` entirely. This one requires it.
    @Test func tagsOutOfOrderComeBackSorted() throws {
        let snippet = Snippet(name: "n", command: "c", tags: ["zebra", "apple", "mango"])

        let model = SnippetMenuModel.build(
            snippets: [snippet], isConnected: true, supportsShell: true)

        #expect(model.groups.map(\.tag) == ["apple", "mango", "zebra"])
    }

    /// Tags differing only in case sort as neighbours, not by code point.
    /// `Snippet.tags` deliberately keeps case (`Docker` and `docker` are two
    /// distinct tags), and the sort's whole point is a case-insensitive
    /// comparator that lands them next to each other anyway. Under a plain,
    /// case-sensitive `sorted()`, uppercase sorts before all lowercase, so
    /// "Docker" would jump ahead of "apple" instead of landing beside
    /// "docker".
    @Test func differentlyCasedTagsSortAsNeighbours() throws {
        let snippet = Snippet(name: "n", command: "c", tags: ["apple", "Docker", "docker"])

        let model = SnippetMenuModel.build(
            snippets: [snippet], isConnected: true, supportsShell: true)

        #expect(model.groups.map(\.tag) == ["apple", "Docker", "docker"])
    }

    /// The doc comment's "ties broken by first appearance across snippets"
    /// clause names multiple snippets specifically — the case-neighbour test
    /// above only exercises one snippet, where the tie order trivially
    /// matches the given tags array. This pins the tie-break across two
    /// snippets: `docker` appears first (on the first snippet), so it sorts
    /// before `Docker` despite neither string being alphabetically "first"
    /// in a way that would matter to a comparator that ignored insertion
    /// order for ties.
    @Test func tiedTagsAcrossSnippetsBreakByFirstAppearance() throws {
        let first = Snippet(name: "a", command: "c", tags: ["docker"])
        let second = Snippet(name: "b", command: "c", tags: ["Docker"])

        let model = SnippetMenuModel.build(
            snippets: [first, second], isConnected: true, supportsShell: true)

        #expect(model.groups.map(\.tag) == ["docker", "Docker"])
    }
}
