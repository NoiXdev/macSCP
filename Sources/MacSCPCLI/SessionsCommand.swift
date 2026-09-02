import ArgumentParser
import Foundation
import macSCPCore

/// Lists the saved sessions — filterable by group, kind, name and tag.
/// Reads `SessionStore` only: no secret, no keychain, no connection. Every
/// other subcommand opens a connection and therefore resolves a secret;
/// this one exists precisely so a user (or a script) can see what is
/// stored WITHOUT doing either.
struct SessionsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sessions",
        abstract: "List the saved sessions.",
        discussion: """
            Every other command addresses a session as name:/path — the name \
            is the first column here. Filters combine; --name matches a \
            case-insensitive substring, not a pattern. Nothing here reads \
            the keychain or opens a connection.
            """)

    @OptionGroup var options: GlobalOptions

    @Option(name: .long, help: "Only sessions in this group or one of its subgroups.")
    var group: String?

    @Option(name: .long, help: "Only this backend: \(Self.kindHelpList).")
    var kind: ConnectionKind?

    @Option(name: .long, help: "Only names containing this text (case-insensitive substring).")
    var name: String?

    @Option(name: .long, help: "Only sessions carrying this tag.")
    var tag: String?

    func run() async throws {
        let store = SessionStore(directory: SessionStore.defaultDirectory)
        let catalog = SessionCatalog(sessions: try store.all(), groups: try store.allGroups())
        let rows = catalog.rows(matching: .init(group: group, kind: kind, name: name, tag: tag))
        OutputFormatter.print(rows: rows, asJSON: options.json)
    }

    /// "ssh, s3 or webdav" — derived from `ConnectionKind.allCases` rather
    /// than hand-typed, so `--kind`'s help text cannot drift out of sync
    /// with the enum the way a second, hardcoded copy of its cases already
    /// did once (review of this task's first version). `ConnectionKind`'s
    /// own doc comment calls it "open for future protocols", so a fourth
    /// case is exactly the kind of change this guards against.
    fileprivate static var kindHelpList: String {
        Self.naturalList(ConnectionKind.allCases.map(\.rawValue))
    }

    /// `["ssh", "s3", "webdav"]` -> `"ssh, s3 or webdav"`; two items join as
    /// `"a or b"` with no comma; one item is itself; zero is `""` (never hit
    /// today, but a partial list reads as a worse bug than an empty one).
    fileprivate static func naturalList(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        default: return items.dropLast().joined(separator: ", ") + " or " + items.last!
        }
    }
}
