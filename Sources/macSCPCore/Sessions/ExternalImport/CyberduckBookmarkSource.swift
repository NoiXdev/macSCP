import Foundation

/// Reads Cyberduck's bookmark files: one XML property list per bookmark,
/// `<UUID>.duck`, under Cyberduck's Group Container.
///
/// Measured 2026-09-03 (`docs/superpowers/specs/2026-09-03-cyberduck-import-design.md`
/// §1): a `.duck` file is a top-level dictionary of string values (and, for
/// `Labels`, an array of strings). Keys read here: `Protocol`, `Hostname`,
/// `Port`, `UUID`, `Username`, `Nickname`, `Private Key File`, `Path`,
/// `Labels`. `Provider`, `Download Folder` and `Access Timestamp` are read
/// by Cyberduck but carry nothing macSCP needs and are ignored.
public struct CyberduckBookmarkSource: BookmarkSource {
    public static let id = "cyberduck"
    public static let displayNameKey = "import.source.cyberduck"

    public init() {}

    public func locate(home: URL) -> URL? {
        let folder = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Group Containers", isDirectory: true)
            .appendingPathComponent("G69SCX94XU.duck", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("duck", isDirectory: true)
            .appendingPathComponent("Bookmarks", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return nil }
        return folder
    }

    public func read(from folder: URL) throws -> [ExternalBookmark] {
        let files = try FileManager.default
            .contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "duck" }

        let bookmarks = files.map { Self.parse(fileAt: $0) }
        return bookmarks.sorted { lhs, rhs in
            let lhsKey = (lhs.nickname ?? "").lowercased()
            let rhsKey = (rhs.nickname ?? "").lowercased()
            if lhsKey != rhsKey { return lhsKey < rhsKey }
            return lhs.host.lowercased() < rhs.host.lowercased()
        }
    }

    private static func parse(fileAt url: URL) -> ExternalBookmark {
        let fileName = url.lastPathComponent
        guard
            let data = try? Data(contentsOf: url),
            let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil),
            let dict = plist as? [String: Any]
        else {
            return unreadableBookmark(fileName: fileName, reason: "not a property list")
        }

        let protocolName = dict["Protocol"] as? String
        let translated: ExternalProtocol
        switch protocolName {
        case "sftp": translated = .sftp
        case "s3": translated = .s3
        default: translated = .unsupported(protocolName ?? "")
        }

        let port = (dict["Port"] as? String).flatMap(Int.init)

        return ExternalBookmark(
            id: (dict["UUID"] as? String) ?? fileName,
            source: Self.id,
            nickname: dict["Nickname"] as? String,
            protocol: translated,
            host: dict["Hostname"] as? String ?? "",
            port: port,
            username: dict["Username"] as? String,
            keyPath: dict["Private Key File"] as? String,
            path: dict["Path"] as? String,
            labels: dict["Labels"] as? [String] ?? [],
            fileName: fileName,
            unreadable: nil)
    }

    private static func unreadableBookmark(fileName: String, reason: String) -> ExternalBookmark {
        ExternalBookmark(
            id: fileName,
            source: Self.id,
            nickname: nil,
            protocol: .unsupported(""),
            host: "",
            port: nil,
            username: nil,
            keyPath: nil,
            path: nil,
            labels: [],
            fileName: fileName,
            unreadable: "\(fileName): \(reason)")
    }
}
