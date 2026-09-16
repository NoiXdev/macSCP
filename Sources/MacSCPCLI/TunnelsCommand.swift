import ArgumentParser
import Foundation
import macSCPCore

/// The saved port forwardings: listing them, creating, changing and
/// deleting one — and running one. The four STORE verbs in this file read
/// `SessionStore` (to resolve `--session`) and read and write `TunnelStore`:
/// no secret, no keychain, no connection, in any verb below.
///
/// The fifth, `start`, is the exception and lives in its own file
/// (`TunnelStartCommand.swift`): it dials, so it declares `GlobalOptions`
/// where the four below declare none, and it resolves the session's secret
/// the way every dialling command in this tool does — `--password-command`,
/// then the environment variable, then the keychain entry the app stored,
/// then, for a private-key session, the passphrase the app stored for a key
/// it manages (`secretSources(for:passwordCommand:)`, whose order is Core's).
/// Both keychain sources are READ and never written: no verb of this tool
/// puts a secret in the keychain.
///
/// `list` is the DEFAULT subcommand, the same choice `SessionsCommand` made
/// and for a weaker reason: no script can have been written against
/// `macscp-cli tunnels` yet. It is symmetry rather than compatibility — the
/// two groups in this tool answer a bare group name the same way.
///
/// A forwarding is addressed by NAME plus `--session`, because that pair is
/// what makes a handle: the app allows one session two forwardings with the
/// same name, and two sessions each having a `db` forward is the ordinary
/// case. `--session` therefore takes no completion of its own — the existing
/// completer appends a trailing `:` because it completes `name:/path`
/// targets, and a bare-name completer is its own change (the design's "Not
/// in this plan").
struct TunnelsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tunnels",
        abstract: "List, add, edit, remove and run port forwardings.",
        discussion: """
            A forwarding belongs to a saved session and is named within it, \
            so every verb but the listing takes --session as well as the \
            name. Specs are written the way ssh(1) writes them: \
            [bind:]port:host:hostport for --local and --remote, [bind:]port \
            for --dynamic, with the bind address defaulting to 127.0.0.1. \
            Only start opens a connection, and it does so in this process, \
            for as long as it runs: it dials with the session's own login, \
            resolving its secret from --password-command, then the \
            environment, then the keychain entry the app saved, then the \
            passphrase the app saved for a key it manages. The other \
            verbs read and write nothing but the two stores.
            """,
        subcommands: [
            TunnelsListCommand.self, TunnelsAddCommand.self,
            TunnelsEditCommand.self, TunnelsRemoveCommand.self,
            TunnelStartCommand.self,
        ],
        defaultSubcommand: TunnelsListCommand.self)
}

/// Lists the saved forwardings, optionally narrowed to one session.
struct TunnelsListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List the saved forwardings.",
        discussion: """
            The default when no verb is given, so macscp-cli tunnels --json \
            still lists. Columns: name, session, kind, spec, autostart, \
            reconnect. There is no state column — a running forwarding \
            belongs to the process that started it, and this one cannot see \
            the app's.
            """)

    @OptionGroup var options: JSONOptions

    @Option(name: .long, help: "Only the forwardings on this session.")
    var session: String?

    func validate() throws {
        if let session { _ = try StoreEditing.requireSession(named: session) }
    }

    func run() throws {
        // One read of the session store per run: the rows below name every
        // profile's session, so the whole listing is needed either way and
        // `--session` is resolved against it rather than through a second
        // read of the same file.
        let sessions = try StoreEditing.sessionStore().all()
        let named = try session.map { try StoreEditing.requireSession(named: $0, in: sessions) }
        let profiles = named.map(StoreEditing.profiles(on:))
            ?? StoreEditing.tunnelStore().allProfiles()
        OutputFormatter.print(
            tunnels: profiles.map { profile in
                // A profile whose session is gone is named by its session
                // id, which is all that is known about it. `sessions rm`
                // deletes a session's profiles with it, so this is the app's
                // possible leftover rather than a state this tool produces —
                // and dropping such a row silently would hide it.
                let name = sessions.first { $0.id == profile.sessionID }?.name
                return TunnelRow(
                    profile: profile, sessionName: name ?? profile.sessionID.uuidString)
            },
            asJSON: options.json)
    }
}

