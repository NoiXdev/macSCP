import ArgumentParser
import Foundation
import macSCPCore

/// The saved sessions: listing them, and creating, changing and deleting
/// one. Reads and writes `SessionStore` (and, when a session goes,
/// `TunnelStore`) — no secret, no keychain, no connection, in any verb.
///
/// `list` is the DEFAULT subcommand, so `macscp-cli sessions` and
/// `macscp-cli sessions --json --tag prod` mean exactly what they meant
/// before the group existed. That is not a courtesy: every script written
/// against this tool spells the listing without a verb, and a group that
/// required one would break all of them at once.
struct SessionsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sessions",
        abstract: "List, add, edit and remove saved sessions.",
        discussion: """
            Every other command addresses a session as name:/path — the name \
            is the first column of the listing. Names are matched without \
            case here, so a name that only differs in case from one already \
            saved is refused. Nothing in this group reads the keychain or \
            opens a connection: a session that logs in with a password is \
            asked for it by the app on first connect.
            """,
        subcommands: [
            SessionsListCommand.self, SessionsAddCommand.self,
            SessionsEditCommand.self, SessionsRemoveCommand.self,
        ],
        defaultSubcommand: SessionsListCommand.self)
}

/// Lists the saved sessions — filterable by group, kind, name and tag.
/// Reads `SessionStore` only: no secret, no keychain, no connection. Every
/// command outside this group opens a connection and therefore resolves a
/// secret; this one exists precisely so a user (or a script) can see what is
/// stored WITHOUT doing either.
struct SessionsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List the saved sessions.",
        discussion: """
            The default when no verb is given, so macscp-cli sessions --json \
            still lists. Filters combine; --name matches a case-insensitive \
            substring, not a pattern.
            """)

    @OptionGroup var options: JSONOptions

    @Option(
        name: .long, help: "Only sessions in this group or one of its subgroups.",
        completion: GroupTagCompletion.group)
    var group: String?

    @Option(name: .long, help: "Only this backend.")
    var kind: ConnectionKind?

    @Option(name: .long, help: "Only names containing this text (case-insensitive substring).")
    var name: String?

    @Option(
        name: .long, help: "Only sessions carrying this tag.",
        completion: GroupTagCompletion.tag)
    var tag: String?

    func run() async throws {
        let store = SessionStore(directory: SessionStore.defaultDirectory)
        let catalog = SessionCatalog(sessions: try store.all(), groups: try store.allGroups())
        let rows = catalog.rows(matching: .init(group: group, kind: kind, name: name, tag: tag))
        OutputFormatter.print(rows: rows, asJSON: options.json)
    }
}

/// Creates one session.
///
/// Every check lives in `validate()`, and that is a decision about EXIT
/// CODES rather than about tidiness: a `ValidationError` thrown there is
/// ArgumentParser's own, and leaves with 64. The same error thrown from
/// `run()` would reach `MacSCPCLI.main()`'s error path instead, where
/// `CLIErrorMapping` has no case for it and classifies it as a connection
/// failure (13) — telling a script the store was unreachable when in fact
/// its arguments were wrong.
///
/// So 0 and 64 are the only codes an ARGUMENT can produce here. A store that
/// cannot be read or written is not an argument and is not in that set: the
/// read inside `validate()` leaves through ArgumentParser as 1, and a write
/// failure inside `run()` reaches `CLIErrorMapping`, which has no case for a
/// `CocoaError` and answers 13. Both are honest — neither is a usage error —
/// and the same is true of `edit` and `rm`.
struct SessionsAddCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Save a new session.",
        discussion: """
            No secret is taken here: no password, no key passphrase, no S3 \
            secret key, and nothing is read from standard input. A \
            key-authenticated (--key) or agent-authenticated (--agent) \
            session works at once; a password session is asked for its \
            password by the app the first time it connects.
            """)

    @Argument(help: "The name to save it under. Must not be taken, ignoring case.")
    var name: String

    @Option(name: .long, help: "Which backend this session speaks.")
    var kind: ConnectionKind

    @OptionGroup var fields: SessionFieldOptions

    func validate() throws {
        _ = try planned()
    }

    func run() throws {
        // Re-planned rather than carried over from `validate()`: a
        // `ParsableCommand` is handed to `validate()` as a copy and has
        // nowhere to put a result. Nothing here can throw that `validate()`
        // did not already throw — same inputs, same pure function — and the
        // store write below is what `validate()` deliberately does not do.
        var session = try planned()
        let store = StoreEditing.sessionStore()
        if let path = fields.group {
            session.groupID = try StoreEditing.ensureGroup(atPath: path, in: store)
        }
        session.position = try StoreEditing.nextPosition(under: session.groupID, store: store)
        try StoreEditing.save(session)
    }

    /// Everything that can be decided without WRITING anything: the flags
    /// belong to this kind, their values are usable, the required ones are
    /// there, and the name is free and not empty.
    ///
    /// It reads the store — the name check has to — so it is not pure; what
    /// it is is repeatable and free of side effects, which is what lets
    /// `validate()` run it for the refusal and `run()` run it again for the
    /// value.
    private func planned() throws -> StoredSession {
        let session = try fields.newSession(named: name, kind: kind)
        if let path = fields.group { _ = try StoreEditing.groupPathSegments(path) }
        try StoreEditing.requireNameIsFree(session.name, in: try StoreEditing.sessionStore().all())
        return session
    }
}

