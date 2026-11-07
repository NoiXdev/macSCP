import Foundation
import Testing

@testable import macSCPCore

/// FTP as a login the user manages: entered in the form, stored, described in
/// the overview, and kept clear of the one thing none of those may hold.
///
/// Most of the machinery these cases read was built under the connection-kind
/// task (`StoredFTPConfig`, `StoredSession.ftp`, the catalog target, the
/// overview facts) and is pinned beside it in `FTPFieldSchemaTests`. What this
/// file adds is the same properties asked THROUGH the surfaces a user reaches
/// them by: the store and the catalog, the form, the save path with a real
/// password on it, and the overview built from what the store handed back.
///
/// A value these cases must not leak lives in a named constant, and every
/// comparison about it is computed into a `Bool` before the expectation:
/// `#expect` prints the source text of its expression AND what its
/// subexpressions evaluated to, so a secret written into an expectation, or a
/// carrier that holds one, would print it in the very failure that says it
/// leaked.
@Suite("FTP stored sessions")
@MainActor
struct FTPStoredSessionTests {
    private static let secret = "ftp-secret-\(UUID().uuidString)"

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ftp-stored-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Answers the overview's presence question from an in-memory secret
    /// store, the way the keychain-backed one answers it from the keychain:
    /// a `Bool`, and nothing that could carry the value.
    private struct PresenceOf: SecretPresence {
        let store: InMemorySecretStore
        func hasSecret(for slot: UUID) -> Bool {
            ((try? store.password(for: slot)) ?? nil) != nil
        }
    }

    // MARK: - The store and the catalog

