import Foundation
import Testing
@testable import macSCPCore

/// `GroupTagCompleter` — the pure decision logic behind the CLI's
/// `--group` and `--tag` shell VALUE completion, same completer family as
/// `SessionNameCompleter` (see `SessionNameCompleterTests`' doc comment for
/// why this lives in Core and is tested directly, no temp store, no
/// subprocess, no environment variable — except for the two
/// store-opening-convenience cases below, which need one).
@Suite("Group/tag completer")
struct GroupTagCompleterTests {
    // MARK: - `completeGroups`/`completeTags` — pure, catalog-driven

    @Test func completeGroupsListsEveryGroupNameSortedAndDeduplicated() {
        let work = StoredGroup(name: "Work")
        let prod = StoredGroup(name: "Prod", parentID: work.id)
        let catalog = SessionCatalog(
            sessions: [
                sshSession(name: "a", groupID: prod.id),
                sshSession(name: "b", groupID: work.id),
            ],
            groups: [work, prod])

        #expect(GroupTagCompleter.completeGroups(prefix: "", in: catalog) == ["Prod", "Work"])
    }

    /// A group with no session in it still completes — `--group` filters
    /// by ancestry, and an empty group is a legitimate (if useless) filter
    /// value, not an error.
    @Test func anEmptyGroupStillCompletes() {
        let empty = StoredGroup(name: "Empty")
        let catalog = SessionCatalog(sessions: [], groups: [empty])

        #expect(GroupTagCompleter.completeGroups(prefix: "", in: catalog) == ["Empty"])
    }

    @Test func completeGroupsFiltersByPrefix() {
        let work = StoredGroup(name: "Work")
        let webOps = StoredGroup(name: "Web-Ops")
        let catalog = SessionCatalog(sessions: [], groups: [work, webOps])

        #expect(GroupTagCompleter.completeGroups(prefix: "We", in: catalog) == ["Web-Ops"])
        #expect(GroupTagCompleter.completeGroups(prefix: "Wo", in: catalog) == ["Work"])
        #expect(GroupTagCompleter.completeGroups(prefix: "W", in: catalog) == ["Web-Ops", "Work"])
    }

    @Test func completeTagsListsEveryTagInUseSortedAndDeduplicated() {
        var prod = sshSession(name: "prod")
        prod.tags = ["prod", "db"]
        var staging = sshSession(name: "staging")
        staging.tags = ["staging", "db"]
        let catalog = SessionCatalog(sessions: [prod, staging], groups: [])

        #expect(GroupTagCompleter.completeTags(prefix: "", in: catalog) == ["db", "prod", "staging"])
    }

    @Test func completeTagsFiltersByPrefix() {
        var session = sshSession(name: "a")
        session.tags = ["prod", "production-adjacent", "staging"]
        let catalog = SessionCatalog(sessions: [session], groups: [])

        #expect(GroupTagCompleter.completeTags(prefix: "prod", in: catalog)
            == ["prod", "production-adjacent"])
    }

    /// `swift-argument-parser`'s generated BASH script hands a `.custom`
    /// completion's answers to `compgen -W`, which splits unquoted on
    /// whitespace — a group like "Work / Prod" would complete as several
    /// separate words there, offering a value the user never typed. A name
    /// WITH whitespace is therefore absent from completion; a name WITHOUT
    /// any is present beside it — the positive is what proves the filter
    /// is actually whitespace-scoped rather than one that happens to
    /// exclude everything.
    @Test func aGroupNameContainingWhitespaceIsAbsentAPlainOneIsPresent() {
        let spaced = StoredGroup(name: "Work / Prod")
        let plain = StoredGroup(name: "WorkProd")
        let catalog = SessionCatalog(sessions: [], groups: [spaced, plain])

        let completed = GroupTagCompleter.completeGroups(prefix: "", in: catalog)
        #expect(!completed.contains("Work / Prod"))
        #expect(completed.contains("WorkProd"))
    }

    /// Same property, for tags — a tag such as "needs review" would
    /// complete as "needs" and "review" under bash's unquoted
    /// `compgen -W` word split.
    @Test func aTagContainingWhitespaceIsAbsentAPlainOneIsPresent() {
        var session = sshSession(name: "a")
        session.tags = ["needs review", "reviewed"]
        let catalog = SessionCatalog(sessions: [session], groups: [])

        let completed = GroupTagCompleter.completeTags(prefix: "", in: catalog)
        #expect(!completed.contains("needs review"))
        #expect(completed.contains("reviewed"))
    }

    /// A newline is whitespace too, and a tag or group name is free text
    /// (`StoredSession.tags`/`StoredGroup.name` carry no character
    /// restriction) — the same filter must catch it, not just the space
    /// character the two tests above happen to use.
    @Test func aNameContainingANewlineIsAbsent() {
        let newlineGroup = StoredGroup(name: "Work\nProd")
        let catalog = SessionCatalog(sessions: [], groups: [newlineGroup])

        #expect(GroupTagCompleter.completeGroups(prefix: "", in: catalog).isEmpty)
    }

    @Test func aSessionWithNoTagsContributesNothing() {
        let catalog = SessionCatalog(sessions: [sshSession(name: "a")], groups: [])

        #expect(GroupTagCompleter.completeTags(prefix: "", in: catalog) == [])
    }

    // MARK: - `completeGroups`/`completeTags(prefix:storeDirectory:)` — the
    // store-opening convenience

    private func withTempStore(
        _ body: (URL, SessionStore) throws -> Void
    ) throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(
                "macscp-cli-group-tag-completer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory, SessionStore(directory: directory))
    }

    @Test func theGroupConvenienceOpensTheStoreAtTheGivenDirectory() throws {
        try withTempStore { directory, store in
            let work = StoredGroup(name: "Work")
            try store.upsertGroup(work)
            try store.upsert(sshSession(name: "a", groupID: work.id))

            #expect(GroupTagCompleter.completeGroups(prefix: "", storeDirectory: directory)
                == ["Work"])
        }
    }

    @Test func theTagConvenienceOpensTheStoreAtTheGivenDirectory() throws {
        try withTempStore { directory, store in
            var session = sshSession(name: "a")
            session.tags = ["prod"]
            try store.upsert(session)

            #expect(GroupTagCompleter.completeTags(prefix: "", storeDirectory: directory)
                == ["prod"])
        }
    }

    @Test func anUnreadableStoreAnswersEmptyRatherThanThrowingForGroups() throws {
        try withTempStore { directory, store in
            let work = StoredGroup(name: "Work")
            try store.upsertGroup(work)
            try store.upsert(sshSession(name: "a", groupID: work.id))
            let fileURL = directory.appendingPathComponent("sessions-v2.json")
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o000], ofItemAtPath: fileURL.path(percentEncoded: false))
            defer {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o644], ofItemAtPath: fileURL.path(percentEncoded: false))
            }

            #expect(GroupTagCompleter.completeGroups(prefix: "", storeDirectory: directory) == [])
            #expect(GroupTagCompleter.completeTags(prefix: "", storeDirectory: directory) == [])
        }
    }
}
