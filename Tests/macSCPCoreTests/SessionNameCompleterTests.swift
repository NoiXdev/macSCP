import Foundation
import Testing
@testable import macSCPCore

/// `SessionNameCompleter` — the pure decision logic behind the CLI's
/// `name:` shell completion. Lives in Core (moved here from `MacSCPCLI` in
/// the fix round after `ae0078c`'s review: decision logic belongs in Core,
/// the CLI stays wiring — M20 CLI design), so these tests exercise it
/// directly, the same way `SessionCatalogTests` exercises `SessionCatalog`:
/// no temp store, no subprocess, no environment variable.
@Suite("Session name completer")
struct SessionNameCompleterTests {
    // MARK: - `complete(prefix:in:)` — pure, catalog-driven

    @Test func matchesByPrefixSortedWithATrailingColon() {
        let catalog = SessionCatalog(
            sessions: [sshSession(name: "Work"), sshSession(name: "Web-01"), sshSession(name: "Prod / DB")],
            groups: [])

        #expect(SessionNameCompleter.complete(prefix: "W", in: catalog) == ["Web-01:", "Work:"])
    }

    @Test func anEmptyPrefixListsEveryName() {
        let catalog = SessionCatalog(
            sessions: [sshSession(name: "Work"), sshSession(name: "Web-01"), sshSession(name: "Prod / DB")],
            groups: [])

        #expect(
            SessionNameCompleter.complete(prefix: "", in: catalog)
                == ["Prod / DB:", "Web-01:", "Work:"])
    }

    @Test func aPrefixAlreadyCarryingAColonOffersNothing() {
        let catalog = SessionCatalog(sessions: [sshSession(name: "Work")], groups: [])

        #expect(SessionNameCompleter.complete(prefix: "Work:", in: catalog) == [])
        #expect(SessionNameCompleter.complete(prefix: "Work:/x", in: catalog) == [])
    }

    /// The name/path boundary is the colon, not `/` — a session name is
    /// free text and may itself contain a `/` (this suite's own "Prod / DB"
    /// fixture, seeded above, is exactly that case). A prefix that reaches
    /// an embedded `/` but has not yet reached the colon must still match:
    /// this is the case `ae0078c`'s review found unguarded (Important
    /// finding I-1) — `guard !prefix.contains("/")` rejected it outright,
    /// before the `hasPrefix` filter that would otherwise have found it.
    @Test func aPrefixReachingAnEmbeddedSlashBeforeTheColonStillMatches() {
        let catalog = SessionCatalog(
            sessions: [sshSession(name: "Work"), sshSession(name: "Prod / DB")], groups: [])

        #expect(SessionNameCompleter.complete(prefix: "Prod / ", in: catalog) == ["Prod / DB:"])
    }

    /// The same case with a session name that needs no quoting to reach a
    /// shell at all (unlike `"Prod / DB"`), matching the review's own
    /// failure scenario: `macscp-cli ls web/`⇥ must still offer
    /// `web/us-east:` — no `:` has been typed, so the name is not yet
    /// finished.
    @Test func anUnquotedNameContainingASlashStillMatchesPastItsSlash() {
        let catalog = SessionCatalog(sessions: [sshSession(name: "web/us-east")], groups: [])

        #expect(SessionNameCompleter.complete(prefix: "web/", in: catalog) == ["web/us-east:"])
    }

    // MARK: - `complete(prefix:storeDirectory:)` — the store-opening convenience

    private func withTempStore(
        sessionNames: [String], unreadable: Bool = false,
        _ body: (URL) throws -> Void
    ) throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(
                "macscp-cli-completer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("sessions-v2.json")
        defer {
            // Permission bits are restored before removal: `chmod` itself
            // needs no read permission on the target (only ownership), but
            // `removeItem` on a directory whose file is unreadable can
            // still leave debris if this is skipped.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: fileURL.path(percentEncoded: false))
            try? FileManager.default.removeItem(at: directory)
        }

        let store = SessionStore(directory: directory)
        for name in sessionNames {
            try store.upsert(sshSession(name: name))
        }

        if unreadable {
            // Mode 0000 on the store's own file — not the directory — so
            // `SessionStore.load()` actually reaches `Data(contentsOf:)`
            // and throws, rather than failing an earlier `fileExists`
            // check and silently returning an empty store: the point of
            // this test is that the convenience catches a real thrown
            // error, not that an empty catalog happens to answer `[]` too
            // (same idiom as `EmbeddedKeyPorterTests`'s "locked_key"
            // fixture).
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o000], ofItemAtPath: fileURL.path(percentEncoded: false))
        }

        try body(directory)
    }

    @Test func theConvenienceOpensTheStoreAtTheGivenDirectory() throws {
        try withTempStore(sessionNames: ["Work", "Web-01"]) { directory in
            #expect(
                SessionNameCompleter.complete(prefix: "W", storeDirectory: directory)
                    == ["Web-01:", "Work:"])
        }
    }

    @Test func anUnreadableStoreAnswersEmptyRatherThanThrowing() throws {
        try withTempStore(sessionNames: ["Work"], unreadable: true) { directory in
            #expect(SessionNameCompleter.complete(prefix: "", storeDirectory: directory) == [])
        }
    }
}
