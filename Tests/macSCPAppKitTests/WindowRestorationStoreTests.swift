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
///
/// Fix round 1 moved the write: there is one, at `applicationWillTerminate`,
/// replacing the file with the windows that were still open. So the cases
/// below say "a quit" and "a launch" rather than "a close", and the pair
/// that matters most is the one at each end of a seed file's life — a
/// launch consumes it, and a quit or launch that is not restoring
/// discards it.
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

    // MARK: - Writing, once, with the windows that were open

    @Test func theSeedsComeBackInTheOrderTheyWereWritten() {
        let dir = Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = WindowRestorationStore(directory: dir)
        let first = Self.describedWindow(isPrimary: true)
        let second = Self.describedWindow(isPrimary: false, keepOnTop: true)
        store.replace([first, second], whenEnabled: true)
        #expect(store.read() == [first, second])
    }

    /// The file describes ONE quit. A second write replaces it whole
    /// rather than adding to it — the first version of this appended per
    /// closed window, which is how a session's deliberately closed windows
    /// piled up in a file that is supposed to say what was on screen at
    /// the end.
    @Test func aSecondWriteReplacesTheFileRatherThanAddingToIt() {
        let dir = Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = WindowRestorationStore(directory: dir)
        let earlier = Self.describedWindow(isPrimary: true)
        let later = Self.describedWindow(isPrimary: false)
        store.replace([earlier, earlier], whenEnabled: true)
        store.replace([later], whenEnabled: true)
        #expect(store.read() == [later])
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
        store.replace([seed], whenEnabled: true)
        let read = store.read()
        #expect(read == [seed])
        #expect(read.first?.tabs.first?.sessionID == sessionID)
        #expect(read.first?.tabs.first?.paneVisibility == PaneVisibility.terminalOnly)
        #expect(read.first?.keepOnTop == true)
        #expect(read.first?.isPrimary == true)
    }

    // MARK: - The setting off leaves no file behind

    @Test func nothingIsWrittenWhileTheSettingIsOff() {
        let dir = Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = WindowRestorationStore(directory: dir)
        store.replace([Self.describedWindow(isPrimary: true)], whenEnabled: false)
        #expect(store.read().isEmpty)
        #expect(
            FileManager.default.fileExists(atPath: store.fileURL.path(percentEncoded: false))
                == false,
            "the store must not even create windows.json while the setting is off")
    }

    /// A quit with the setting off DELETES an existing file rather than
    /// leaving it. A seed file describes one quit; a stale one has no
    /// owner, and leaving it would mean the next launch with the setting
    /// on restored a generation of windows two quits old.
    @Test func aQuitWithTheSettingOffDiscardsAnEarlierFile() {
        let dir = Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = WindowRestorationStore(directory: dir)
        store.replace([Self.describedWindow(isPrimary: true)], whenEnabled: true)
        #expect(store.read().count == 1)
        store.replace([Self.describedWindow(isPrimary: false)], whenEnabled: false)
        #expect(store.read().isEmpty)
        #expect(
            FileManager.default.fileExists(atPath: store.fileURL.path(percentEncoded: false))
                == false)
    }

    // MARK: - A seed file never outlives the launch that finds it

    @Test func theLaunchReadTakesTheFileAndLeavesNothingBehind() {
        let dir = Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = WindowRestorationStore(directory: dir)
        let seed = Self.describedWindow(isPrimary: true)
        store.replace([seed], whenEnabled: true)
        #expect(store.consumeAtLaunch(whenEnabled: true) == [seed])
        #expect(store.read().isEmpty, """
            the file must be consumed by the launch that read it — a second \
            launch that crashed before its quit sweep ran would otherwise \
            reopen the windows of the launch before it, forever
            """)
    }

    /// The other direction of the same rule, and the one that keeps a
    /// launch from ever seeing two generations: with the setting off the
    /// file is deleted UNREAD. Turning the setting on afterwards restores
    /// nothing, because there is nothing left to restore from.
    @Test func aLaunchWithTheSettingOffDiscardsTheFileUnread() {
        let dir = Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = WindowRestorationStore(directory: dir)
        store.replace([Self.describedWindow(isPrimary: true)], whenEnabled: true)
        #expect(store.consumeAtLaunch(whenEnabled: false).isEmpty)
        #expect(store.read().isEmpty)
        #expect(
            FileManager.default.fileExists(atPath: store.fileURL.path(percentEncoded: false))
                == false,
            "a launch that is not restoring must leave no seed file behind")
    }

    @Test func readingAMissingFileIsEmptyAndNotAnError() {
        let dir = Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = WindowRestorationStore(directory: dir)
        #expect(store.read().isEmpty)
        #expect(store.consumeAtLaunch(whenEnabled: true).isEmpty)
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
        store.replace(
            [WindowSeed(
                tabs: [TabSeed(sessionID: UUID(), paneVisibility: .bothVisible)],
                keepOnTop: true, isPrimary: true)],
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