/// Creates one forwarding on one session.
///
/// Every check lives in `validate()`, for the reason `SessionsAddCommand`'s
/// doc comment spells out: a `ValidationError` thrown there is
/// ArgumentParser's own and leaves with 64, while the same error thrown from
/// `run()` would reach `CLIErrorMapping` and be reported as a connection
/// failure (13) — telling a script the store was unreachable when its
/// arguments were wrong.
struct TunnelsAddCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Save a new forwarding on a session.",
        discussion: """
            The session must be one a forwarding can dial over: SSH, with \
            neither a login set nor a jump host. That is checked here, so \
            the refusal names the reason rather than waiting for a dial that \
            cannot work.
            """)

    @Argument(help: "The name to save it under. Must be free on that session.")
    var name: String

    @OptionGroup var target: TunnelTargetOptions
    @OptionGroup var spec: TunnelSpecOptions

    @Option(name: .long, help: "When to start it without being asked. Default off.")
    var autostart = AutoStartOption(.off)

    @Flag(name: .long, help: "Reconnect with backoff when the connection is lost.")
    var reconnect = false

    func validate() throws {
        _ = try planned()
    }

    func run() throws {
        // Re-planned rather than carried over from `validate()`, for the
        // reason `SessionsAddCommand.run()` states: a `ParsableCommand` is
        // handed to `validate()` as a copy and has nowhere to put a result.
        try StoreEditing.save(try planned())
    }

    /// Everything that can be decided without WRITING anything: exactly one
    /// spec flag, a spec that parses, a session that exists and can carry a
    /// forwarding at all, and a name that is free on it.
    private func planned() throws -> TunnelProfile {
        let kind = try spec.requireExactlyOne()
        let session = try target.requireSession()
        try target.requireItCanCarryAForwarding(session)
        try StoreEditing.requireForwardingNameIsFree(name, on: session)
        return TunnelProfile(
            sessionID: session.id, name: SessionNameRule.asSaved(name), kind: kind,
            autoStart: autostart.stored, reconnects: reconnect)
    }
}

/// Changes the fields named, and nothing else.
struct TunnelsEditCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "edit",
        abstract: "Change a saved forwarding.",
        discussion: """
            Only the fields you name change, and the kind is one of them: a \
            profile is one mapping, and replacing that mapping is what \
            editing it means. The forwarding keeps its identity, so the app \
            restarts a running forwarding only when you stop and start it.
            """)

    @Argument(help: "The forwarding to change, matched without case.")
    var name: String

    @OptionGroup var target: TunnelTargetOptions
    @OptionGroup var spec: TunnelSpecOptions

    @Option(name: .long, help: "Rename it. The new name must be free on that session.")
    var rename: String?

    @Option(name: .long, help: "When to start it without being asked.")
    var autostart: AutoStartOption?

    @Flag(
        inversion: .prefixedNo,
        exclusivity: .exclusive,
        help: "Reconnect with backoff when the connection is lost.")
    var reconnect: Bool?

    func validate() throws {
        _ = try planned()
    }

    func run() throws {
        try StoreEditing.save(try planned())
    }

    private func planned() throws -> TunnelProfile {
        let kind = try spec.requireAtMostOne()
        let session = try target.requireSession()
        var profile = try StoreEditing.requireProfile(named: name, on: session)
        if let kind { profile.kind = kind }
        if let autostart { profile.autoStart = autostart.stored }
        if let reconnect { profile.reconnects = reconnect }
        if let rename {
            try StoreEditing.requireForwardingNameIsFree(
                rename, on: session, excluding: profile.id)
            profile.name = SessionNameRule.asSaved(rename)
        }
        return profile
    }
}

/// Deletes one forwarding.
struct TunnelsRemoveCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rm",
        abstract: "Delete a saved forwarding.",
        discussion: """
            Asks nothing, unlike sessions rm: a forwarding carries no secret \
            and is one line to recreate. A forwarding the app is running \
            keeps running until the app is told to stop it.
            """)

    @Argument(help: "The forwarding to delete, matched without case.")
    var name: String

    @OptionGroup var target: TunnelTargetOptions

    func validate() throws {
        _ = try planned()
    }

    func run() throws {
        try StoreEditing.deleteProfile(try planned())
    }

    private func planned() throws -> TunnelProfile {
        try StoreEditing.requireProfile(named: name, on: try target.requireSession())
    }
}

/// The `--session` every verb but the listing requires, and the two
/// questions asked about it — declared once so all three verbs ask them in
/// the same words and the same order.
struct TunnelTargetOptions: ParsableArguments {
    @Option(name: .long, help: "The session this forwarding belongs to, matched without case.")
    var session: String

    init() {}

    func requireSession() throws -> StoredSession {
        try StoreEditing.requireSession(named: session)
    }

