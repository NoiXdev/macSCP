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

    /// Regression (T1 review M-3): repeated slashes must collapse inside the
    /// directory portion too, not just at the very end — the guard for this
    /// was missing even though `RemotePath.normalizedAbsolute` already
    /// handles it correctly.
    @Test func directoryToListCollapsesRepeatedSlashesInsideTheDirectoryPortion() {
        #expect(PathCompletion.directoryToList(for: "/var//www//h") == "/var/www")
        let result = PathCompletion.complete(
            input: "/var//www//h", entries: [folder("html")], caseSensitive: true)
        #expect(result.completedInput == "/var/www/html/")
    }

    /// Documents current behavior (T1 review M-2): `input` is required to be
    /// absolute. A bare relative fragment with no slash at all does NOT
    /// resolve relative to any "current directory" — there is none to fall
    /// back to — it silently becomes an absolute completion against root
    /// instead. Harmless for the path bar (always pre-filled with the
    /// absolute current path) but worth pinning so T2 isn't surprised.
    @Test func relativeInputWithNoSlashIsTreatedAsAbsoluteAgainstRoot() {
        #expect(PathCompletion.directoryToList(for: "ho") == "/")
        let result = PathCompletion.complete(
            input: "ho", entries: [folder("hosts", in: "/")], caseSensitive: true)
        #expect(result.completedInput == "/hosts/")
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
        let entries = [folder("Docs", in: "/home")]
        let result = PathCompletion.complete(input: "/home/d", entries: entries, caseSensitive: true)
        #expect(result.completedInput == "/home/d")
        #expect(result.candidates == [])
    }

    /// caseSensitive: false must adopt the REAL entry's casing ("Docs"),
    /// never the typed casing ("docs") — see `PathCompletion`'s doc comment.
    @Test func caseInsensitiveMatchAdoptsRealEntryCasing() {
        let entries = [folder("Docs", in: "/home")]
        let result = PathCompletion.complete(input: "/home/d", entries: entries, caseSensitive: false)
        #expect(result.completedInput == "/home/Docs/")
        #expect(result.candidates == ["Docs"])
    }

    /// Regression (T1 review I-2): `PathCompletion.swift:98` used to guard on
    /// `commonPrefix.count > typed.count` — comparing LENGTHS — so a
    /// same-length but differently-cased real prefix lost to the typed
    /// text. "Downloads" and "Documents" both really start "Do", the same
    /// length as typed "do": the real spelling must still win.
    @Test func caseInsensitiveMultiMatchAdoptsRealCasingEvenAtEqualLength() {
        let entries = [folder("Downloads", in: "/home"), folder("Documents", in: "/home")]
        let result = PathCompletion.complete(input: "/home/do", entries: entries, caseSensitive: false)
        #expect(result.completedInput == "/home/Do")
        #expect(result.candidates == ["Documents", "Downloads"])
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
        let entries = [folder("My Files", in: "/home")]
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
