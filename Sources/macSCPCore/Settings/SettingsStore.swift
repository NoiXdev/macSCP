import Foundation
import Observation

/// Minimal JSON value type for `SettingsStore`'s raw backing.
///
/// Used exclusively internally to achieve forward compatibility: keys this
/// app version doesn't know about are kept here as `JSONValue` and written
/// back unchanged when saving.
enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

/// Central app settings. JSON in `<directory>/settings.json` —
/// FORWARD-COMPATIBLE: unknown keys are preserved when saving (round-tripped
/// through a raw `[String: JSONValue]` backing, with typed accessors on top).
/// Not a secret store.
@Observable
@MainActor
public final class SettingsStore {
    private enum Keys {
        static let maxConcurrentTransfers = "maxConcurrentTransfers"
        static let uploadLimitKBs = "uploadLimitKBs"
        static let downloadLimitKBs = "downloadLimitKBs"
        static let defaultEditorPath = "defaultEditorPath"
        static let fileAssociations = "fileAssociations"
        static let showHiddenFiles = "showHiddenFiles"
        static let autoRefreshEnabled = "autoRefreshEnabled"
        static let autoRefreshIntervalSeconds = "autoRefreshIntervalSeconds"
        static let terminalFontName = "terminalFontName"
        static let terminalFontSize = "terminalFontSize"
        static let terminalCursorStyle = "terminalCursorStyle"
        static let terminalCursorBlink = "terminalCursorBlink"
    }

    private enum Defaults {
        static let maxConcurrentTransfers = 3
        static let uploadLimitKBs = 0
        static let downloadLimitKBs = 0
        static let showHiddenFiles = false
        static let autoRefreshEnabled = true
        static let autoRefreshIntervalSeconds = 5
        static let terminalFontSize = 13
        static let terminalCursorStyle = TerminalCursorStyle.block
        static let terminalCursorBlink = true
    }

    /// Identical to `SessionStore.defaultDirectory` — both stores share the
    /// app support directory, but each has its own file.
    public static let defaultDirectory: URL = SessionStore.defaultDirectory

    private let directory: URL

    /// Raw backing, loaded directly from the file. Unknown keys are left
    /// untouched here and get written back out on every `persist()`.
    private var raw: [String: JSONValue]

    private var fileURL: URL {
        directory.appendingPathComponent("settings.json")
    }

    /// Loads immediately from `<directory>/settings.json`. If the file is
    /// missing or unreadable/not valid JSON, the defaults apply (no crash) —
    /// the file is only replaced on the next save.
    public init(directory: URL) {
        self.directory = directory
        self.raw = Self.loadRaw(from: directory)
    }

