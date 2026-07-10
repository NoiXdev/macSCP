import AppKit
import Foundation
import os
import macSCPCore

/// Resolves which application should open a downloaded remote file for
/// editing (double-click wiring, M5e/T4).
///
/// Resolution happens in TWO STAGES, split across two calls, because the
/// system association (stage 3) needs an actual local file to query while
/// the user-configured rule/default (stages 1-2) only need the file name:
///
/// 1. `settings.associatedApp(forExtension:)` — a per-extension rule.
/// 2. `settings.defaultEditorPath` — the configured default editor.
/// 3. `NSWorkspace.shared.urlForApplication(toOpen:)` — the macOS system
///    association. Queried by the caller AFTER the download completes,
///    since it needs a real local file URL (`systemApplicationURL(for:)`).
/// 4. Last resort (caller's responsibility): `NSWorkspace.shared.open(_:)`
///    on the local URL directly, letting macOS pick (or prompt for)
///    something on its own.
///
/// A configured app path that no longer exists on disk is skipped (falls
/// through to the next stage) with a single log line — not treated as fatal.
enum EditorResolver {
    private static let logger = Logger(subsystem: "dev.noidee.macscp", category: "EditorResolver")

    /// Stages 1-2 (pre-download): resolves the extension rule or the
    /// configured default editor by file name alone — no local file needs to
    /// exist yet. Returns `nil` if neither yields an app that still exists on
    /// disk, meaning the caller should fall through to the post-download
    /// system association.
    ///
    /// `@MainActor` because `SettingsStore` is — call sites (the App layer)
    /// are already on the main actor.
    @MainActor
    static func applicationURL(forFileName fileName: String, settings: SettingsStore) -> URL? {
        let ext = (fileName as NSString).pathExtension
        if let associatedPath = settings.associatedApp(forExtension: ext) {
            if FileManager.default.fileExists(atPath: associatedPath) {
                return URL(fileURLWithPath: associatedPath)
            }
            logger.warning(
                "configured file association app for '.\(ext, privacy: .public)' not found at \(associatedPath, privacy: .public); falling through"
            )
        }
        if let defaultPath = settings.defaultEditorPath {
            if FileManager.default.fileExists(atPath: defaultPath) {
                return URL(fileURLWithPath: defaultPath)
            }
            logger.warning(
                "configured default editor not found at \(defaultPath, privacy: .public); falling through"
            )
        }
        return nil
    }

    /// Stage 3 (post-download): the macOS system association for the actual
    /// local file. Only consulted when `applicationURL(forFileName:settings:)`
    /// resolved nothing.
    static func systemApplicationURL(for localURL: URL) -> URL? {
        NSWorkspace.shared.urlForApplication(toOpen: localURL)
    }
}
