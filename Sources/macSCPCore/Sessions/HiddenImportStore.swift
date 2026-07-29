import Foundation

/// JSON persistence for aliases the user chose to hide from the imported
/// `~/.ssh/config` list (M11f). Only the alias string is stored — never a
/// copy of the imported host's other fields — so this store can never
/// become a second, staler copy of the config file it is layered over.
///
/// Follows the `LoginSetStore` pattern: stateless, atomic writes.
public struct HiddenImportStore: Sendable {
    private struct StoreFile: Codable {
        var aliases: [String] = []

        // Custom decoding: Swift's synthesized Decodable does not fall
        // back to a property's default value for a missing key, but this
        // store must tolerate a bare `{}` (and any future unknown field)
        // as an empty file.
        private enum CodingKeys: String, CodingKey { case aliases }

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            aliases = try container.decodeIfPresent([String].self, forKey: .aliases) ?? []
        }
    }

    private let directory: URL
    public init(directory: URL) { self.directory = directory }
    private var fileURL: URL { directory.appendingPathComponent("hidden-imports.json") }

    private func load() throws -> StoreFile {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
            return StoreFile()
        }
        return try JSONDecoder().decode(StoreFile.self, from: Data(contentsOf: fileURL))
    }

    private func persist(_ file: StoreFile) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(file).write(to: fileURL, options: .atomic)
    }

    /// All hidden aliases, sorted case-insensitively for stable display.
    public func allHidden() throws -> [String] {
        try load().aliases.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    /// Hides an alias. Idempotent: hiding an already-hidden alias is a no-op.
    public func hide(_ alias: String) throws {
        var file = try load()
        guard !file.aliases.contains(alias) else { return }
        file.aliases.append(alias)
        try persist(file)
    }

    /// Unhides an alias. Unhiding an alias that was never hidden does not
    /// throw and leaves the store unchanged.
    public func unhide(_ alias: String) throws {
        var file = try load()
        guard let index = file.aliases.firstIndex(of: alias) else { return }
        file.aliases.remove(at: index)
        try persist(file)
    }

    /// Whether `alias` is hidden. Comparison is exact: ssh treats `Host`
    /// aliases as exact strings, and a case-insensitive rule here would
    /// hide entries the user never meant to hide.
    public func isHidden(_ alias: String) throws -> Bool {
        try load().aliases.contains(alias)
    }
}

/// Splits imported `~/.ssh/config` hosts into what should be shown and what
/// should stay hidden, given the set of aliases the user chose to hide.
public enum ImportedHostPartition {
    /// - `visible`: hosts whose alias is not in `hiddenAliases`, in the
    ///   input order (the importer already sorts it).
    /// - `hidden`: hosts whose alias is in `hiddenAliases`.
    /// - `orphaned`: hidden aliases with no matching host anymore (e.g. the
    ///   entry was renamed or removed from the config file), alphabetically
    ///   sorted.
    public struct Result: Equatable, Sendable {
        public let visible: [SSHConfigHost]
        public let hidden: [SSHConfigHost]
        public let orphaned: [String]
    }

    /// Pure: no file access. `hiddenAliases` is compared exactly, matching
    /// `HiddenImportStore.isHidden`'s exact-string semantics.
    public static func split(hosts: [SSHConfigHost], hiddenAliases: [String]) -> Result {
        let hiddenSet = Set(hiddenAliases)
        var visible: [SSHConfigHost] = []
        var hidden: [SSHConfigHost] = []
        var matchedAliases = Set<String>()

        for host in hosts {
            if hiddenSet.contains(host.alias) {
                hidden.append(host)
                matchedAliases.insert(host.alias)
            } else {
                visible.append(host)
            }
        }

        let orphaned = hiddenSet.subtracting(matchedAliases).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }

        return Result(visible: visible, hidden: hidden, orphaned: orphaned)
    }
}
