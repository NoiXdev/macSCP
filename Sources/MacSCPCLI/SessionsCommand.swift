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

    @OptionGroup var options: JSONOptions

    @Option(name: .long, help: "Only sessions in this group or one of its subgroups.")
    var group: String?

    @Option(name: .long, help: "Only this backend.")
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
}

/// `sessions` reads no secret, resolves no login set and opens no
/// connection — so `GlobalOptions`' other flags (`--verbose`,
/// `--non-interactive`, `--accept-new`, `--password-command`) describe
/// choices this command never makes. Handing it the whole of
/// `GlobalOptions` anyway advertised all four in `sessions --help`, on the
/// one command whose entire point is that none of them apply
/// (final-branch-review finding, 2026-09-02). `--json`'s help text is
/// copied verbatim from `GlobalOptions.json` rather than shared, the same
/// way `ConflictAction`'s and `ConnectionKind`'s `ExpressibleByArgument`
/// conformances live as siblings rather than a shared base — the two
/// options happen to agree today, not because one is defined in terms of
/// the other.
struct JSONOptions: ParsableArguments {
    @Flag(name: .long, help: "Emit one JSON object per line instead of columns.")
    var json = false

    init() {}
}
