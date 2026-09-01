import Foundation
import Testing
@testable import macSCPCore

@Suite("SettingsStore")
@MainActor
struct SettingsStoreTests {
    private func makeTempDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-settings-\(UUID().uuidString)")
    }

    private var fileURL: (URL) -> URL {
        { dir in dir.appendingPathComponent("settings.json") }
    }

    /// Reads back what a setter actually persisted. Asserting through
    /// `SettingsStore`'s own getter is not enough to pin a clamping
    /// setter: the getter independently re-clamps on every read, so a
    /// setter that skipped clamping entirely would still read back
    /// correctly and the test would stay green.
    private func persistedRaw(_ dir: URL) throws -> [String: JSONValue] {
        let data = try Data(contentsOf: fileURL(dir))
        return try JSONDecoder().decode([String: JSONValue].self, from: data)
    }

    @Test func defaultsWithoutFile() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        #expect(store.maxConcurrentTransfers == 3)
        #expect(store.uploadLimitKBs == 0)
        #expect(store.downloadLimitKBs == 0)
    }

    @Test func persistenceRoundtrips() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        store.maxConcurrentTransfers = 5
        store.uploadLimitKBs = 100
        store.downloadLimitKBs = 200

        let reloaded = SettingsStore(directory: dir)
        #expect(reloaded.maxConcurrentTransfers == 5)
        #expect(reloaded.uploadLimitKBs == 100)
        #expect(reloaded.downloadLimitKBs == 200)
    }

    @Test func menuBarEnabledDefaultsTrue() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        #expect(store.menuBarEnabled == true)
    }

    @Test func menuBarEnabledRoundtrips() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        store.menuBarEnabled = false
        let reloaded = SettingsStore(directory: dir)
        #expect(reloaded.menuBarEnabled == false)
    }

    /// The sidebar's tag filter bar is on unless the user turns it off (E1):
    /// a fresh install shows the filter it has, and switching it off is a
    /// decision that has to be made once and then persists.
    @Test func sidebarTagFilterEnabledDefaultsTrue() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        #expect(store.sidebarTagFilterEnabled == true)
    }

    @Test func sidebarTagFilterEnabledRoundtrips() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        store.sidebarTagFilterEnabled = false
        let reloaded = SettingsStore(directory: dir)
        #expect(reloaded.sidebarTagFilterEnabled == false)
    }

    @Test func maxConcurrentTransfersClampsBelowRange() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        store.maxConcurrentTransfers = 0
        #expect(store.maxConcurrentTransfers == 1)
    }

    @Test func maxConcurrentTransfersClampsAboveRange() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        store.maxConcurrentTransfers = 99
        #expect(store.maxConcurrentTransfers == 8)
    }

    @Test func negativeLimitsClampToZero() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        store.uploadLimitKBs = -5
        store.downloadLimitKBs = -1
        #expect(store.uploadLimitKBs == 0)
        #expect(store.downloadLimitKBs == 0)
    }

    @Test func outOfRangeValuesOnDiskAreClampedOnLoad() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = """
            {"maxConcurrentTransfers": 42, "uploadLimitKBs": -10, "downloadLimitKBs": -20}
            """
        try Data(json.utf8).write(to: fileURL(dir))

        let store = SettingsStore(directory: dir)
        #expect(store.maxConcurrentTransfers == 8)
        #expect(store.uploadLimitKBs == 0)
        #expect(store.downloadLimitKBs == 0)
    }

    @Test func unknownKeysSurviveLoadChangeAndSave() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = """
            {"maxConcurrentTransfers": 4, "futureFeatureEnabled": true, "futureLabel": "keep-me"}
            """
        try Data(json.utf8).write(to: fileURL(dir))

        let store = SettingsStore(directory: dir)
        #expect(store.maxConcurrentTransfers == 4)
        store.downloadLimitKBs = 42

        let data = try Data(contentsOf: fileURL(dir))
        let raw = try JSONDecoder().decode([String: JSONValue].self, from: data)
        #expect(raw["futureFeatureEnabled"] == .bool(true))
        #expect(raw["futureLabel"] == .string("keep-me"))
        #expect(raw["downloadLimitKBs"] == .number(42))
    }

    @Test func corruptJSONFallsBackToDefaultsWithoutCrashing() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("kein json".utf8).write(to: fileURL(dir))

        let store = SettingsStore(directory: dir)
        #expect(store.maxConcurrentTransfers == 3)
        #expect(store.uploadLimitKBs == 0)
        #expect(store.downloadLimitKBs == 0)

        // The next save replaces the corrupt file with valid JSON.
        store.maxConcurrentTransfers = 6
        let data = try Data(contentsOf: fileURL(dir))
        let decoded = try JSONDecoder().decode([String: JSONValue].self, from: data)
        #expect(decoded["maxConcurrentTransfers"] == .number(6))
    }

    @Test func directoryIsCreatedWhenNeeded() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(!FileManager.default.fileExists(atPath: dir.path(percentEncoded: false)))

        let store = SettingsStore(directory: dir)
        store.maxConcurrentTransfers = 4
        #expect(FileManager.default.fileExists(atPath: fileURL(dir).path(percentEncoded: false)))
    }

    // MARK: - Default editor + file associations (M5e Task 1)

    @Test func defaultEditorSettingsDefaultToNilAndEmpty() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        #expect(store.defaultEditorPath == nil)
        #expect(store.fileAssociations.isEmpty)
        #expect(store.associatedApp(forExtension: "php") == nil)
    }

    @Test func editorSettingsPersistenceRoundtrips() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        store.defaultEditorPath = "/Applications/TextEdit.app"
        store.fileAssociations = [
            "php": "/Applications/PhpStorm.app",
            "md": "/Applications/Typora.app",
        ]

        let reloaded = SettingsStore(directory: dir)
        #expect(reloaded.defaultEditorPath == "/Applications/TextEdit.app")
        #expect(
            reloaded.fileAssociations == [
                "php": "/Applications/PhpStorm.app",
                "md": "/Applications/Typora.app",
            ])
    }

    @Test func fileAssociationsNormalizesExtensionsOnSet() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        store.fileAssociations = [
            ".PHP": "/Applications/PhpStorm.app",
            " .md ": "/Applications/Typora.app",
        ]
        #expect(
            store.fileAssociations == [
                "php": "/Applications/PhpStorm.app",
                "md": "/Applications/Typora.app",
            ])
    }

    @Test func associatedAppNormalizesLookupExtension() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        store.fileAssociations = ["php": "/Applications/PhpStorm.app"]
        #expect(store.associatedApp(forExtension: ".PHP") == "/Applications/PhpStorm.app")
        #expect(store.associatedApp(forExtension: " php ") == "/Applications/PhpStorm.app")
    }

    @Test func emptyOrWhitespaceExtensionsAreIgnoredOnSetAndRead() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        store.fileAssociations = [
            "": "/Applications/PhpStorm.app",
            "   ": "/Applications/Typora.app",
            "php": "/Applications/PhpStorm.app",
        ]
        #expect(store.fileAssociations == ["php": "/Applications/PhpStorm.app"])
        #expect(store.associatedApp(forExtension: "") == nil)
        #expect(store.associatedApp(forExtension: "   ") == nil)
    }

    @Test func settingEmptyAppPathRemovesAssociationRule() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        store.fileAssociations = [
            "php": "/Applications/PhpStorm.app",
            "md": "/Applications/Typora.app",
        ]
        store.fileAssociations = ["php": "", "md": "/Applications/Typora.app"]
        #expect(store.fileAssociations == ["md": "/Applications/Typora.app"])
        #expect(store.associatedApp(forExtension: "php") == nil)
    }

    @Test func settingDefaultEditorPathToEmptyOrNilClearsIt() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        store.defaultEditorPath = "/Applications/TextEdit.app"
        store.defaultEditorPath = ""
        #expect(store.defaultEditorPath == nil)

        store.defaultEditorPath = "/Applications/TextEdit.app"
        store.defaultEditorPath = nil
        #expect(store.defaultEditorPath == nil)
    }

    @Test func loadingOldSettingsFileWithoutEditorKeysUsesDefaults() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = """
            {"maxConcurrentTransfers": 4, "uploadLimitKBs": 10, "downloadLimitKBs": 20}
            """
        try Data(json.utf8).write(to: fileURL(dir))

        let store = SettingsStore(directory: dir)
        #expect(store.maxConcurrentTransfers == 4)
        #expect(store.defaultEditorPath == nil)
        #expect(store.fileAssociations.isEmpty)
    }

    // MARK: - Hidden files (M7a Task 4)

    @Test func showHiddenFilesDefaultsFalseAndPersists() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        #expect(store.showHiddenFiles == false)
        store.showHiddenFiles = true
        let reloaded = SettingsStore(directory: dir)
        #expect(reloaded.showHiddenFiles == true)
    }

    @Test func editorSettingsSurviveAlongsideUnknownKeys() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = """
            {"maxConcurrentTransfers": 4, "futureFeatureEnabled": true, "futureLabel": "keep-me"}
            """
        try Data(json.utf8).write(to: fileURL(dir))

        let store = SettingsStore(directory: dir)
        store.defaultEditorPath = "/Applications/TextEdit.app"
        store.fileAssociations = ["php": "/Applications/PhpStorm.app"]

        let data = try Data(contentsOf: fileURL(dir))
        let raw = try JSONDecoder().decode([String: JSONValue].self, from: data)
        #expect(raw["futureFeatureEnabled"] == .bool(true))
        #expect(raw["futureLabel"] == .string("keep-me"))
        #expect(raw["defaultEditorPath"] == .string("/Applications/TextEdit.app"))
        #expect(raw["fileAssociations"] == .object(["php": .string("/Applications/PhpStorm.app")]))
    }

    // MARK: - Auto-refresh (M9c Task 1)

    @Test func autoRefreshDefaultsToEnabledWithFiveSecondInterval() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        #expect(store.autoRefreshEnabled == true)
        #expect(store.autoRefreshIntervalSeconds == 5)
    }

    @Test func autoRefreshIntervalSetterClampsBelowRange() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        store.autoRefreshIntervalSeconds = 1
        #expect(store.autoRefreshIntervalSeconds == 2)
    }

    @Test func autoRefreshIntervalSetterClampsAboveRange() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        store.autoRefreshIntervalSeconds = 9999
        #expect(store.autoRefreshIntervalSeconds == 300)
    }

    /// Forward-compat pattern (see `outOfRangeValuesOnDiskAreClampedOnLoad`):
    /// a hand-edited or corrupted settings.json can carry an out-of-range
    /// raw value directly, bypassing the setter entirely — the GETTER must
    /// clamp too, not just the setter.
    @Test func autoRefreshIntervalGetterClampsRawValueBelowRange() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = """
            {"autoRefreshIntervalSeconds": 0}
            """
        try Data(json.utf8).write(to: fileURL(dir))

        let store = SettingsStore(directory: dir)
        #expect(store.autoRefreshIntervalSeconds == 2)
    }

    @Test func autoRefreshIntervalGetterClampsRawValueAboveRange() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = """
            {"autoRefreshIntervalSeconds": 100000}
            """
        try Data(json.utf8).write(to: fileURL(dir))

        let store = SettingsStore(directory: dir)
        #expect(store.autoRefreshIntervalSeconds == 300)
    }

    @Test func autoRefreshSettingsPersistenceRoundtrips() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        store.autoRefreshEnabled = false
        store.autoRefreshIntervalSeconds = 30

        let reloaded = SettingsStore(directory: dir)
        #expect(reloaded.autoRefreshEnabled == false)
        #expect(reloaded.autoRefreshIntervalSeconds == 30)
    }

    @Test func loadingOldSettingsFileWithoutAutoRefreshKeysUsesDefaults() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = """
            {"maxConcurrentTransfers": 4, "uploadLimitKBs": 10, "downloadLimitKBs": 20}
            """
        try Data(json.utf8).write(to: fileURL(dir))

        let store = SettingsStore(directory: dir)
        #expect(store.autoRefreshEnabled == true)
        #expect(store.autoRefreshIntervalSeconds == 5)
    }

    // MARK: - Terminal appearance (M9d Task 1)

    @Test func terminalAppearanceDefaults() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        #expect(store.terminalFontName == nil)
        #expect(store.terminalFontSize == 13)
        #expect(store.terminalCursorStyle == .block)
        #expect(store.terminalCursorBlink == true)
    }

    @Test func terminalFontSizeSetterClampsBelowRange() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        store.terminalFontSize = 8
        #expect(store.terminalFontSize == 9)
    }

    @Test func terminalFontSizeSetterClampsAboveRange() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        store.terminalFontSize = 99
        #expect(store.terminalFontSize == 24)
    }

    /// Forward-compat pattern (see `outOfRangeValuesOnDiskAreClampedOnLoad`):
    /// a hand-edited settings.json can carry an out-of-range raw value
    /// directly, bypassing the setter — the GETTER must clamp too.
    @Test func terminalFontSizeGetterClampsRawValueBelowRange() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = """
            {"terminalFontSize": 0}
            """
        try Data(json.utf8).write(to: fileURL(dir))

        let store = SettingsStore(directory: dir)
        #expect(store.terminalFontSize == 9)
    }

    @Test func terminalFontSizeGetterClampsRawValueAboveRange() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = """
            {"terminalFontSize": 1000}
            """
        try Data(json.utf8).write(to: fileURL(dir))

        let store = SettingsStore(directory: dir)
        #expect(store.terminalFontSize == 24)
    }

    /// An unrecognized raw cursor style string (e.g. a future value this
    /// app version doesn't know, or hand-edited garbage) must read as the
    /// safe default `.block`, never crash or propagate `nil`.
    @Test func terminalCursorStyleUnknownRawValueReadsAsBlock() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = """
            {"terminalCursorStyle": "weird"}
            """
        try Data(json.utf8).write(to: fileURL(dir))

        let store = SettingsStore(directory: dir)
        #expect(store.terminalCursorStyle == .block)
    }

    @Test func terminalAppearanceSettingsRoundtrip() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        store.terminalFontName = "Menlo"
        store.terminalFontSize = 16
        store.terminalCursorStyle = .bar
        store.terminalCursorBlink = false

        let reloaded = SettingsStore(directory: dir)
        #expect(reloaded.terminalFontName == "Menlo")
        #expect(reloaded.terminalFontSize == 16)
        #expect(reloaded.terminalCursorStyle == .bar)
        #expect(reloaded.terminalCursorBlink == false)
    }

    @Test func loadingOldSettingsFileWithoutTerminalAppearanceKeysUsesDefaults() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = """
            {"maxConcurrentTransfers": 4, "uploadLimitKBs": 10, "downloadLimitKBs": 20}
            """
        try Data(json.utf8).write(to: fileURL(dir))

        let store = SettingsStore(directory: dir)
        #expect(store.terminalFontName == nil)
        #expect(store.terminalFontSize == 13)
        #expect(store.terminalCursorStyle == .block)
        #expect(store.terminalCursorBlink == true)
    }

    // MARK: - Update check (M11b Task 2)

    @Test func updateCheckDefaultsToEnabledWithNoLastCheck() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        #expect(store.updateCheckEnabled == true)
        #expect(store.lastUpdateCheck == nil)
    }

    @Test func updateCheckSettingsPersistenceRoundtrips() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        store.updateCheckEnabled = false
        store.lastUpdateCheck = timestamp

        let reloaded = SettingsStore(directory: dir)
        #expect(reloaded.updateCheckEnabled == false)
        #expect(reloaded.lastUpdateCheck == timestamp)
    }

    @Test func lastUpdateCheckCanBeClearedBackToNil() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        store.lastUpdateCheck = Date()
        store.lastUpdateCheck = nil
        #expect(store.lastUpdateCheck == nil)
    }

    @Test func loadingOldSettingsFileWithoutUpdateCheckKeysUsesDefaults() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = """
            {"maxConcurrentTransfers": 4, "uploadLimitKBs": 10, "downloadLimitKBs": 20}
            """
        try Data(json.utf8).write(to: fileURL(dir))

        let store = SettingsStore(directory: dir)
        #expect(store.updateCheckEnabled == true)
        #expect(store.lastUpdateCheck == nil)
    }

    @Test func updateCheckSurvivesAlongsideUnknownKeys() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = """
            {"maxConcurrentTransfers": 4, "futureFeatureEnabled": true, "futureLabel": "keep-me"}
            """
        try Data(json.utf8).write(to: fileURL(dir))

        let store = SettingsStore(directory: dir)
        store.updateCheckEnabled = false
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        store.lastUpdateCheck = timestamp

        let data = try Data(contentsOf: fileURL(dir))
        let raw = try JSONDecoder().decode([String: JSONValue].self, from: data)
        #expect(raw["futureFeatureEnabled"] == .bool(true))
        #expect(raw["futureLabel"] == .string("keep-me"))
        #expect(raw["updateCheckEnabled"] == .bool(false))
        #expect(raw["lastUpdateCheck"] == .number(timestamp.timeIntervalSince1970))
    }

    // MARK: - External terminal (M11d Task 2)

    @Test func externalTerminalDefaultsToBuiltInNilFalse() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        #expect(store.terminalTarget == .builtIn)
        #expect(store.customTerminalAppPath == nil)
        #expect(store.externalTerminalPasswordHintShown == false)
    }

    @Test(arguments: [
        TerminalTarget.builtIn, .terminalApp, .iTerm, .custom,
    ])
    func externalTerminalSettingsRoundtrip(target: TerminalTarget) {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        store.terminalTarget = target
        store.customTerminalAppPath = "/Applications/iTerm.app"
        store.externalTerminalPasswordHintShown = true

        let reloaded = SettingsStore(directory: dir)
        #expect(reloaded.terminalTarget == target)
        #expect(reloaded.customTerminalAppPath == "/Applications/iTerm.app")
        #expect(reloaded.externalTerminalPasswordHintShown == true)
    }

    @Test func customTerminalAppPathSetToEmptyOrNilClearsIt() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        store.customTerminalAppPath = "/Applications/iTerm.app"
        store.customTerminalAppPath = ""
        #expect(store.customTerminalAppPath == nil)

        store.customTerminalAppPath = "/Applications/iTerm.app"
        store.customTerminalAppPath = nil
        #expect(store.customTerminalAppPath == nil)
    }

    /// An unrecognized raw target string (future app version, or hand-edited
    /// garbage) must read as the safe default `.builtIn` — same pattern as
    /// `terminalCursorStyleUnknownRawValueReadsAsBlock`.
    @Test func terminalTargetUnknownRawValueReadsAsBuiltIn() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = """
            {"terminalTarget": "weird"}
            """
        try Data(json.utf8).write(to: fileURL(dir))

        let store = SettingsStore(directory: dir)
        #expect(store.terminalTarget == .builtIn)
    }

    @Test func loadingOldSettingsFileWithoutExternalTerminalKeysUsesDefaults() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = """
            {"maxConcurrentTransfers": 4, "uploadLimitKBs": 10, "downloadLimitKBs": 20}
            """
        try Data(json.utf8).write(to: fileURL(dir))

        let store = SettingsStore(directory: dir)
        #expect(store.terminalTarget == .builtIn)
        #expect(store.customTerminalAppPath == nil)
        #expect(store.externalTerminalPasswordHintShown == false)
    }

    @Test func externalTerminalSurvivesAlongsideUnknownKeys() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = """
            {"maxConcurrentTransfers": 4, "futureFeatureEnabled": true, "futureLabel": "keep-me"}
            """
        try Data(json.utf8).write(to: fileURL(dir))

        let store = SettingsStore(directory: dir)
        store.terminalTarget = .custom
        store.customTerminalAppPath = "/Applications/iTerm.app"

        let data = try Data(contentsOf: fileURL(dir))
        let raw = try JSONDecoder().decode([String: JSONValue].self, from: data)
        #expect(raw["futureFeatureEnabled"] == .bool(true))
        #expect(raw["futureLabel"] == .string("keep-me"))
        #expect(raw["terminalTarget"] == .string("custom"))
        #expect(raw["customTerminalAppPath"] == .string("/Applications/iTerm.app"))
    }

    // MARK: - Visible file-list columns (M11m Task 1)

    @Test func visibleColumnsDefaultsToTodaysThreeFixedColumns() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        #expect(store.visibleColumns == [.name, .size, .modified])
    }

    @Test func visibleColumnsRoundtrips() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        store.visibleColumns = [.name, .permissions, .owner]

        let reloaded = SettingsStore(directory: dir)
        #expect(reloaded.visibleColumns == [.name, .permissions, .owner])
    }

    /// `name` can never be hidden — even a caller that omits it gets it
    /// back from both the setter and the getter.
    @Test func visibleColumnsAlwaysIncludesName() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        store.visibleColumns = [.owner, .group]
        #expect(store.visibleColumns == [.name, .owner, .group])
    }

    /// Forward compatibility: a settings.json predating M11m (no
    /// `visibleColumns` key at all) must show exactly what the list always
    /// showed before this feature existed.
    @Test func loadingOldSettingsFileWithoutVisibleColumnsKeyUsesDefaults() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = """
            {"maxConcurrentTransfers": 4, "uploadLimitKBs": 10, "downloadLimitKBs": 20}
            """
        try Data(json.utf8).write(to: fileURL(dir))

        let store = SettingsStore(directory: dir)
        #expect(store.visibleColumns == [.name, .size, .modified])
    }

    /// A future app version's column name (or hand-edited garbage) on disk
    /// is dropped silently rather than crashing or surfacing garbage.
    @Test func unrecognizedColumnNamesOnDiskAreDroppedSilently() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = """
            {"visibleColumns": ["name", "owner", "futureColumn"]}
            """
        try Data(json.utf8).write(to: fileURL(dir))

        let store = SettingsStore(directory: dir)
        #expect(store.visibleColumns == [.name, .owner])
    }

    @Test func visibleColumnsSurvivesAlongsideUnknownKeys() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = """
            {"maxConcurrentTransfers": 4, "futureFeatureEnabled": true, "futureLabel": "keep-me"}
            """
        try Data(json.utf8).write(to: fileURL(dir))

        let store = SettingsStore(directory: dir)
        store.visibleColumns = [.name, .type]

        let data = try Data(contentsOf: fileURL(dir))
        let raw = try JSONDecoder().decode([String: JSONValue].self, from: data)
        #expect(raw["futureFeatureEnabled"] == .bool(true))
        #expect(raw["futureLabel"] == .string("keep-me"))
        #expect(raw["visibleColumns"] == .array([.string("name"), .string("type")]))
    }

    @Test func selectedLanguageDefaultsToSystem() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        #expect(store.selectedLanguage == .system)
        #expect(AppLanguage.system.localeCode == nil)
        #expect(AppLanguage.fr.localeCode == "fr")
    }

    @Test func selectedLanguageRoundtrips() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        store.selectedLanguage = .pl
        let reloaded = SettingsStore(directory: dir)
        #expect(reloaded.selectedLanguage == .pl)
    }

    @Test func selectedLanguageFallsBackOnGarbage() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        store.selectedLanguage = .de
        // Corrupt the on-disk value, then a fresh load must fall back.
        let fileURL = dir.appendingPathComponent("settings.json")
        var raw = try! JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as! [String: Any]
        raw["appLanguage"] = "klingon"
        try! JSONSerialization.data(withJSONObject: raw).write(to: fileURL)
        let reloaded = SettingsStore(directory: dir)
        #expect(reloaded.selectedLanguage == .system)
    }

    // MARK: - Presigned share link default expiry (M14 Task 4)

    @Test func presignedDefaultExpiryDefaultsToOneHourAndRoundtrips() {
        #expect(PresignedExpiry.oneHour.seconds == 3600)
        #expect(PresignedExpiry.sevenDays.seconds == 604_800)

        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        #expect(store.presignedDefaultExpiry == .oneHour)

        store.presignedDefaultExpiry = .oneDay
        let reloaded = SettingsStore(directory: dir)
        #expect(reloaded.presignedDefaultExpiry == .oneDay)
    }

    /// An unrecognized raw expiry string (future app version, or hand-edited
    /// garbage) must read as the safe default `.oneHour` — same pattern as
    /// `terminalCursorStyleUnknownRawValueReadsAsBlock`.
    @Test func presignedDefaultExpiryUnknownRawValueReadsAsOneHour() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = """
            {"presignedDefaultExpiry": "weird"}
            """
        try Data(json.utf8).write(to: fileURL(dir))

        let store = SettingsStore(directory: dir)
        #expect(store.presignedDefaultExpiry == .oneHour)
    }

    @Test func loadingOldSettingsFileWithoutPresignedDefaultExpiryKeyUsesDefault() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = """
            {"maxConcurrentTransfers": 4, "uploadLimitKBs": 10, "downloadLimitKBs": 20}
            """
        try Data(json.utf8).write(to: fileURL(dir))

        let store = SettingsStore(directory: dir)
        #expect(store.presignedDefaultExpiry == .oneHour)
    }

    // MARK: - Connection liveness settings

    /// Asserts through the persisted file, not just the getter: the getter
    /// re-clamps independently, so a setter that forgot to clamp would
    /// still read back clamped and this test would miss it (see
    /// `persistedRaw`'s doc comment).
    @Test func theKeepAliveIntervalIsClampedOnBothEnds() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)

        store.keepAliveIntervalSeconds = 5
        #expect(store.keepAliveIntervalSeconds == 15)
        #expect(try persistedRaw(dir)["keepAliveIntervalSeconds"] == .number(15))

        // `0` used to be the sentinel for "off"; "off" is now
        // `keepAliveEnabled`'s own Bool, so `0` is just another value below
        // the floor and clamps like anything else.
        store.keepAliveIntervalSeconds = 0
        #expect(store.keepAliveIntervalSeconds == 15)
        #expect(try persistedRaw(dir)["keepAliveIntervalSeconds"] == .number(15))

        store.keepAliveIntervalSeconds = 9_999
        #expect(store.keepAliveIntervalSeconds == 600)
        #expect(try persistedRaw(dir)["keepAliveIntervalSeconds"] == .number(600))
    }

    @Test func keepAliveIntervalSecondsDefaultsToSixtyAndClampsZeroOnWrite() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        #expect(store.keepAliveIntervalSeconds == 60)

        store.keepAliveIntervalSeconds = 0
        let reloaded = SettingsStore(directory: dir)
        #expect(reloaded.keepAliveIntervalSeconds == 15)
    }

    /// Pins `SettingsStore.defaultKeepAliveIntervalSeconds` (Task 9's
    /// Settings UI resumes the Keep-Alive stepper at this value when the
    /// probe is turned back on from "off") against a FRESH store's own
    /// default — same tie, and same reason to pin it, as
    /// `defaultConnectTimeoutSecondsMatchesAFreshStore` below.
    @Test func defaultKeepAliveIntervalSecondsMatchesAFreshStore() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        #expect(SettingsStore.defaultKeepAliveIntervalSeconds == store.keepAliveIntervalSeconds)
    }

    // MARK: - keepAliveEnabled (2026-09-02: two settings, not one sentinel)

    @Test func keepAliveEnabledDefaultsTrueAndRoundtrips() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        #expect(store.keepAliveEnabled == true)

        store.keepAliveEnabled = false
        #expect(try persistedRaw(dir)["keepAliveEnabled"] == .bool(false))
        let reloadedOff = SettingsStore(directory: dir)
        #expect(reloadedOff.keepAliveEnabled == false)

        store.keepAliveEnabled = true
        #expect(try persistedRaw(dir)["keepAliveEnabled"] == .bool(true))
        let reloadedOn = SettingsStore(directory: dir)
        #expect(reloadedOn.keepAliveEnabled == true)
    }

    /// Read-side migration: a file written before 2026-09-02 stored "off" as
    /// `keepAliveIntervalSeconds == 0` and had no `keepAliveEnabled` key at
    /// all. Opening it must read `keepAliveEnabled == false` without
    /// rewriting anything — the file on disk stays byte-for-byte the same
    /// until the user actually changes a setting.
    @Test func oldOffFileWithoutKeepAliveEnabledKeyMigratesOnRead() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = #"{"keepAliveIntervalSeconds": 0}"#
        try Data(json.utf8).write(to: fileURL(dir))
        let beforeRead = try Data(contentsOf: fileURL(dir))

        let store = SettingsStore(directory: dir)
        #expect(store.keepAliveEnabled == false)
        #expect(store.keepAliveIntervalSeconds == 60)

        let afterRead = try Data(contentsOf: fileURL(dir))
        #expect(afterRead == beforeRead)
    }

    /// Once both keys are on disk, `keepAliveEnabled` wins outright — the
    /// migration fallback only applies when the key is ABSENT. A stored `0`
    /// is the retired sentinel, not an interval, whether or not
    /// `keepAliveEnabled` is present: it reads as the default `60`, exactly
    /// like the absent-key case above, not as a second way to spell "off".
    @Test func explicitKeepAliveEnabledKeyWinsOverStoredZeroInterval() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = #"{"keepAliveIntervalSeconds": 0, "keepAliveEnabled": true}"#
        try Data(json.utf8).write(to: fileURL(dir))

        let store = SettingsStore(directory: dir)
        #expect(store.keepAliveEnabled == true)
        #expect(store.keepAliveIntervalSeconds == 60)
    }

    /// Asserts through the persisted file, not just the getter — see
    /// `theKeepAliveIntervalIsClampedOnBothEnds`'s comment for why.
    @Test func theConnectTimeoutIsClampedAndDefaultsBelowCitadelsThirty() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        #expect(store.connectTimeoutSeconds == 10)

        store.connectTimeoutSeconds = 1
        #expect(store.connectTimeoutSeconds == 5)
        #expect(try persistedRaw(dir)["connectTimeoutSeconds"] == .number(5))

        store.connectTimeoutSeconds = 10_000
        #expect(store.connectTimeoutSeconds == 120)
        #expect(try persistedRaw(dir)["connectTimeoutSeconds"] == .number(120))
    }

    @Test func connectTimeoutSecondsRoundtrips() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        store.connectTimeoutSeconds = 45
        let reloaded = SettingsStore(directory: dir)
        #expect(reloaded.connectTimeoutSeconds == 45)
    }

    /// Pins `SettingsStore.defaultConnectTimeoutSeconds` (the constant
    /// `MacSCPCLI/SessionConnecting.swift` falls back to, having no
    /// `SettingsStore` of its own) against a FRESH store's own default —
    /// the two are the same underlying value by construction
    /// (`defaultConnectTimeoutSeconds = Defaults.connectTimeoutSeconds`),
    /// but nothing else in the suite exercises that tie, so a future edit
    /// that quietly re-literals one of them would otherwise go unnoticed.
    @Test func defaultConnectTimeoutSecondsMatchesAFreshStore() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        #expect(SettingsStore.defaultConnectTimeoutSeconds == store.connectTimeoutSeconds)
    }

    @Test func reconnectDefaultsToOfferingOnly() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(SettingsStore(directory: dir).reconnectBehaviour == .offerOnly)
    }

    @Test func reconnectBehaviourRoundtrips() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        store.reconnectBehaviour = .automatic
        let reloaded = SettingsStore(directory: dir)
        #expect(reloaded.reconnectBehaviour == .automatic)
    }

    /// An unrecognized raw behaviour string (future app version, or
    /// hand-edited garbage) must read as the safe default `.offerOnly` —
    /// same pattern as `selectedLanguageFallsBackOnGarbage`.
    @Test func reconnectBehaviourUnknownRawValueReadsAsOfferOnly() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = """
            {"reconnectBehaviour": "weird"}
            """
        try Data(json.utf8).write(to: fileURL(dir))

        let store = SettingsStore(directory: dir)
        #expect(store.reconnectBehaviour == .offerOnly)
    }

    // MARK: - Sidebar width

    /// A `settings.json` predating this feature has no width in it at all,
    /// and must keep opening the sidebar exactly as wide as it always did.
    @Test func sidebarWidthDefaultsToTheWidthTheSidebarAlwaysOpenedAt() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(SettingsStore(directory: dir).sidebarWidth == 190)
    }

    /// Asserts through the persisted file, not just the getter — see
    /// `theKeepAliveIntervalIsClampedOnBothEnds`'s comment for why.
    @Test func theSidebarWidthIsClampedOnBothEnds() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)

        store.sidebarWidth = 10
        #expect(store.sidebarWidth == 170)
        #expect(try persistedRaw(dir)["sidebarWidth"] == .number(170))

        store.sidebarWidth = 4_000
        #expect(store.sidebarWidth == 340)
        #expect(try persistedRaw(dir)["sidebarWidth"] == .number(340))
    }

    /// The getter's own clamp, reached the only way that skips the setter:
    /// a width typed straight into the file by hand. Both ends in one test,
    /// because a getter that clamps one end only is the failure this pins.
    @Test func sidebarWidthClampsWhatWasTypedIntoTheFileByHand() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        try Data(#"{"sidebarWidth": 1}"#.utf8).write(to: fileURL(dir))
        #expect(SettingsStore(directory: dir).sidebarWidth == 170)

        try Data(#"{"sidebarWidth": 9000}"#.utf8).write(to: fileURL(dir))
        #expect(SettingsStore(directory: dir).sidebarWidth == 340)
    }

    @Test func sidebarWidthRoundtrips() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        store.sidebarWidth = 275
        let reloaded = SettingsStore(directory: dir)
        #expect(reloaded.sidebarWidth == 275)
    }

    /// Pins the bounds the view reads (`SettingsStore.sidebarWidthRange`,
    /// which is what the sidebar's own frame is built from) against the
    /// clamp the store applies. The two are the same range by construction;
    /// nothing else in the suite ties them, so a future edit that re-literals
    /// the frame's end of it would otherwise go unnoticed.
    @Test func sidebarWidthRangeMatchesWhatTheStoreClampsTo() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)

        store.sidebarWidth = Int.min
        #expect(store.sidebarWidth == SettingsStore.sidebarWidthRange.lowerBound)

        store.sidebarWidth = Int.max
        #expect(store.sidebarWidth == SettingsStore.sidebarWidthRange.upperBound)
    }

    // MARK: - Checksum algorithm (file checksums, Task 4)

    /// SHA-256 is the default, and it is the algorithm's own `preferred`
    /// rather than a second copy of that decision here.
    @Test func checksumAlgorithmDefaultsToTheAlgorithmsOwnPreference() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)

        #expect(store.checksumAlgorithm == ChecksumAlgorithm.preferred)
        #expect(store.checksumAlgorithm == .sha256)
    }

    @Test func checksumAlgorithmRoundtripsThroughTheFile() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)

        store.checksumAlgorithm = .md5
        let reloaded = SettingsStore(directory: dir)
        #expect(reloaded.checksumAlgorithm == .md5)
    }

    /// An unrecognized raw value reads as the preferred algorithm rather
    /// than as a broken one — the same fallback shape as
    /// `presignedDefaultExpiryUnknownRawValueReadsAsOneHour`, and here it
    /// matters more: falling back to MD5 would silently downgrade what the
    /// app computes.
    @Test func checksumAlgorithmUnknownRawValueReadsAsThePreferredOne() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"checksumAlgorithm": "crc32"}"#.utf8).write(to: fileURL(dir))

        #expect(SettingsStore(directory: dir).checksumAlgorithm == ChecksumAlgorithm.preferred)
    }

    @Test func aSettingsFileWithoutTheKeyUsesThePreferredAlgorithm() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"maxConcurrentTransfers": 4}"#.utf8).write(to: fileURL(dir))

        #expect(SettingsStore(directory: dir).checksumAlgorithm == ChecksumAlgorithm.preferred)
    }
}
