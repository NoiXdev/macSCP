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
}
