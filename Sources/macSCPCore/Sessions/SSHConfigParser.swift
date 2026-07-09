import Foundation

/// Ein importierter Host aus ~/.ssh/config (nur die für macSCP relevanten Felder).
public struct SSHConfigHost: Equatable, Sendable {
    public let alias: String
    public let hostName: String?
    public let user: String?
    public let port: Int?
    public let identityFile: String?

    public init(alias: String, hostName: String?, user: String?,
                port: Int?, identityFile: String?) {
        self.alias = alias
        self.hostName = hostName
        self.user = user
        self.port = port
        self.identityFile = identityFile
    }
}

/// Purer Parser für das OpenSSH-config-Format (lesend, YAGNI-Grenzen:
/// kein Match/Include, keine Wildcard-Vererbung — solche Blöcke werden übersprungen).
public enum SSHConfigParser {
    public static func parse(_ text: String) -> [SSHConfigHost] {
        var blocks: [(aliases: [String], settings: [String: String])] = []
        var inIgnoredBlock = false   // Match-Block o.ä.

        for rawLine in text.components(separatedBy: .newlines) {
            var line = rawLine
            if let hash = line.firstIndex(of: "#") {
                line = String(line[..<hash])
            }
            line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            guard let (keyword, value) = splitKeywordValue(line) else { continue }
            switch keyword.lowercased() {
            case "host":
                inIgnoredBlock = false
                let aliases = value.split(separator: " ").map(String.init)
                blocks.append((aliases: aliases, settings: [:]))
            case "match":
                inIgnoredBlock = true
            default:
                guard !inIgnoredBlock, !blocks.isEmpty else { continue }
                let key = keyword.lowercased()
                // ssh-Semantik: der erste Wert gewinnt
                if blocks[blocks.count - 1].settings[key] == nil {
                    blocks[blocks.count - 1].settings[key] = unquote(value)
                }
            }
        }

        var results: [SSHConfigHost] = []
        for block in blocks {
            for alias in block.aliases {
                guard !alias.contains("*"), !alias.contains("?"),
                      !alias.hasPrefix("!") else { continue }
                results.append(SSHConfigHost(
                    alias: alias,
                    hostName: block.settings["hostname"],
                    user: block.settings["user"],
                    port: block.settings["port"].flatMap(Int.init),
                    identityFile: block.settings["identityfile"]
                ))
            }
        }
        return results
    }

    /// Trennt "Keyword Wert" bzw. "Keyword=Wert" (mit beliebigem Whitespace um '=').
    private static func splitKeywordValue(_ line: String) -> (String, String)? {
        let separators = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "="))
        guard let range = line.rangeOfCharacter(from: separators) else { return nil }
        let keyword = String(line[..<range.lowerBound])
        var value = String(line[range.lowerBound...])
        value = value.trimmingCharacters(in: separators)
        guard !keyword.isEmpty, !value.isEmpty else { return nil }
        return (keyword, value)
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else {
            return value
        }
        return String(value.dropFirst().dropLast())
    }
}

/// Lädt und sortiert die importierbaren Hosts. Fehlende Datei ist kein Fehler.
public enum SSHConfigImporter {
    public static var defaultPath: String {
        NSHomeDirectory() + "/.ssh/config"
    }

    public static func load(path: String) -> [SSHConfigHost] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return []
        }
        // Erster Block gewinnt (ssh-Präzedenz); verhindert zugleich doppelte
        // SwiftUI-IDs in der Sidebar.
        var seen = Set<String>()
        let unique = SSHConfigParser.parse(text).filter { seen.insert($0.alias).inserted }
        return unique.sorted {
            $0.alias.localizedCaseInsensitiveCompare($1.alias) == .orderedAscending
        }
    }
}
