import Foundation
import Testing
@testable import MacSCPAppKit
@testable import macSCPCore

@Suite("EditorResolver")
@MainActor
struct EditorResolverTests {
    /// Creates a directory that stands in for an installed app bundle, and
    /// removes it when the test ends.
    private func makeExistingAppPath() throws -> (path: String, cleanup: () -> Void) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("macSCP-test-\(UUID().uuidString).app")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return (url.path, { try? FileManager.default.removeItem(at: url) })
    }

    /// A store rooted in a throwaway directory. Never the real settings
    /// file — these tests write associations and a default editor, and
    /// doing that to the maintainer's own configuration would be a defect
    /// of the test suite, not of the code under test. Also returns a
    /// cleanup closure for the directory itself: `SettingsStore` never
    /// removes its own directory, so leaving that out here would leak a
    /// throwaway settings folder into the system temp directory on every
    /// test run.
    private func makeSettingsStore() throws -> (store: SettingsStore, cleanup: () -> Void) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macSCP-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (SettingsStore(directory: directory), { try? FileManager.default.removeItem(at: directory) })
    }

    private func setAssociation(
        in settings: SettingsStore, extension ext: String, path: String
    ) {
        settings.fileAssociations[ext] = path
    }

    private func setDefaultEditor(in settings: SettingsStore, path: String) {
        settings.defaultEditorPath = path
    }

    /// With nothing configured the resolver must decline, so the caller
    /// falls through to the post-download system association.
    @Test func nothingConfiguredResolvesToNil() throws {
        let settings = try makeSettingsStore()
        defer { settings.cleanup() }

        #expect(EditorResolver.applicationURL(forFileName: "notes.md", settings: settings.store) == nil)
    }

    /// A per-extension rule wins when its app still exists.
    @Test func anExtensionRuleWinsWhenItsAppExists() throws {
        let app = try makeExistingAppPath()
        defer { app.cleanup() }
        let settings = try makeSettingsStore()
        defer { settings.cleanup() }
        setAssociation(in: settings.store, extension: "md", path: app.path)

        let resolved = EditorResolver.applicationURL(forFileName: "notes.md", settings: settings.store)

        #expect(resolved?.path == app.path)
    }

    /// A rule pointing at an app that was deleted must be SKIPPED, not
    /// returned — handing the caller a path that no longer exists turns a
    /// stale setting into a failed open.
    @Test func anExtensionRuleWhoseAppIsGoneFallsThrough() throws {
        let settings = try makeSettingsStore()
        defer { settings.cleanup() }
        setAssociation(
            in: settings.store, extension: "md",
            path: "/nonexistent/\(UUID().uuidString).app")

        #expect(EditorResolver.applicationURL(forFileName: "notes.md", settings: settings.store) == nil)
    }

    /// The configured default editor covers extensions with no rule.
    @Test func theDefaultEditorCoversUnruledExtensions() throws {
        let app = try makeExistingAppPath()
        defer { app.cleanup() }
        let settings = try makeSettingsStore()
        defer { settings.cleanup() }
        setDefaultEditor(in: settings.store, path: app.path)

        let resolved = EditorResolver.applicationURL(forFileName: "notes.xyz", settings: settings.store)

        #expect(resolved?.path == app.path)
    }

    /// The rule must take precedence over the default — that ordering is the
    /// entire point of having both.
    @Test func theExtensionRuleOutranksTheDefaultEditor() throws {
        let ruled = try makeExistingAppPath()
        defer { ruled.cleanup() }
        let fallback = try makeExistingAppPath()
        defer { fallback.cleanup() }
        let settings = try makeSettingsStore()
        defer { settings.cleanup() }
        setAssociation(in: settings.store, extension: "md", path: ruled.path)
        setDefaultEditor(in: settings.store, path: fallback.path)

        let resolved = EditorResolver.applicationURL(forFileName: "notes.md", settings: settings.store)

        #expect(resolved?.path == ruled.path)
    }

    /// A file with no extension must not match a rule keyed on one.
    @Test func aFileWithoutAnExtensionDoesNotMatchARule() throws {
        let app = try makeExistingAppPath()
        defer { app.cleanup() }
        let settings = try makeSettingsStore()
        defer { settings.cleanup() }
        setAssociation(in: settings.store, extension: "md", path: app.path)

        #expect(EditorResolver.applicationURL(forFileName: "README", settings: settings.store) == nil)
    }
}
