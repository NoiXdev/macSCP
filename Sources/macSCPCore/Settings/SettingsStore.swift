import Foundation
import Observation

/// Minimaler JSON-Werttyp für das rohe Backing von `SettingsStore`.
///
/// Wird ausschließlich intern genutzt, um Vorwärtskompatibilität zu erreichen:
/// Schlüssel, die diese App-Version nicht kennt, werden hier als `JSONValue`
/// gehalten und beim Speichern unverändert mit zurückgeschrieben.
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
                in: container, debugDescription: "Nicht unterstützter JSON-Wert")
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

/// Zentrale App-Einstellungen. JSON in `<directory>/settings.json` —
/// VORWÄRTSKOMPATIBEL: unbekannte Schlüssel bleiben beim Speichern erhalten
/// (Roundtrip über ein rohes `[String: JSONValue]`-Backing, typisierte
/// Accessoren obendrauf). Kein Geheimnis-Speicher.
@Observable
@MainActor
public final class SettingsStore {
    private enum Keys {
        static let maxConcurrentTransfers = "maxConcurrentTransfers"
        static let uploadLimitKBs = "uploadLimitKBs"
        static let downloadLimitKBs = "downloadLimitKBs"
    }

    private enum Defaults {
        static let maxConcurrentTransfers = 3
        static let uploadLimitKBs = 0
        static let downloadLimitKBs = 0
    }

    /// Identisch zu `SessionStore.defaultDirectory` — beide Stores teilen sich
    /// das App-Support-Verzeichnis, aber jeweils eine eigene Datei.
    public static let defaultDirectory: URL = SessionStore.defaultDirectory

    private let directory: URL

    /// Rohes Backing, direkt aus der Datei geladen. Unbekannte Schlüssel
    /// bleiben hier unangetastet liegen und werden bei jedem `persist()`
    /// wieder mit rausgeschrieben.
    private var raw: [String: JSONValue]

    private var fileURL: URL {
        directory.appendingPathComponent("settings.json")
    }

    /// Lädt sofort aus `<directory>/settings.json`. Fehlt die Datei oder ist
    /// sie nicht lesbar/kein valides JSON, gelten die Defaults (kein Crash) —
    /// die Datei wird erst beim nächsten Speichern ersetzt.
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

    // MARK: - Typisierte Accessoren

    /// Maximale gleichzeitige Übertragungen (geklemmt auf 1...8, Default 3).
    public var maxConcurrentTransfers: Int {
        get { clamp(intValue(for: Keys.maxConcurrentTransfers, default: Defaults.maxConcurrentTransfers), 1, 8) }
        set { setInt(clamp(newValue, 1, 8), for: Keys.maxConcurrentTransfers) }
    }

    /// Bandbreiten-Limit Upload in KB/s; 0 = unbegrenzt (Default 0). Geklemmt >= 0.
    public var uploadLimitKBs: Int {
        get { clamp(intValue(for: Keys.uploadLimitKBs, default: Defaults.uploadLimitKBs), 0, .max) }
        set { setInt(clamp(newValue, 0, .max), for: Keys.uploadLimitKBs) }
    }

    /// Bandbreiten-Limit Download in KB/s; 0 = unbegrenzt (Default 0). Geklemmt >= 0.
    public var downloadLimitKBs: Int {
        get { clamp(intValue(for: Keys.downloadLimitKBs, default: Defaults.downloadLimitKBs), 0, .max) }
        set { setInt(clamp(newValue, 0, .max), for: Keys.downloadLimitKBs) }
    }

    // MARK: - Backing-Zugriff

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

    /// Schreibt das komplette rohe Backing (inkl. unbekannter Schlüssel)
    /// synchron zurück — analog zur Save-Haltung von `SessionStore`. Legt das
    /// Verzeichnis bei Bedarf an; Schreibfehler werden verschluckt (Setter
    /// können laut öffentlichem Interface nicht werfen).
    private func persist() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(raw) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
