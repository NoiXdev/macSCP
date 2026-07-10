import Foundation

/// An imported host from ~/.ssh/config (only the fields relevant to macSCP).
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

/// Pure parser for the OpenSSH config format (read-only, YAGNI boundaries:
/// no Match/Include, no wildcard inheritance — such blocks are skipped).
public enum SSHConfigParser {
    public static func parse(_ text: String) -> [SSHConfigHost] {
        var blocks: [(aliases: [String], settings: [String: String])] = []
        var inIgnoredBlock = false   // Match block or similar

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
                // ssh semantics: the first value wins
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

    /// Splits "Keyword Value" or "Keyword=Value" (with arbitrary whitespace around '=').
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

/// Loads and sorts the importable hosts. A missing file is not an error.
public enum SSHConfigImporter {
    public static var defaultPath: String {
        NSHomeDirectory() + "/.ssh/config"
    }

    public static func load(path: String) -> [SSHConfigHost] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return []
        }
        // First block wins (ssh precedence); this also prevents duplicate
        // SwiftUI ids in the sidebar.
        var seen = Set<String>()
        let unique = SSHConfigParser.parse(text).filter { seen.insert($0.alias).inserted }
        return unique.sorted {
            $0.alias.localizedCaseInsensitiveCompare($1.alias) == .orderedAscending
        }
    }
}
