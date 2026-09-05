import Foundation
import Testing
@testable import MacSCPAppKit
import macSCPCore

/// `WindowRestorationStore` — the `windows.json` beside the app's other
/// JSON stores (Detachable Tabs plan, Task 5).
///
/// Every case here runs over a temporary directory it makes and removes.
/// Nothing in this suite may name the real application-support path: the
/// store resolves its own directory the same way `SessionStore` does, and
/// a test that spelled that path a second time would both write into the
/// running user's data and stop being a test of the lookup.
///
/// The last case is the secrecy pin. It is a whole-file key comparison
/// rather than a search for a forbidden word, because a search only finds
/// the words whoever wrote it thought of — a key set that must MATCH
/// fails the moment anything else appears in the file.
@Suite("WindowRestorationStore — windows.json")
@MainActor
struct WindowRestorationStoreTests {
    private static func makeTempDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-windows-\(UUID().uuidString)")
    }

    private static func describedWindow(
        isPrimary: Bool, keepOnTop: Bool = false, sessionID: UUID? = UUID()
    ) -> WindowSeed {
        WindowSeed(
            tabs: [TabSeed(sessionID: sessionID, paneVisibility: .bothVisible)],
            keepOnTop: keepOnTop, isPrimary: isPrimary)
    }

    // MARK: - Where the file lives

    /// The store reads the directory the same way the other JSON stores
    /// do rather than spelling a path of its own — one lookup, so the
    /// `MACSCP_STORAGE_DIRECTORY` override and the real location cannot
    /// come to disagree between stores.
    @Test func theDefaultDirectoryIsTheOneEveryOtherJSONStoreUses() {
        #expect(WindowRestorationStore.defaultDirectory == SessionStore.defaultDirectory)
    }

    @Test func theFileSitsBesideTheOtherStoresUnderItsOwnName() {
        let dir = Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = WindowRestorationStore(directory: dir)
        #expect(store.fileURL == dir.appendingPathComponent("windows.json"))
    }

    // MARK: - Writing, in the order the windows closed

    @Test func seedsComeBackInTheOrderTheyWereWritten() {
        let dir = Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = WindowRestorationStore(directory: dir)
        let first = Self.describedWindow(isPrimary: false)
        let second = Self.describedWindow(isPrimary: true, keepOnTop: true)
        store.append(first, whenEnabled: true)
        store.append(second, whenEnabled: true)
        #expect(store.read() == [first, second])
    }

    @Test func aWrittenSeedKeepsEveryFactTheWindowHad() {
        let dir = Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = WindowRestorationStore(directory: dir)
        let sessionID = UUID()
        let seed = WindowSeed(
            tabs: [
                TabSeed(sessionID: sessionID, paneVisibility: .terminalOnly),
                TabSeed(sessionID: nil, paneVisibility: .filesOnly),
            ],
            keepOnTop: true, isPrimary: true)
        store.append(seed, whenEnabled: true)
        let read = store.read()
        #expect(read == [seed])
        #expect(read.first?.tabs.first?.sessionID == sessionID)
        #expect(read.first?.tabs.first?.paneVisibility == PaneVisibility.terminalOnly)
        #expect(read.first?.keepOnTop == true)
        #expect(read.first?.isPrimary == true)
    }

    // MARK: - The setting off changes nothing on disk

    @Test func nothingIsWrittenWhileTheSettingIsOff() {
        let dir = Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = WindowRestorationStore(directory: dir)
        store.append(Self.describedWindow(isPrimary: true), whenEnabled: false)
        #expect(store.read().isEmpty)
        #expect(
            FileManager.default.fileExists(atPath: store.fileURL.path(percentEncoded: false))
                == false,
            "the store must not even create windows.json while the setting is off")
    }

    /// The reason the flag-off write is a no-op rather than a clear:
    /// turning the setting ON later must not resurrect windows from
    /// whenever it was last on. An existing file is left exactly as it
    /// was found, and the launch that reads it is what consumes it.
    @Test func anExistingFileIsLeftAloneWhileTheSettingIsOff() {
        let dir = Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = WindowRestorationStore(directory: dir)
        let earlier = Self.describedWindow(isPrimary: true)
        store.append(earlier, whenEnabled: true)
        store.append(Self.describedWindow(isPrimary: false), whenEnabled: false)
        #expect(store.read() == [earlier])
        #expect(store.readAndClear(whenEnabled: false).isEmpty)
        #expect(store.read() == [earlier], """
            a read with the setting off must not consume the file either — \
            only a launch that is actually restoring may clear it
            """)
    }

    // MARK: - A seed file is consumed once

    @Test func theLaunchReadTakesTheFileAndLeavesNothingBehind() {
        let dir = Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = WindowRestorationStore(directory: dir)
        let seed = Self.describedWindow(isPrimary: true)
        store.append(seed, whenEnabled: true)
        #expect(store.readAndClear(whenEnabled: true) == [seed])
        #expect(store.read().isEmpty, """
            the file must be consumed by the launch that read it — a second \
            launch that crashed before writing anything would otherwise \
            reopen the windows of the launch before it, forever
            """)
    }

    @Test func readingAMissingFileIsEmptyAndNotAnError() {
        let dir = Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = WindowRestorationStore(directory: dir)
        #expect(store.read().isEmpty)
        #expect(store.readAndClear(whenEnabled: true).isEmpty)
    }

    @Test func unreadableContentIsEmptyRatherThanAFailedLaunch() throws {
        let dir = Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = WindowRestorationStore(directory: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json at all".utf8).write(to: store.fileURL)
        #expect(store.read().isEmpty)
    }

    // MARK: - What the file may contain

    /// The whole file, key by key. `windows.json` is not a secret store
    /// and must never become one: it holds identifiers and booleans, and
    /// this comparison fails on ANY key that is not one of them rather
    /// than on a list of words someone remembered to forbid.
    @Test func theFileHoldsIdentifiersAndBooleansAndNothingElse() throws {
        let dir = Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = WindowRestorationStore(directory: dir)
        store.append(
            WindowSeed(
                tabs: [TabSeed(sessionID: UUID(), paneVisibility: .bothVisible)],
                keepOnTop: true, isPrimary: true),
            whenEnabled: true)

        let data = try Data(contentsOf: store.fileURL)
        let decoded = try JSONSerialization.jsonObject(with: data)
        let windows = try #require(decoded as? [[String: Any]])
        #expect(windows.count == 1)
        for window in windows {
            #expect(Set(window.keys) == ["id", "tabIDs", "tabs", "keepOnTop", "isPrimary"])
            let tabs = try #require(window["tabs"] as? [[String: Any]])
            for tab in tabs {
                #expect(Set(tab.keys) == ["sessionID", "paneVisibility"])
                let visibility = try #require(tab["paneVisibility"] as? [String: Any])
                #expect(Set(visibility.keys) == ["showsFiles", "showsTerminal"])
            }
        }
    }
}