    /// The three rules `TunnelCarriers.refusal(for:)` words — a login set, a
    /// jump host, a backend with no `direct-tcpip` — asked here, before
    /// anything is written, so the refusal names the reason rather than
    /// arriving as a failed dial later.
    ///
    /// The SENTENCE comes from Core and is not worded again here: the same
    /// rule answers in the app's sidebar menu and inside
    /// `TunnelConnection.connect`, and a refusal worded differently in three
    /// places reads as three different rules.
    func requireItCanCarryAForwarding(_ session: StoredSession) throws {
        guard let refusal = TunnelCarriers.refusal(for: session) else { return }
        throw ValidationError(refusal)
    }
}

/// The three spec flags, and the rule that exactly one of them is a
/// forwarding.
///
/// One option group rather than three properties per verb, because `add` and
/// `edit` differ only in how many they accept: `add` needs one — a profile
/// with no mapping is not a profile — and `edit` accepts none, meaning
/// "leave the mapping alone".
struct TunnelSpecOptions: ParsableArguments {
    @Option(
        name: .long,
        help: "Local forward (ssh -L): [bind:]port:host:hostport.")
    var local: String?

    @Option(
        name: .long,
        help: "Remote forward (ssh -R): [bind:]port:host:hostport.")
    var remote: String?

    @Option(
        name: .long,
        help: "Dynamic SOCKS5 forward (ssh -D): [bind:]port.")
    var dynamic: String?

    init() {}

    /// The parsed kind, or a usage error naming all three flags.
    ///
    /// `TunnelSpec`'s own error is thrown as it is worded: it names the text
    /// it refused and what the shape should have been, and re-wording it
    /// here would put a second spelling of the grammar in front of the user.
    func requireExactlyOne() throws -> TunnelProfile.Kind {
        guard let kind = try parsed() else {
            throw ValidationError(Self.oneOfThree)
        }
        return kind
    }

    /// The parsed kind, or `nil` when no spec flag was given at all — what
    /// `edit` means by "leave the mapping alone". More than one is still a
    /// usage error: a profile is ONE mapping.
    func requireAtMostOne() throws -> TunnelProfile.Kind? {
        try parsed()
    }

    private static let oneOfThree =
        "name exactly one of --local, --remote or --dynamic"

    /// The flags that were given, by name. Counted before anything is
    /// parsed, so "two flags" is refused as two flags rather than as
    /// whichever of them happens to be malformed.
    private var givenFlags: [String] {
        var names: [String] = []
        if local != nil { names.append("--local") }
        if remote != nil { names.append("--remote") }
        if dynamic != nil { names.append("--dynamic") }
        return names
    }

    /// `nil` for no flag, a parsed kind for exactly one, and a usage error
    /// for two or three. The callers above differ only in what they make of
    /// `nil`.
    private func parsed() throws -> TunnelProfile.Kind? {
        guard givenFlags.count <= 1 else { throw ValidationError(Self.oneOfThree) }
        do {
            if let local { return try TunnelSpec.parse(local: local) }
            if let remote { return try TunnelSpec.parse(remote: remote) }
            if let dynamic { return try TunnelSpec.parse(dynamic: dynamic) }
            return nil
        } catch let error as TunnelSpecError {
            throw ValidationError(error.description)
        }
    }
}

/// `--autostart off|app-start|login`.
///
/// Every spelling comes from `TunnelProfile.AutoStart.rowName` — the same
/// one `tunnels list` prints, so a value read out of a listing can be handed
/// straight back to `--autostart`, and the choices the help screen offers
/// are `allCases`' rather than a list written here. It is NOT the stored raw
/// value, which spells the middle choice `appStart`; see `rowName`'s doc
/// comment for why the two differ.
///
/// A wrapper rather than a conformance on `TunnelProfile.AutoStart` itself,
/// for the reason `PaneOption` gives: the flag's vocabulary is the command
/// line's, and Core cannot import `ArgumentParser` anyway.
struct AutoStartOption: ExpressibleByArgument {
    let stored: TunnelProfile.AutoStart

    init(_ stored: TunnelProfile.AutoStart) {
        self.stored = stored
    }

    init?(argument: String) {
        guard let stored = TunnelProfile.AutoStart(rowName: argument) else { return nil }
        self.stored = stored
    }

    static var allValueStrings: [String] {
        TunnelProfile.AutoStart.allCases.map(\.rowName)
    }

    var defaultValueDescription: String { stored.rowName }
}
