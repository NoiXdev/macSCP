import Foundation
import Testing
@testable import macSCPCore

@Suite("FileListFormatter")
struct FileListFormatterTests {
    private let dir = RemoteFileItem(name: "docs", path: "/docs", kind: .directory, size: 96)
    private let file = RemoteFileItem(
        name: "a.txt", path: "/a.txt", kind: .file,
        size: 1536, modifiedAt: Date(timeIntervalSince1970: 0)
    )
    private let bare = RemoteFileItem(name: "b", path: "/b", kind: .file)
    private let symlink = RemoteFileItem(name: "current", path: "/current", kind: .symlink, size: nil)

    @Test func directoriesShowDashInsteadOfInodeSize() {
        #expect(FileListFormatter.sizeString(for: dir) == "-")
    }

    @Test func missingSizeShowsDash() {
        #expect(FileListFormatter.sizeString(for: bare) == "-")
    }

    @Test func fileSizeIsFormatted() {
        let s = FileListFormatter.sizeString(for: file)
        #expect(s != "-")
        #expect(s.contains { $0.isNumber })
    }

    @Test func missingDateShowsDash() {
        #expect(FileListFormatter.dateString(for: bare) == "-")
    }

    @Test func presentDateIsFormatted() {
        let s = FileListFormatter.dateString(for: file)
        #expect(s != "-")
        #expect(s.contains("19") || s.contains("70"))  // 1970, locale-tolerant
    }

    @Test func directoryDisplayNameGetsSlash() {
        #expect(FileListFormatter.displayName(for: dir) == "docs/")
        #expect(FileListFormatter.displayName(for: file) == "a.txt")
    }

    /// M11h/T1: a symlink gets NO trailing slash, even when its name could
    /// be mistaken for a directory — without a per-entry `stat`, whether it
    /// resolves to a directory isn't knowable here (same restraint as the
    /// M11g/T2 completion, which also never offers symlinks as directories).
    /// Regression guard alongside the two cases above: directories keep
    /// their `/`, plain files stay without one.
    @Test func symlinkDisplayNameGetsNoSlash() {
        #expect(FileListFormatter.displayName(for: symlink) == "current")
    }
}
