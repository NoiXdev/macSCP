import Foundation
import Testing
@testable import macSCPCore

/// The one M22 test that cannot be replaced by reasoning.
///
/// Everything else the milestone did is provable by argument: the schemas are
/// data, the factories switch over their own enums, the renderer walks a list.
/// Whether a `sessions.json` and a `logins.json` written BEFORE the milestone
/// still load afterwards is not — that is a fact about two files on disk, and
/// only a frozen copy of them can state it.
///
/// The fixtures were produced by `SessionStore.persist`/`LoginSetStore.persist`
/// themselves, so they are the format the app writes today, byte for byte. That
/// is the same as the pre-M22 format because M22 changed no persistence shape
/// at all — `git diff <pre-M22>..HEAD` over `StoredSession`, `StoredS3Config`,
/// `StoredWebDAVConfig`, `LoginSetStore` and the two export codecs is empty.
/// If a shape ever does change, this suite is where the break surfaces.
///
/// Loaded through the real stores rather than a bare `JSONDecoder`, because the
/// store is what a user's installation actually runs: it is where the container
/// shape, the legacy bare-array fallback and the dangling-group sweep live.
@Suite("Legacy store compatibility")
struct LegacyStoreCompatibilityTests {
    /// Copies both fixtures into a fresh temporary directory under the names
    /// the stores look for, and returns it.
    private func seededStoreDirectory() throws -> URL {
        let fixtures = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-legacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: fixtures.appendingPathComponent("legacy-session-pre-m22.json"),
            to: directory.appendingPathComponent("sessions.json"))
        try FileManager.default.copyItem(
            at: fixtures.appendingPathComponent("legacy-loginset-pre-m22.json"),
            to: directory.appendingPathComponent("logins.json"))
        return directory
    }

    private func fixtureText(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name)")
        return try #require(String(data: try Data(contentsOf: url), encoding: .utf8))
    }

    /// A session written before M22 must still load — and still describe the
    /// same connection, read through the descriptor's own adapter.
    @Test func aPreM22SessionStillLoads() throws {
        let directory = try seededStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessions = try SessionStore(directory: directory).all()
        #expect(sessions.count == 3)

        let ssh = try #require(sessions.first { $0.kind == .ssh })
        let sshValues = BackendDescriptor.descriptor(for: .ssh).sessionValues(ssh)
        #expect(sshValues[SSHField.host] == "server.example.com")
        #expect(sshValues[SSHField.port] == "2222")
        #expect(sshValues[SSHField.username] == "tim")
        #expect(sshValues[SSHField.authKind] == StoredSession.AuthKind.privateKey.rawValue)
        #expect(sshValues[SSHField.keyPath] == "~/.ssh/id_ed25519")
        // The group binding survives the store's dangling-group sweep, and the
        // jump host keeps its own agent login.
        #expect(ssh.groupID != nil)
        #expect(ssh.jump?.host == "bastion.example.com")
        #expect(ssh.jump?.authKind == .agent)

        let s3 = try #require(sessions.first { $0.kind == .s3 })
        let s3Stored = try #require(s3.s3)
        #expect(S3FieldSchema.values(from: s3Stored)[S3Field.bucket] == "backups")
        let s3Values = BackendDescriptor.descriptor(for: .s3).sessionValues(s3)
        #expect(s3Values[S3Field.endpoint] == "https://s3.example.com")
        #expect(s3Values[S3Field.region] == "eu-central-1")
        #expect(s3Values[S3Field.accessKeyID] == "AKIA")
        #expect(s3Values[bool: S3Field.usePathStyle])
        // A set-bound session keeps pointing at the set the login fixture holds.
        #expect(s3.loginSetID?.uuidString.lowercased() == "66666666-6666-4666-8666-666666666666")

        let dav = try #require(sessions.first { $0.kind == .webdav })
        let davStored = try #require(dav.webdav)
        #expect(WebDAVFieldSchema.values(from: davStored)[WebDAVField.username] == "tim")
        let davValues = BackendDescriptor.descriptor(for: .webdav).sessionValues(dav)
        #expect(davValues[WebDAVField.baseURL] == "https://dav.example.com")
        #expect(davValues[bool: WebDAVField.useNextcloudPath])
    }

    /// Loading is not enough: the values a loaded session yields must still
    /// build the same runtime config the user connected with before M22. The
    /// WebDAV session is the one carrying neither a jump nor a login-set
    /// binding, so it is the one `StoredSessionConnectionConfig.build` — the
    /// CLI's path — can answer for end to end.
    @Test func aPreM22SessionStillBuildsItsConfig() throws {
        let directory = try seededStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessions = try SessionStore(directory: directory).all()
        let dav = try #require(sessions.first { $0.kind == .webdav })

        guard case .webdav(let viaStore) = try StoredSessionConnectionConfig.build(
            for: dav, secret: "s") else {
            Issue.record("expected a WebDAV config")
            return
        }
        #expect(viaStore.baseURL == "https://dav.example.com")
        #expect(viaStore.username == "tim")
        #expect(viaStore.useNextcloudPath)

        // The schema route must agree with the persistence route: same stored
        // session, same config, whether it travels through the descriptor's
        // field values or through the typed builder.
        let descriptor = BackendDescriptor.descriptor(for: .webdav)
        guard case .webdav(let viaSchema) = try descriptor.makeConfig(
            descriptor.sessionValues(dav), "s") else {
            Issue.record("expected a WebDAV config")
            return
        }
        #expect(viaSchema == viaStore)
    }

    /// A login set written before M22 must still load, in every kind the store
    /// could hold at the time, and still translate into its backend's fields.
    @Test func aPreM22LoginSetStillLoads() throws {
        let directory = try seededStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sets = try LoginSetStore(directory: directory).all()
        #expect(sets.count == 2)

        let ssh = try #require(sets.first { $0.kind == .ssh })
        #expect(ssh.username == "tim")
        #expect(ssh.authKind == .privateKey)
        let sshValues = BackendDescriptor.descriptor(for: .ssh).loginSetValues(ssh)
        #expect(sshValues[SSHField.username] == "tim")
        #expect(sshValues[SSHField.keyPath] == "~/.ssh/id_ed25519")

        let s3 = try #require(sets.first { $0.kind == .s3 })
        #expect(s3.accessKeyID == "AKIA")
        let s3Values = BackendDescriptor.descriptor(for: .s3).loginSetValues(s3)
        #expect(s3Values[S3Field.accessKeyID] == "AKIA")
    }

    /// Every object KEY in a fixture, at any depth.
    private func keys(in json: Any) -> Set<String> {
        if let object = json as? [String: Any] {
            return object.reduce(into: Set(object.keys)) { $0.formUnion(keys(in: $1.value)) }
        }
        if let array = json as? [Any] {
            return array.reduce(into: Set<String>()) { $0.formUnion(keys(in: $1)) }
        }
        return []
    }

    /// The fixtures are checked into git, so they must carry no secret
    /// material.
    ///
    /// Deliberately checks KEYS parsed out of the JSON rather than grepping the
    /// text, because a textual scan for "password" cannot work here:
    /// `StoredSession.AuthKind`'s raw value IS `"password"`, so a completely
    /// legitimate `"authKind" : "password"` trips it — and the next person
    /// "fixes" that by weakening the check. A secret can only ever appear as a
    /// named field, so the key set is both the exact question and one no
    /// quoting or whitespace convention can confuse.
    @Test func fixturesCarryNoSecrets() throws {
        let secretFieldNames: Set<String> = [
            "secretAccessKey", "secret", "password", "passphrase",
            "embeddedKey", "privateKey", "jumpPassword", "fileContents",
        ]
        for name in ["legacy-session-pre-m22.json", "legacy-loginset-pre-m22.json"] {
            let data = try Data(contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)"))
            let found = keys(in: try JSONSerialization.jsonObject(with: data))
                .intersection(secretFieldNames)
            #expect(found.isEmpty, "fixture \(name) carries \(found.sorted())")
        }
    }

    /// The trap the check above sidesteps, pinned so nobody "simplifies" it
    /// back into a textual scan: the fixture really does contain the word
    /// `password`, as a legitimate auth-kind VALUE.
    @Test func theAuthKindRawValueLooksLikeASecretButIsNot() throws {
        #expect(StoredSession.AuthKind.password.rawValue == "password")
        #expect(try fixtureText("legacy-session-pre-m22.json").contains("\"password\""))
    }
}