    /// A session of each security mode goes into the store file and comes back
    /// equal, and the catalog built from what came back describes it: its
    /// kind, its folder, its tags and the `user@host:port` target. The
    /// catalog is read through the kind filter too, because that is how the
    /// command line finds an FTP login.
    @Test func aStoredFTPSessionRoundTripsThroughTheCatalog() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)

        let group = StoredGroup(name: "Mirrors")
        try store.upsertGroup(group)
        var expectedTargets: [String: String] = [:]
        for mode in FTPSecurityMode.allCases {
            let port = mode == .implicitTLS ? 2990 : 2121
            var session = ftpSession(
                name: "files-\(mode.rawValue)", groupID: group.id,
                config: StoredFTPConfig(
                    host: "files.example.com", port: port, username: "tim",
                    security: mode, initialPath: "/pub"))
            session.tags = ["mirror"]
            try store.upsert(session)
            expectedTargets[session.name] = "tim@files.example.com:\(port)"
        }
        try store.upsert(sshSession(name: "not-ftp"))

        let loaded = try store.all()
        for mode in FTPSecurityMode.allCases {
            let session = try #require(loaded.first { $0.name == "files-\(mode.rawValue)" })
            #expect(session.kind == .ftp)
            #expect(session.ftp?.security == mode)
            #expect(session.ftp?.initialPath == "/pub")
            #expect(session.ssh == nil && session.s3 == nil && session.webdav == nil)
        }

        let catalog = SessionCatalog(sessions: loaded, groups: try store.allGroups())
        let rows = catalog.rows(matching: .init(kind: .ftp))
        #expect(rows.count == FTPSecurityMode.allCases.count)
        for row in rows {
            #expect(row.kind == .ftp)
            #expect(row.groupPath == "Mirrors")
            #expect(row.tags == ["mirror"])
            #expect(row.target == expectedTargets[row.name])
        }
        // The positive beside the per-row loop: a catalog that returned
        // nothing would satisfy every check inside it.
        #expect(Set(rows.map(\.name)) == Set(expectedTargets.keys))
    }

    // MARK: - The form

    /// The security picker offers the three modes, in the order the type
    /// declares them, and the port follows the mode's default until the user
    /// types one of their own.
    ///
    /// Three things, each of which a form could get wrong on its own: the
    /// picker's options (what can be chosen), the port a choice lands on
    /// (21, 21 and 990), and the port a choice must LEAVE ALONE (one the user
    /// typed). A fresh form starts on explicit FTPS with its port written out.
    @Test func theFormOffersThreeSecurityModesAndDefaultsThePortToEach() throws {
        let field = try #require(
            FTPFieldSchema.connection.fields.first { $0.id == FTPField.security.rawValue })
        guard case .picker(.fixed(let options)) = field.kind else {
            Issue.record("expected a fixed picker")
            return
        }
        #expect(options.map(\.id) == FTPSecurityMode.allCases.map(\.rawValue))
        #expect(options.count == 3)

        let model = ConnectionViewModel(connector: { _, _ in
            MockRemoteFileSystem(tree: ["/": []])
        })
        model.kind = .ftp
        #expect(model.values[FTPField.security] == FTPSecurityMode.explicitTLS.rawValue)
        #expect(model.values[FTPField.port] == "21")

        // Every mode, from every other mode: the port lands on the new
        // mode's default whichever way round the user travels.
        for from in FTPSecurityMode.allCases {
            for to in FTPSecurityMode.allCases {
                model.selectFTPSecurity(from)
                #expect(model.values[FTPField.port] == String(from.defaultPort))
                model.selectFTPSecurity(to)
                #expect(model.values[FTPField.security] == to.rawValue)
                #expect(
                    model.values[FTPField.port] == String(to.defaultPort),
                    "\(from.rawValue) -> \(to.rawValue) left the port on the old default")
                #expect(FTPFieldSchema.stored(from: model.values).port == to.defaultPort)
            }
        }

        // A port the user typed is theirs, in every direction.
        for to in FTPSecurityMode.allCases {
            model.selectFTPSecurity(.plain)
            model.values[FTPField.port] = "2121"
            model.selectFTPSecurity(to)
            #expect(model.values[FTPField.port] == "2121", "\(to.rawValue) overwrote a typed port")
        }
        // A stored session carries its port with its mode: implicit FTPS on
        // 21 keeps 21 when the edit form opens it, because loading assigns
        // both at once and does not travel through the picker's command.
        let editing = ConnectionViewModel(connector: { _, _ in
            MockRemoteFileSystem(tree: ["/": []])
        })
        editing.beginEditing(ftpSession(
            name: "odd",
            config: StoredFTPConfig(
                host: "files.example.com", port: 21, username: "tim", security: .implicitTLS)))
        #expect(editing.values[FTPField.security] == FTPSecurityMode.implicitTLS.rawValue)
        #expect(editing.values[FTPField.port] == "21")

        // And a blank one stays blank: blank already means "the mode's own".
        model.values[FTPField.port] = ""
        model.selectFTPSecurity(.implicitTLS)
        #expect(model.values[FTPField.port] == "")
        #expect(FTPFieldSchema.stored(from: model.values).port == 990)
    }

    // MARK: - No password at rest

    /// The password goes to the secret store and nowhere else: driven through
    /// the save path with a real password on it, then read back from the
    /// store FILE (the bytes on disk, not the in-memory session).
    ///
    /// The positive half is what makes the negative one mean something: the
    /// secret DID reach the secret store under the session's slot, so a save
    /// that dropped it on the floor, or never carried it, cannot pass.
    @Test func theStoredSessionCarriesNoPassword() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let secrets = InMemorySecretStore()
        let sessions = SessionListViewModel(
            store: SessionStore(directory: directory), secrets: secrets,
            auditStore: AuditLogStore(directory: directory),
            loginSetStore: LoginSetStore(directory: directory),
            keys: ManagedKeyStore(directory: directory))

        var values = FieldValues()
        values[FTPField.host] = "files.example.com"
        values[FTPField.port] = "2121"
        values[FTPField.security] = FTPSecurityMode.explicitTLS.rawValue
        values[FTPField.username] = "tim"
        values[FTPField.initialPath] = "/pub"
        // The form's password field is part of `values` when the app saves,
        // beside the separate argument: both are on the path, so a block
        // built from a field it should not read can pick the secret up.
        values[FTPField.password] = Self.secret
        let saved = try #require(sessions.save(
            name: "files", values: values, password: Self.secret, kind: .ftp))

        let reachedTheSecretStore = ((try secrets.password(for: saved.secretSlot)) ?? "") == Self.secret
        #expect(reachedTheSecretStore)

        let file = directory.appendingPathComponent("sessions-v2.json")
        let onDisk = try String(contentsOf: file, encoding: .utf8)
        let leakedToDisk = onDisk.contains(Self.secret)
        #expect(leakedToDisk == false)
        let wroteTheBlock = onDisk.contains("files.example.com")
        #expect(wroteTheBlock)

        let encoded = String(decoding: try JSONEncoder().encode(saved), as: UTF8.self)
        let leakedFromTheValue = encoded.contains(Self.secret)
        #expect(leakedFromTheValue == false)
        #expect(saved.ftp?.username == "tim")
    }

    // MARK: - The overview

    /// The overview of a saved FTP login says where it goes, how it is
    /// protected and who logs in, and says WHETHER a password is saved, never
    /// what it is.
    ///
    /// Built from what the store handed back after a save with a real
    /// password, and checked across the whole value: `String(describing:)`
    /// reaches every stored property the model holds, so a field added later
    /// that started carrying the secret is inside the check without anyone
    /// adding a line to it. The user name is a fact on purpose (it identifies
    /// the login, as on SSH); the password is the credential.
    @Test func theOverviewDescribesAnFTPSessionWithoutNamingItsCredentials() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let secrets = InMemorySecretStore()
        let sessions = SessionListViewModel(
            store: SessionStore(directory: directory), secrets: secrets,
            auditStore: AuditLogStore(directory: directory),
            loginSetStore: LoginSetStore(directory: directory),
            keys: ManagedKeyStore(directory: directory))
        var values = FieldValues()
        values[FTPField.host] = "files.example.com"
        values[FTPField.port] = "990"
        values[FTPField.security] = FTPSecurityMode.implicitTLS.rawValue
        values[FTPField.username] = "tim"
        values[FTPField.initialPath] = "/pub"
        values[FTPField.password] = Self.secret
        let saved = try #require(sessions.save(
            name: "files", values: values, password: Self.secret, kind: .ftp))
        let stored = try #require(try SessionStore(directory: directory).all().first { $0.id == saved.id })

        let overview = SessionOverviewModel(
            session: stored, descriptor: BackendDescriptor.descriptor(for: .ftp), knownKey: nil,
            secrets: PresenceOf(store: secrets), events: [], snippets: [])

        // What it says.
        let texts = Dictionary(uniqueKeysWithValues: overview.facts.map { ($0.id, $0.text) })
        #expect(texts["host"] == "files.example.com")
        #expect(texts["port"] == "990")
        #expect(texts["username"] == "tim")
        #expect(texts["initialPath"] == "/pub")
        #expect(texts["security"] == CoreL10n.string("core.overview.ftp.security.implicitTLS"))
        #expect(overview.endpointText == "files.example.com:990")
        #expect(overview.hasStoredSecret == true)
        #expect(overview.hostKey == .notApplicable)

        // What it never says.
        let everything = String(describing: overview)
        let leaked = everything.contains(Self.secret)
        #expect(leaked == false)
        let factsNameAPassword = overview.facts.contains {
            $0.id.lowercased().contains("password") || $0.labelKey.lowercased().contains("password")
        }
        #expect(factsNameAPassword == false)
        // The positive beside both: the rendering is not empty, so the
        // negative checks are about something.
        #expect(overview.facts.count >= 5)
    }
}
