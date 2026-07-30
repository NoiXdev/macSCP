import Foundation
import Testing
@testable import macSCPCore

@Suite("PathCompletion")
struct PathCompletionTests {
    private func folder(_ name: String, in directory: String = "/var/www") -> RemoteFileItem {
        RemoteFileItem(name: name, path: RemotePath.join(directory, name), kind: .directory)
    }

    private func file(_ name: String, in directory: String = "/var/www") -> RemoteFileItem {
        RemoteFileItem(name: name, path: RemotePath.join(directory, name), kind: .file, size: 1)
    }

    // MARK: - directoryToList

    @Test func directoryToListCutsAfterLastSlash() {
        #expect(PathCompletion.directoryToList(for: "/var/www/ho") == "/var/www")
    }

    @Test func directoryToListHandlesTrailingSlash() {
        #expect(PathCompletion.directoryToList(for: "/var/www/") == "/var/www")
    }

    @Test func directoryToListOneLevelDeepIsRoot() {
        #expect(PathCompletion.directoryToList(for: "/var") == "/")
    }

    @Test func directoryToListAtRootIsRoot() {
        #expect(PathCompletion.directoryToList(for: "/") == "/")
    }

    // MARK: - complete

    @Test func uniqueMatchCompletesWithTrailingSlash() {
        let result = PathCompletion.complete(
            input: "/var/www/ht", entries: [folder("html")], caseSensitive: true)
        #expect(result.completedInput == "/var/www/html/")
        #expect(result.candidates == ["html"])
    }

    @Test func multipleCandidatesExtendToCommonPrefix() {
        let entries = [folder("hosts"), folder("home-alt"), folder("holiday")]
        let result = PathCompletion.complete(input: "/var/www/h", entries: entries, caseSensitive: true)
        #expect(result.completedInput == "/var/www/ho")
        #expect(result.candidates == ["holiday", "home-alt", "hosts"])
    }

    @Test func multipleCandidatesWithoutExtraCommonPrefixLeaveInputUnchanged() {
        let entries = [folder("html"), folder("hosts")]
        let result = PathCompletion.complete(input: "/var/www/h", entries: entries, caseSensitive: true)
        #expect(result.completedInput == "/var/www/h")
        #expect(result.candidates == ["hosts", "html"])
    }

    @Test func noMatchLeavesInputUnchanged() {
        let result = PathCompletion.complete(
            input: "/var/www/zz", entries: [folder("html")], caseSensitive: true)
        #expect(result.completedInput == "/var/www/zz")
        #expect(result.candidates == [])
    }

    @Test func trailingSlashListsAllDirectoriesAndLeavesInputUnchangedWithNoCommonPrefix() {
        let entries = [folder("html"), folder("images")]
        let result = PathCompletion.complete(input: "/var/www/", entries: entries, caseSensitive: true)
        #expect(result.candidates == ["html", "images"])
        #expect(result.completedInput == "/var/www/")   // "h" vs "i" share no prefix
    }

    @Test func filesAreNeverCandidates() {
        let entries = [file("index.html"), folder("images")]
        let result = PathCompletion.complete(input: "/var/www/i", entries: entries, caseSensitive: true)
        #expect(result.completedInput == "/var/www/images/")
        #expect(result.candidates == ["images"])
    }

    @Test func caseSensitiveMatchFailsOnWrongCase() {
        let entries = [RemoteFileItem(name: "Docs", path: "/home/Docs", kind: .directory)]
        let result = PathCompletion.complete(input: "/home/d", entries: entries, caseSensitive: true)
        #expect(result.completedInput == "/home/d")
        #expect(result.candidates == [])
    }

    /// caseSensitive: false must adopt the REAL entry's casing ("Docs"),
    /// never the typed casing ("docs") — see `PathCompletion`'s doc comment.
    @Test func caseInsensitiveMatchAdoptsRealEntryCasing() {
        let entries = [RemoteFileItem(name: "Docs", path: "/home/Docs", kind: .directory)]
        let result = PathCompletion.complete(input: "/home/d", entries: entries, caseSensitive: false)
        #expect(result.completedInput == "/home/Docs/")
        #expect(result.candidates == ["Docs"])
    }

    @Test func emptyListingYieldsNoCandidatesAndUnchangedInput() {
        let result = PathCompletion.complete(input: "/var/www/h", entries: [], caseSensitive: true)
        #expect(result.completedInput == "/var/www/h")
        #expect(result.candidates == [])
    }

    @Test func rootListsBothCandidatesWithUnchangedInput() {
        let entries = [
            RemoteFileItem(name: "etc", path: "/etc", kind: .directory),
            RemoteFileItem(name: "usr", path: "/usr", kind: .directory),
        ]
        let result = PathCompletion.complete(input: "/", entries: entries, caseSensitive: true)
        #expect(result.completedInput == "/")
        #expect(result.candidates == ["etc", "usr"])
    }

    @Test func spacesInComponentNamesAreNeitherQuotedNorEscaped() {
        let entries = [RemoteFileItem(name: "My Files", path: "/home/My Files", kind: .directory)]
        let result = PathCompletion.complete(input: "/home/My", entries: entries, caseSensitive: true)
        #expect(result.completedInput == "/home/My Files/")
        #expect(result.candidates == ["My Files"])
    }

    /// A symlink is never a candidate: without a `stat` call, `complete`
    /// cannot know whether it points at a directory (same restraint as
    /// `PermissionsTreeApplier` — see its doc comments).
    @Test func symlinksAreNeverCandidates() {
        let entries = [RemoteFileItem(name: "html", path: "/var/www/html", kind: .symlink)]
        let result = PathCompletion.complete(input: "/var/www/h", entries: entries, caseSensitive: true)
        #expect(result.completedInput == "/var/www/h")
        #expect(result.candidates == [])
    }
}