    private static func loadRaw(from directory: URL) -> [String: JSONValue] {
        let fileURL = directory.appendingPathComponent("settings.json")
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
            return [:]
        }
        guard let data = try? Data(contentsOf: fileURL),
            let decoded = try? JSONDecoder().decode([String: JSONValue].self, from: data)
        else {
            return [:]
        }
        return decoded
    }

    // MARK: - Typed accessors

    /// Maximum concurrent transfers (clamped to 1...8, default 3).
    public var maxConcurrentTransfers: Int {
        get { clamp(intValue(for: Keys.maxConcurrentTransfers, default: Defaults.maxConcurrentTransfers), 1, 8) }
        set { setInt(clamp(newValue, 1, 8), for: Keys.maxConcurrentTransfers) }
    }

    /// Upload bandwidth limit in KB/s; 0 = unlimited (default 0). Clamped >= 0.
    public var uploadLimitKBs: Int {
        get { clamp(intValue(for: Keys.uploadLimitKBs, default: Defaults.uploadLimitKBs), 0, .max) }
        set { setInt(clamp(newValue, 0, .max), for: Keys.uploadLimitKBs) }
    }

    /// Download bandwidth limit in KB/s; 0 = unlimited (default 0). Clamped >= 0.
    public var downloadLimitKBs: Int {
        get { clamp(intValue(for: Keys.downloadLimitKBs, default: Defaults.downloadLimitKBs), 0, .max) }
        set { setInt(clamp(newValue, 0, .max), for: Keys.downloadLimitKBs) }
    }

    /// Absolute path to the .app bundle used as the default editor for remote
    /// files; nil/empty = use the macOS system association. Persisted.
    public var defaultEditorPath: String? {
        get {
            guard case .string(let value)? = raw[Keys.defaultEditorPath], !value.isEmpty else {
                return nil
            }
            return value
        }
        set {
            if let newValue, !newValue.isEmpty {
                raw[Keys.defaultEditorPath] = .string(newValue)
            } else {
                raw[Keys.defaultEditorPath] = nil
            }
            persist()
        }
    }

    /// Per-extension overrides: normalized extension (lowercase, no leading
    /// dot, trimmed) -> absolute .app path. Assigning an empty app path for an
    /// extension removes that rule instead of storing it. Empty/whitespace-only
    /// extensions are ignored on write.
    public var fileAssociations: [String: String] {
        get {
            guard case .object(let entries)? = raw[Keys.fileAssociations] else { return [:] }
            var result: [String: String] = [:]
            for (rawExtension, value) in entries {
                guard case .string(let appPath) = value else { continue }
                let normalizedExtension = Self.normalizeExtension(rawExtension)
                guard !normalizedExtension.isEmpty else { continue }
                result[normalizedExtension] = appPath
            }
            return result
        }
        set {
            var normalized: [String: JSONValue] = [:]
            for (rawExtension, appPath) in newValue {
                let normalizedExtension = Self.normalizeExtension(rawExtension)
                guard !normalizedExtension.isEmpty, !appPath.isEmpty else { continue }
                normalized[normalizedExtension] = .string(appPath)
            }
            raw[Keys.fileAssociations] = normalized.isEmpty ? nil : .object(normalized)
            persist()
        }
    }

    /// Show dotfiles in both panes (M7a). Default OFF — the Finder-like
    /// default; ⌘⇧. and the General settings tab toggle it.
    public var showHiddenFiles: Bool {
        get { boolValue(for: Keys.showHiddenFiles, default: Defaults.showHiddenFiles) }
        set { setBool(newValue, for: Keys.showHiddenFiles) }
    }

    /// Auto-refresh of the active tab's remote pane (M9c). Default ON.
    public var autoRefreshEnabled: Bool {
        get { boolValue(for: Keys.autoRefreshEnabled, default: Defaults.autoRefreshEnabled) }
        set { setBool(newValue, for: Keys.autoRefreshEnabled) }
    }

    /// Interval in seconds, clamped to 2...300 on BOTH ends so a hand-edited
    /// settings.json cannot produce SFTP spam or a dead timer.
    public var autoRefreshIntervalSeconds: Int {
        get {
            clamp(
                intValue(for: Keys.autoRefreshIntervalSeconds, default: Defaults.autoRefreshIntervalSeconds),
                2, 300)
        }
        set { setInt(clamp(newValue, 2, 300), for: Keys.autoRefreshIntervalSeconds) }
    }

    /// Custom terminal font family name (M9d); nil/empty = use the system
    /// monospaced default. Persisted like `defaultEditorPath`.
    public var terminalFontName: String? {
        get { stringValue(for: Keys.terminalFontName) }
        set { setString(newValue, for: Keys.terminalFontName) }
    }

    /// Terminal font point size, clamped to 9...24 on BOTH ends (default 13)
    /// — same forward-compat pattern as `autoRefreshIntervalSeconds`: a
    /// hand-edited settings.json cannot produce an unreadable terminal.
    public var terminalFontSize: Int {
        get {
            clamp(
                intValue(for: Keys.terminalFontSize, default: Defaults.terminalFontSize),
                9, 24)
        }
        set { setInt(clamp(newValue, 9, 24), for: Keys.terminalFontSize) }
    }

    /// Terminal cursor shape (M9d). An unrecognized raw value on disk
    /// (future app version, or hand-edited garbage) reads as `.block`
    /// instead of crashing or propagating `nil`.
    public var terminalCursorStyle: TerminalCursorStyle {
        get {
            guard case .string(let value)? = raw[Keys.terminalCursorStyle] else {
                return Defaults.terminalCursorStyle
            }
            return TerminalCursorStyle(rawValue: value) ?? .block
        }
        set {
            raw[Keys.terminalCursorStyle] = .string(newValue.rawValue)
            persist()
        }
    }

    /// Whether the terminal cursor blinks (M9d). Default ON.
    public var terminalCursorBlink: Bool {
        get { boolValue(for: Keys.terminalCursorBlink, default: Defaults.terminalCursorBlink) }
        set { setBool(newValue, for: Keys.terminalCursorBlink) }
    }

    /// Convenience: association lookup with the SAME normalization applied.
    public func associatedApp(forExtension ext: String) -> String? {
        let normalizedExtension = Self.normalizeExtension(ext)
        guard !normalizedExtension.isEmpty else { return nil }
        return fileAssociations[normalizedExtension]
    }

    /// Normalizes a file extension for use as a `fileAssociations` key:
    /// trims whitespace, strips a single leading dot, and lowercases.
    private static func normalizeExtension(_ ext: String) -> String {
        var trimmed = ext.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(".") {
            trimmed.removeFirst()
        }
        return trimmed.lowercased()
    }

    // MARK: - Backing access

    private func intValue(for key: String, default defaultValue: Int) -> Int {
        guard case .number(let value)? = raw[key] else {
            return defaultValue
        }
        return Int(value)
    }

    private func setInt(_ value: Int, for key: String) {
        raw[key] = .number(Double(value))
        persist()
    }

    private func clamp(_ value: Int, _ lower: Int, _ upper: Int) -> Int {
        min(max(value, lower), upper)
    }

    /// Generic string-optional backing (same nil/empty-collapsing rule as
    /// `defaultEditorPath`'s hand-rolled getter/setter): empty and missing
    /// both read as `nil`, and setting `nil` or "" clears the key.
    private func stringValue(for key: String) -> String? {
        guard case .string(let value)? = raw[key], !value.isEmpty else {
            return nil
        }
        return value
    }

    private func setString(_ value: String?, for key: String) {
        if let value, !value.isEmpty {
            raw[key] = .string(value)
        } else {
            raw[key] = nil
        }
        persist()
    }

    private func boolValue(for key: String, default defaultValue: Bool) -> Bool {
        guard case .bool(let value)? = raw[key] else {
            return defaultValue
        }
        return value
    }

    private func setBool(_ value: Bool, for key: String) {
        raw[key] = .bool(value)
        persist()
    }

    /// Writes the entire raw backing (including unknown keys) back out
    /// synchronously — mirroring `SessionStore`'s save approach. Creates the
    /// directory if needed; write errors are swallowed (setters can't throw
    /// per the public interface).
    private func persist() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(raw) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
