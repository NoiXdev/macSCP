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
}