/// Changes the fields named, and nothing else.
struct SessionsEditCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "edit",
        abstract: "Change a saved session.",
        discussion: """
            Only the fields you name change. The session keeps its identity, \
            so a password already saved for it stays reachable — editing the \
            host or the user name does not orphan it. Takes no secret, the \
            same way add does.
            """)

    @Argument(help: "The session to change, matched without case.")
    var name: String

    @Option(name: .long, help: "Rename it. The new name must not be taken, ignoring case.")
    var rename: String?

    @Option(name: .long, help: "Drop this tag. Repeat for several.")
    var noTag: [String] = []

    /// Declared so it can be REFUSED with a sentence, rather than reported
    /// as an unknown option. A stored session's backend is what its whole
    /// field bag means; changing it in place would leave an S3 block on an
    /// SSH session or the other way round.
    @Option(name: .long, help: "Refused: a session's backend cannot change.")
    var kind: ConnectionKind?

    @OptionGroup var fields: SessionFieldOptions

    func validate() throws {
        _ = try planned()
    }

    func run() throws {
        var session = try planned()
        let store = StoreEditing.sessionStore()
        if let path = fields.group {
            let groupID = try StoreEditing.ensureGroup(atPath: path, in: store)
            // Only when the session actually MOVES. A `position` carried into
            // another group is a number about a different list — it lands the
            // moved session above siblings that were there first, or below
            // ones that were not — so a move ends where an add would:
            // last among its new siblings. Re-filing into the group it is
            // already in is not a move, and renumbering it there would
            // shuffle a list nobody asked to reorder.
            if groupID != session.groupID {
                session.groupID = groupID
                session.position = try StoreEditing.nextPosition(under: groupID, store: store)
            }
        }
        try StoreEditing.save(session)
    }

    private func planned() throws -> StoredSession {
        if kind != nil {
            throw ValidationError("--kind cannot change; remove the session and add it again")
        }
        let stored = try StoreEditing.requireSession(named: name)
        // The stored kind decides which flags apply — `edit` has no --kind
        // of its own to read them against.
        try fields.validateKindOwnership(stored.kind)
        try fields.validateAuthChoice()
        // The same value checks `add` runs — see `validateGivenValues`' doc
        // comment for what happened when only one verb had them.
        try fields.validateGivenValues()
        if let path = fields.group { _ = try StoreEditing.groupPathSegments(path) }

        var session = fields.edited(stored, removingTags: noTag)
        if let rename {
            let sessions = try StoreEditing.sessionStore().all()
            try StoreEditing.requireNameIsFree(rename, excluding: stored.id, in: sessions)
            session.name = SessionNameRule.asSaved(rename)
        }
        return session
    }
}

/// Deletes a session and the port forwardings that belong to it.
struct SessionsRemoveCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rm",
        abstract: "Delete a saved session and its forwardings.",
        discussion: """
            Asks first on a terminal; pass --yes to skip the question, which \
            is required when there is no terminal to ask on. The stored \
            password is left in the keychain — this tool never opens it — so \
            a session recreated under the same name does NOT find it again \
            (the entry is keyed by the session's identity, not its name).
            """)

    @Argument(help: "The session to delete, matched without case.")
    var name: String

    @Flag(name: .long, help: "Delete without asking.")
    var yes = false

    @Flag(name: .long, help: "Never prompt; fail instead.")
    var nonInteractive = false

    @Flag(name: .long, help: "Report what was and was not touched.")
    var verbose = false

    func validate() throws {
        _ = try StoreEditing.requireSession(named: name)
        // Both halves, and the TTY one is not redundant: a script that
        // redirects stdin without passing --non-interactive would otherwise
        // reach a question nobody can answer, and `CLIEnvironment.confirm`
        // reads EOF as "no" — a delete that silently does nothing is a worse
        // answer than a usage error.
        guard !yes, nonInteractive || !CLIEnvironment.hasTTY else { return }
        throw ValidationError(
            "there is no terminal to ask on; pass --yes to delete \(name)")
    }

    func run() throws {
        let session = try StoreEditing.requireSession(named: name)
        let forwardings = StoreEditing.forwardingCount(for: session)
        if !yes {
            let question =
                "Delete session \(session.name) and \(forwardings) forwardings? [y/N] "
            guard CLIEnvironment.confirm(question) else {
                OutputFormatter.note("Left \(session.name) in place.")
                return
            }
        }
        try StoreEditing.deleteSession(session)
        if verbose {
            OutputFormatter.note(
                "Deleted \(session.name) and \(forwardings) forwardings; "
                    + "keychain entry left in place.")
        }
    }
}

/// `sessions list` reads no secret, resolves no login set and opens no
/// connection — so `GlobalOptions`' other flags (`--verbose`,
/// `--non-interactive`, `--accept-new`, `--password-command`) describe
/// choices it never makes. Handing it the whole of `GlobalOptions` anyway
/// advertised all four on the one command whose entire point is that none of
/// them apply (final-branch-review finding, 2026-09-02). The same reasoning
/// keeps `GlobalOptions` out of every verb in this group: `rm` declares its
/// own `--non-interactive` and `--verbose` because it really makes those two
/// choices, and declares nothing about host keys or secrets because it makes
/// no choice about either.
///
/// `--json`'s help text is copied verbatim from `GlobalOptions.json` rather
/// than shared, the same way `ConflictAction`'s and `ConnectionKind`'s
/// `ExpressibleByArgument` conformances live as siblings rather than a
/// shared base — the two options happen to agree today, not because one is
/// defined in terms of the other.
struct JSONOptions: ParsableArguments {
    @Flag(name: .long, help: "Emit one JSON object per line instead of columns.")
    var json = false

    init() {}
}
