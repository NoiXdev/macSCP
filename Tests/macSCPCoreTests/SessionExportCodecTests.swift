import Foundation
import Testing
@testable import macSCPCore

@Suite("SessionExportCodec")
struct SessionExportCodecTests {
    private func samplePayload(includesSecrets: Bool = false) -> SessionExportPayload {
        let groupID = UUID()
        return SessionExportPayload(
            includesSecrets: includesSecrets,
            groups: [ExportedGroup(id: groupID, name: "Prod")],
            sessions: [ExportedSession(
                id: UUID(), name: "wärter-01 🚀", kind: .ssh,
                fields: sshExportFields(
                    host: "Web-01.example.COM", port: 2222, username: "deploy",
                    authKind: .privateKey, keyPath: "/Users/x/.ssh/id_ed25519"),
                groupID: groupID,
                password: includesSecrets ? "geh€im🔑" : nil)])
    }

    @Test func clearRoundtripPreservesPayload() throws {
        let payload = samplePayload()
        let data = try SessionExportCodec.encode(payload, password: nil)
        #expect(try SessionExportCodec.probe(data) == false)
        #expect(try SessionExportCodec.decode(data, password: nil) == payload)
    }

    @Test func encryptedRoundtripPreservesPayloadIncludingSecrets() throws {
        let payload = samplePayload(includesSecrets: true)
        let data = try SessionExportCodec.encode(payload, password: "päss wörd 🔒")
        #expect(try SessionExportCodec.probe(data) == true)
        let decoded = try SessionExportCodec.decode(data, password: "päss wörd 🔒")
        #expect(decoded == payload)
        // Plaintext must not leak into the encrypted file.
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("deploy"))
        #expect(!text.contains("geh€im"))
    }

    @Test func wrongPasswordFailsWithoutOracle() throws {
        let data = try SessionExportCodec.encode(samplePayload(), password: "right")
        #expect(throws: SessionExportError.wrongPasswordOrCorrupted) {
            _ = try SessionExportCodec.decode(data, password: "wrong")
        }
    }

    @Test func tamperedCiphertextFailsWithSameError() throws {
        let data = try SessionExportCodec.encode(samplePayload(), password: "pw")
        var envelope = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var ciphertext = Data(base64Encoded: envelope["ciphertext"] as! String)!
        ciphertext[ciphertext.count / 2] ^= 0xFF
        envelope["ciphertext"] = ciphertext.base64EncodedString()
        let tampered = try JSONSerialization.data(withJSONObject: envelope)
        #expect(throws: SessionExportError.wrongPasswordOrCorrupted) {
            _ = try SessionExportCodec.decode(tampered, password: "pw")
        }
    }

    @Test func encryptedFileWithoutPasswordAsksForOne() throws {
        let data = try SessionExportCodec.encode(samplePayload(), password: "pw")
        #expect(throws: SessionExportError.passwordRequired) {
            _ = try SessionExportCodec.decode(data, password: nil)
        }
    }

    @Test func garbageAndForeignJSONAreRejected() throws {
        #expect(throws: SessionExportError.notAnExportFile) {
            _ = try SessionExportCodec.probe(Data("not json at all".utf8))
        }
        let foreign = Data(#"{"something":"else"}"#.utf8)
        #expect(throws: SessionExportError.notAnExportFile) {
            _ = try SessionExportCodec.decode(foreign, password: nil)
        }
    }

    @Test func newerVersionIsRejectedWithItsNumber() throws {
        let future = Data(#"{"format":"macscp-sessions","version":99,"encrypted":false,"payload":{}}"#.utf8)
        #expect(throws: SessionExportError.unsupportedVersion(99)) {
            _ = try SessionExportCodec.probe(future)
        }
    }

    /// Builds a syntactically well-formed encrypted envelope with the given
    /// `iterations` override, the same way `tamperedCiphertextFailsWithSameError`
    /// tampers the ciphertext — via `JSONSerialization` on a real encoded
    /// envelope, so salt/ciphertext stay well-formed and only `iterations`
    /// is hostile.
    private func envelopeData(iterationsOverride: Any) throws -> Data {
        let data = try SessionExportCodec.encode(samplePayload(), password: "pw")
        var envelope = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        envelope["iterations"] = iterationsOverride
        return try JSONSerialization.data(withJSONObject: envelope)
    }

    // MARK: - Hostile `iterations` (M9a final review, Finding 1 — critical)
    //
    // `decode` used to pass the file's `iterations` straight to
    // `CCKeyDerivationPBKDF` unchecked. A negative or absurdly large value
    // traps the process (reproduced: signal 5); an in-range multi-billion
    // value freezes the main thread for minutes. These three prove the
    // fixed `decode` rejects all of them up front as a structurally invalid
    // envelope — password-independent, so no oracle is introduced.

    @Test func negativeIterationsIsRejectedAsNotAnExportFile() throws {
        let data = try envelopeData(iterationsOverride: -1)
        #expect(throws: SessionExportError.notAnExportFile) {
            _ = try SessionExportCodec.decode(data, password: "pw")
        }
    }

    @Test func zeroIterationsIsRejectedAsNotAnExportFile() throws {
        let data = try envelopeData(iterationsOverride: 0)
        #expect(throws: SessionExportError.notAnExportFile) {
            _ = try SessionExportCodec.decode(data, password: "pw")
        }
    }

    @Test func absurdlyLargeIterationsIsRejectedAsNotAnExportFile() throws {
        let data = try envelopeData(iterationsOverride: 5_000_000_000)
        #expect(throws: SessionExportError.notAnExportFile) {
            _ = try SessionExportCodec.decode(data, password: "pw")
        }
    }

    @Test func inRangeVersionGarbageBodyIsRejectedAsNotAnExportFile() throws {
        let garbage = Data(#"{"format":"macscp-sessions","version":1,"encrypted":"yes"}"#.utf8)
        #expect(throws: SessionExportError.notAnExportFile) {
            _ = try SessionExportCodec.decode(garbage, password: nil)
        }
    }

    /// Table test: a grab-bag of structurally malformed encrypted envelopes
    /// — bad salt length, wrong-typed fields, truncated ciphertext base64 —
    /// each must throw a typed `SessionExportError`, never trap.
    @Test func malformedEncryptedEnvelopesAlwaysThrowATypedError() throws {
        let base = try JSONSerialization.jsonObject(
            with: SessionExportCodec.encode(samplePayload(), password: "pw")) as! [String: Any]

        var wrongSaltLength = base
        wrongSaltLength["salt"] = Data([0x01, 0x02]).base64EncodedString() // too short for AES-GCM key derivation
        var wrongTypedIterations = base
        wrongTypedIterations["iterations"] = "600000" // string, not a number
        var truncatedCiphertext = base
        let ciphertext = Data(base64Encoded: base["ciphertext"] as! String)!
        truncatedCiphertext["ciphertext"] = ciphertext.prefix(4).base64EncodedString()
        var nonBase64Salt = base
        nonBase64Salt["salt"] = "not-base64!!!"

        for malformed in [wrongSaltLength, wrongTypedIterations, truncatedCiphertext, nonBase64Salt] {
            let data = try JSONSerialization.data(withJSONObject: malformed)
            #expect(throws: SessionExportError.self) {
                _ = try SessionExportCodec.decode(data, password: "pw")
            }
        }
    }

    // MARK: - Jump host fields (M10c)

    @Test func legacyPayloadWithoutJumpFieldsDecodesNilJump() throws {
        let raw = Data("""
        {"format":"macscp-sessions","version":1,"encrypted":false,"payload":{"includesSecrets":false,\
        "groups":[],"sessions":[{"id":"\(UUID().uuidString)","name":"web","host":"h","port":22,\
        "username":"u","authKind":"password"}]}}
        """.utf8)
        let payload = try SessionExportCodec.decode(raw, password: nil)
        #expect(payload.sessions.first?.jumpHost == nil)
        #expect(payload.sessions.first?.jumpPort == nil)
        #expect(payload.sessions.first?.jumpUsername == nil)
        #expect(payload.sessions.first?.jumpAuthKind == nil)
        #expect(payload.sessions.first?.jumpKeyPath == nil)
        #expect(payload.sessions.first?.jumpPassword == nil)
    }

    @Test func jumpFieldsRoundtripThroughEncodeDecode() throws {
        let groupID = UUID()
        let payload = SessionExportPayload(
            includesSecrets: true,
            groups: [ExportedGroup(id: groupID, name: "Prod")],
            sessions: [ExportedSession(
                id: UUID(), name: "web", kind: .ssh,
                fields: sshExportFields(host: "h", username: "u"),
                groupID: groupID, password: "pw",
                jumpHost: "bastion.example.com", jumpPort: 2222, jumpUsername: "jumper",
                jumpAuthKind: .privateKey, jumpKeyPath: "/k", jumpPassword: "jp")])
        let data = try SessionExportCodec.encode(payload, password: nil)
        let decoded = try SessionExportCodec.decode(data, password: nil)
        #expect(decoded == payload)
    }

    // MARK: - Agent auth (M10d/T3)

    /// `authKind`/`jumpAuthKind` == "agent" travels as a plain value through
    /// the envelope, just like "password"/"privateKey" — no special casing
    /// needed in the codec itself.
    @Test func agentAuthKindRoundtripsThroughEncodeDecode() throws {
        let payload = SessionExportPayload(
            includesSecrets: false,
            groups: [],
            sessions: [ExportedSession(
                id: UUID(), name: "web", kind: .ssh,
                fields: sshExportFields(host: "h", username: "u", authKind: .agent),
                jumpHost: "bastion.example.com", jumpPort: 22, jumpUsername: "jumper",
                jumpAuthKind: .agent)])
        let data = try SessionExportCodec.encode(payload, password: nil)
        let decoded = try SessionExportCodec.decode(data, password: nil)
        #expect(decoded == payload)
        #expect(decoded.sessions.first?.fields["SSHField.authKind"] == "agent")
        #expect(decoded.sessions.first?.jumpAuthKind == .agent)
    }

    // MARK: - Connection kind + S3 fields (M12)

    @Test func s3SessionWithKindAndFieldsRoundtripsThroughEncodeDecode() throws {
        let payload = SessionExportPayload(
            includesSecrets: true,
            groups: [],
            sessions: [ExportedSession(
                id: UUID(), name: "s3-prod", kind: .s3,
                fields: s3ExportFields(
                    accessKeyID: "AKIAEXAMPLE", region: "eu-central-1",
                    endpoint: "https://s3.eu-central-1.amazonaws.com", bucket: "my-bucket",
                    usePathStyle: true),
                s3SecretAccessKey: "shh-secret")])
        let data = try SessionExportCodec.encode(payload, password: "pw")
        let decoded = try SessionExportCodec.decode(data, password: "pw")
        #expect(decoded == payload)
        let session = decoded.sessions.first!
        #expect(session.kind == .s3)
        #expect(session.fields["S3Field.accessKeyID"] == "AKIAEXAMPLE")
        #expect(session.fields["S3Field.region"] == "eu-central-1")
        #expect(session.fields["S3Field.endpoint"] == "https://s3.eu-central-1.amazonaws.com")
        #expect(session.fields["S3Field.bucket"] == "my-bucket")
        #expect(session.fields["S3Field.usePathStyle"] == "true")
        // The secret is NOT a field: it keeps its own slot, outside the bag.
        #expect(session.s3SecretAccessKey == "shh-secret")
    }

    /// A payload written before M12 has no `kind`/`s3*` keys at all. `kind`
    /// decodes as `nil` (same pattern as `groupID`/jump fields) and the import
    /// planner maps it to `.ssh` -- which is also why `decode` folds this
    /// file's flat triple into the SSH keys of the bag, and into no others.
    @Test func legacyPayloadWithoutKindDecodesNilKind() throws {
        let raw = Data("""
        {"format":"macscp-sessions","version":1,"encrypted":false,"payload":{"includesSecrets":false,\
        "groups":[],"sessions":[{"id":"\(UUID().uuidString)","name":"web","host":"h","port":22,\
        "username":"u","authKind":"password"}]}}
        """.utf8)
        let payload = try SessionExportCodec.decode(raw, password: nil)
        let session = payload.sessions.first!
        #expect(session.kind == nil)
        #expect(session.fields["SSHField.host"] == "h")
        #expect(session.fields["SSHField.port"] == "22")
        #expect(session.fields["SSHField.username"] == "u")
        #expect(session.fields["S3Field.accessKeyID"] == nil)
        #expect(session.fields["S3Field.region"] == nil)
        #expect(session.fields["S3Field.endpoint"] == nil)
        #expect(session.fields["S3Field.bucket"] == nil)
        #expect(session.fields["S3Field.usePathStyle"] == nil)
        #expect(session.s3SecretAccessKey == nil)
        // Same story for the WebDAV columns (M21/M23): a pre-fix file has no
        // `webdav*` keys at all and must still decode, adding nothing.
        #expect(session.fields["WebDAVField.baseURL"] == nil)
        #expect(session.fields["WebDAVField.username"] == nil)
        #expect(session.fields["WebDAVField.useNextcloudPath"] == nil)
    }

    // MARK: - WebDAV fields (M23 fix — the export dropped them entirely)

    @Test func webdavSessionWithKindAndFieldsRoundtripsThroughEncodeDecode() throws {
        let payload = SessionExportPayload(
            includesSecrets: true,
            groups: [],
            sessions: [ExportedSession(
                id: UUID(), name: "nextcloud", kind: .webdav,
                fields: webdavExportFields(
                    baseURL: "https://dav.example.com/dav", username: "alice",
                    useNextcloudPath: true),
                password: "dav-secret")])
        let data = try SessionExportCodec.encode(payload, password: "pw")
        let decoded = try SessionExportCodec.decode(data, password: "pw")
        #expect(decoded == payload)
        let session = decoded.sessions.first!
        #expect(session.kind == .webdav)
        #expect(session.fields["WebDAVField.baseURL"] == "https://dav.example.com/dav")
        #expect(session.fields["WebDAVField.username"] == "alice")
        #expect(session.fields["WebDAVField.useNextcloudPath"] == "true")
        // WebDAV has no secret column of its own: the password travels in the
        // shared `password` slot, exactly as `StoredWebDAVConfig` has no
        // secret field. Nothing must have been added beside it.
        #expect(session.password == "dav-secret")
    }

    /// A session with NO WebDAV block must not gain any WebDAV key in the
    /// written file. The bag makes this structural rather than a rule the
    /// exporter has to remember: an SSH session's `sessionValues` produces
    /// SSH keys and nothing else, so no other backend can leak into its
    /// entry.
    @Test func sessionWithoutWebDAVBlockWritesNoWebDAVKeys() throws {
        let payload = samplePayload()
        let data = try SessionExportCodec.encode(payload, password: nil)
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.lowercased().contains("webdav"))
        let session = try SessionExportCodec.decode(data).sessions.first!
        #expect(session.fields["WebDAVField.baseURL"] == nil)
        #expect(session.fields["WebDAVField.username"] == nil)
        #expect(session.fields["WebDAVField.useNextcloudPath"] == nil)
        #expect(session.fields.keys.allSatisfy { $0.hasPrefix("SSHField.") })
    }

    // MARK: - FTP (the fourth kind, 2026-11-08)

    /// An FTP session survives the envelope with its five fields and its
    /// Keychain password intact.
    ///
    /// Every expectation is a `Bool` computed before the macro, and nothing
    /// below names a host, a user name or a password in a macro operand or
    /// receiver. `#expect` reports both the SOURCE TEXT of its operands and
    /// what they evaluated to, so `#expect(decoded == payload)` on a payload
    /// carrying a secret prints the secret on the red run — and a red run is
    /// exactly when somebody is reading the output. The sibling suites above
    /// predate that rule; new work does not get to.
    @Test func anFTPSessionRoundTripsThroughTheExportEnvelope() throws {
        let fields = ftpExportFields(initialPath: "/htdocs")
        let payload = SessionExportPayload(
            includesSecrets: true,
            groups: [],
            sessions: [ExportedSession(
                id: UUID(), name: "Uploads", kind: .ftp, fields: fields,
                password: Self.ftpSecret)])

        let data = try SessionExportCodec.encode(payload, password: Self.envelopePassword)
        let decoded = try SessionExportCodec.decode(data, password: Self.envelopePassword)

        let roundTripped = decoded == payload
        #expect(roundTripped)
        let entry: ExportedSession? = decoded.sessions.count == 1 ? decoded.sessions[0] : nil
        #expect(entry?.name == "Uploads")
        #expect(entry?.kind == .ftp)
        // The whole bag at once, so no key can go missing without this
        // failing — and compared as a `Bool`, so a mismatch prints neither
        // side.
        let bagSurvived = entry?.fields == fields
        #expect(bagSurvived)
        // FTP has no secret column of its own either: the password rides the
        // shared slot, as WebDAV's does.
        let secretSurvived = entry?.password == Self.ftpSecret
        #expect(secretSurvived)
        // Nothing invented a second backend's key alongside FTP's.
        let onlyFTPKeys = entry?.fields.keys.allSatisfy { $0.hasPrefix("\(FTPField.namespace).") }
        #expect(onlyFTPKeys == true)
    }

    /// The password the envelope is locked with, and the Keychain secret the
    /// FTP entry carries. Named constants rather than literals at the call
    /// site: a literal inside a macro operand is reported verbatim when the
    /// expectation fails.
    private static let envelopePassword = "envelope-pw"
    private static let ftpSecret = "ftp-secret"

    // MARK: - An unknown kind refuses its entry, not the document

    /// A file naming a kind this build has no case for. Before this task
    /// `ConnectionKind`'s synthesized `Decodable` threw on it, and because
    /// the enclosing array threw with it, ONE such entry voided the whole
    /// document — so an older macSCP reading an export that contains an FTP
    /// session imported nothing at all.
    ///
    /// Both halves in one test, per this project's rule that a negative
    /// check needs a positive one beside it: `"smb"` is skipped and named,
    /// and the byte-for-byte same file with `"ftp"` in its place keeps both
    /// entries and skips none. Without the second half, a decoder that
    /// dropped EVERY session would satisfy the first.
    @Test func anExportCarryingAnUnknownKindSkipsThatEntryAndKeepsTheRest() throws {
        let unknown = try SessionExportCodec.decode(Self.twoSessionFile(secondKind: "smb"))
        #expect(unknown.sessions.map(\.name) == ["keep"])
        #expect(unknown.skippedKinds == ["smb"])
        // The rest of the document is intact, not merely present.
        #expect(unknown.includesSecrets == false)
        #expect(unknown.groups.map(\.name) == ["Prod"])
        let keptFields = unknown.sessions.first?.fields["SSHField.host"] != nil
        #expect(keptFields)

        // The positive control: the same file, one kind name different.
        let known = try SessionExportCodec.decode(Self.twoSessionFile(secondKind: "ftp"))
        #expect(known.sessions.map(\.name) == ["keep", "future"])
        #expect(known.skippedKinds.isEmpty)
        #expect(known.sessions.last?.kind == .ftp)
    }

    /// A payload whose ONLY session names an unknown kind decodes to an
    /// empty session list rather than to a thrown error — the "never a
    /// failed document" half, where there is no surviving entry to carry it.
    @Test func afileWhoseOnlySessionIsAnUnknownKindDecodesEmptyRatherThanThrowing() throws {
        let raw = Data("""
        {"format":"macscp-sessions","version":2,"encrypted":false,"payload":{"includesSecrets":false,\
        "groups":[],"sessions":[{"id":"\(UUID().uuidString)","name":"future","kind":"smb",\
        "fields":{"SMBField.share":"public"}}]}}
        """.utf8)
        let payload = try SessionExportCodec.decode(raw, password: nil)
        #expect(payload.sessions.isEmpty)
        #expect(payload.skippedKinds == ["smb"])
    }

    /// A raw kind name can be the EMPTY STRING, and the skip path takes it.
    /// `KindTolerantEntry` diverts an entry whose `kind` key is present,
    /// reads as a `String`, and names no case of `ConnectionKind`; `""`
    /// satisfies all three, so `skippedKinds` holds `""`.
    ///
    /// Written down because it constrains the App layer, not because it is
    /// a choice this codec makes: anything that REPORTED what was skipped
    /// by name would render this as a bare pair of quotes in four
    /// languages, which is why `ImportFeedbackText.skippedKindsLine`
    /// reports a count.
    ///
    /// The positive check beside it is the second half: the session that IS
    /// readable survives, so a decoder that dropped everything would not
    /// satisfy the first.
    @Test func anEntryWhoseKindIsTheEmptyStringIsStillSkipped() throws {
        let payload = try SessionExportCodec.decode(Self.twoSessionFile(secondKind: ""))
        #expect(payload.skippedKinds == [""])
        #expect(payload.sessions.map(\.name) == ["keep"])
    }

    /// `skippedKinds` is a fact about the FILE that was read, so it must not
    /// be writable into one: a crafted export naming kinds it does not carry
    /// would otherwise report skips that never happened.
    @Test func skippedKindsIsNeverWrittenToAFile() throws {
        let decoded = try SessionExportCodec.decode(Self.twoSessionFile(secondKind: "smb"))
        #expect(decoded.skippedKinds == ["smb"])  // the anchor: there IS one to lose

        let data = try SessionExportCodec.encode(decoded, password: nil)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("skippedKinds") == false)
        #expect(json.contains("smb") == false)
        #expect(try SessionExportCodec.decode(data).skippedKinds.isEmpty)
    }

    /// The tolerance's OTHER side, and the one line this task's change
    /// rests on: an entry refused for a reason that is NOT its kind still
    /// refuses the whole document. `KindTolerantEntry.init(from:)` ends in
    /// `self = .readable(try Entry(from: decoder))`, which rethrows; soften
    /// that `try` and a corrupt file becomes a silent partial import, which
    /// is a worse answer than the wholesale refusal this task replaced.
    ///
    /// Three shapes, all under a kind this build DOES have a case for, so
    /// none of them can be satisfied by the skip path: a required field
    /// missing, a required field of the wrong type, and an entry that is
    /// not an object at all.
    ///
    /// The fourth case is the positive check standing beside them — the
    /// same file, well formed, decodes and carries its one session.
    /// Without it a decoder that threw on everything would satisfy the
    /// first three.
    @Test func anEntryMalformedForAReasonOtherThanItsKindStillVoidsTheDocument() throws {
        // A required field missing. `name` is non-optional on
        // `ExportedSession`, and the kind is one this build reads.
        #expect(throws: SessionExportError.notAnExportFile) {
            try SessionExportCodec.decode(Self.oneSessionFile(entry: """
                {"id":"\(UUID().uuidString)","kind":"ssh","fields":{"SSHField.host":"h"}}
                """))
        }
        // A required field of the wrong type.
        #expect(throws: SessionExportError.notAnExportFile) {
            try SessionExportCodec.decode(Self.oneSessionFile(entry: """
                {"id":"\(UUID().uuidString)","name":42,"kind":"ssh",\
                "fields":{"SSHField.host":"h"}}
                """))
        }
        // Not an object, so there is no `kind` key to read and no entry to
        // skip — the element's own decoder refuses it, as it did before.
        #expect(throws: SessionExportError.notAnExportFile) {
            try SessionExportCodec.decode(Self.oneSessionFile(entry: "7"))
        }

        // The positive check: the same file, nothing wrong with it.
        let wellFormed = try SessionExportCodec.decode(Self.oneSessionFile(entry: """
            {"id":"\(UUID().uuidString)","name":"keep","kind":"ssh",\
            "fields":{"SSHField.host":"h"}}
            """))
        #expect(wellFormed.sessions.map(\.name) == ["keep"])
        #expect(wellFormed.skippedKinds.isEmpty)
    }

    /// One group and exactly one session, the session written out as the
    /// raw JSON given. Bytes rather than an encoded payload for the same
    /// reason `twoSessionFile` below is: the shapes under test cannot be
    /// produced by encoding a `SessionExportPayload`.
    private static func oneSessionFile(entry: String) -> Data {
        Data("""
        {"format":"macscp-sessions","version":2,"encrypted":false,"payload":{"includesSecrets":false,\
        "groups":[{"id":"\(UUID().uuidString)","name":"Prod"}],"sessions":[\(entry)]}}
        """.utf8)
    }

    /// Two sessions and one group, with the second session's `kind` as
    /// given. Built as bytes rather than by encoding a payload, because a
    /// kind this build has no case for cannot be ENCODED from here — which
    /// is the whole situation under test.
    private static func twoSessionFile(secondKind: String) -> Data {
        Data("""
        {"format":"macscp-sessions","version":2,"encrypted":false,"payload":{"includesSecrets":false,\
        "groups":[{"id":"\(UUID().uuidString)","name":"Prod"}],\
        "sessions":[{"id":"\(UUID().uuidString)","name":"keep","kind":"ssh",\
        "fields":{"SSHField.host":"h","SSHField.port":"22","SSHField.username":"u"}},\
        {"id":"\(UUID().uuidString)","name":"future","kind":"\(secondKind)",\
        "fields":{"FTPField.host":"h","FTPField.port":"21","FTPField.username":"u",\
        "FTPField.security":"explicitTLS","FTPField.initialPath":""}}]}}
        """.utf8)
    }

    // MARK: - The field bag (M23/P3)

    /// The one test that proves an export file somebody already has still
    /// imports. Everything else about this phase is provable by argument; this
    /// is a fact about bytes on disk.
    @Test func aV1ExportStillDecodesIntoTheFieldBag() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/legacy-export-v1.macscp.json")
        let payload = try SessionExportCodec.decode(try Data(contentsOf: url))

        let prod = try #require(payload.sessions.first { $0.name == "Prod" })
        #expect(prod.kind == .ssh)
        #expect(prod.fields["SSHField.host"] == "prod.example.com")
        #expect(prod.fields["SSHField.port"] == "2222")
        #expect(prod.fields["SSHField.username"] == "deploy")

        let archive = try #require(payload.sessions.first { $0.name == "Archive" })
        #expect(archive.kind == .s3)
        #expect(archive.fields["S3Field.bucket"] == "archive")
        #expect(archive.fields["S3Field.usePathStyle"] == "true")
        // The v1 file carried SSH's flat triple for every kind, holding the
        // literal placeholder. It must NOT survive into the bag.
        #expect(archive.fields["SSHField.host"] == nil)

        let cloud = try #require(payload.sessions.first { $0.name == "Cloud" })
        #expect(cloud.kind == .webdav)
        #expect(cloud.fields["WebDAVField.baseURL"] == "https://cloud.example.com/remote.php/dav")
    }

    // MARK: - Nesting and positions (D1/D2)

    /// A folder's parent and everyone's rank travel in the file. `parentID`
    /// names another `ExportedGroup.id` — file-local, like
    /// `ExportedSession.groupID` — so the codec's job is only to carry it
    /// intact; rekeying it is the import planner's.
    @Test func nestingAndPositionsRoundtripThroughEncodeDecode() throws {
        let outerID = UUID()
        let innerID = UUID()
        var session = ExportedSession(
            id: UUID(), name: "web", kind: .ssh,
            fields: sshExportFields(host: "h", username: "u"), groupID: innerID)
        session.position = 4
        let payload = SessionExportPayload(
            includesSecrets: false,
            groups: [
                ExportedGroup(id: outerID, name: "Outer", position: 0),
                ExportedGroup(id: innerID, name: "Inner", parentID: outerID, position: 1),
            ],
            sessions: [session])

        let data = try SessionExportCodec.encode(payload, password: nil)
        let decoded = try SessionExportCodec.decode(data, password: nil)
        #expect(decoded == payload)
        #expect(decoded.groups.last?.parentID == outerID)
        #expect(decoded.groups.last?.position == 1)
        #expect(decoded.sessions.first?.position == 4)
    }

    /// A file written before folders could nest carries neither key. It has
    /// to decode: a `keyNotFound` on `position` would make every export
    /// anybody already has unreadable, which is the same trap
    /// `StoredGroup.init(from:)` avoids for `sessions-v2.json`.
    @Test func aPayloadWithoutNestingKeysDecodesWithoutThem() throws {
        let raw = Data("""
        {"format":"macscp-sessions","version":2,"encrypted":false,"payload":{"includesSecrets":false,\
        "groups":[{"id":"\(UUID().uuidString)","name":"Prod"}],\
        "sessions":[{"id":"\(UUID().uuidString)","name":"web","kind":"ssh",\
        "fields":{"SSHField.host":"h","SSHField.port":"22","SSHField.username":"u"}}]}}
        """.utf8)
        let payload = try SessionExportCodec.decode(raw, password: nil)
        #expect(payload.groups.first?.name == "Prod")
        #expect(payload.groups.first?.parentID == nil)
        #expect(payload.groups.first?.position == nil)
        #expect(payload.sessions.first?.position == nil)
    }

    /// A v2 file round-trips through the bag with no column-shaped loss.
    @Test(arguments: ConnectionKind.allCases)
    func aSessionRoundTripsThroughTheBag(kind: ConnectionKind) throws {
        let session: StoredSession
        switch kind {
        case .ssh: session = sshSession(
            name: "s", host: "h.example.com", port: 2222, username: "u",
            authKind: .privateKey, keyPath: "/k")
        case .s3: session = s3Session(name: "s")
        case .webdav: session = webdavSession(name: "s")
        case .ftp: session = ftpSession(name: "s")
        }

        let descriptor = BackendDescriptor.descriptor(for: kind)
        var exported = ExportedSession(
            id: session.id, name: session.name, kind: kind,
            fields: descriptor.sessionValues(session).raw)
        exported.groupID = nil

        var rebuilt = StoredSession(
            id: session.id, name: session.name, kind: kind)
        var values = FieldValues()
        for (key, value) in exported.fields { values.setRaw(key, to: value) }
        descriptor.apply(values, &rebuilt)

        #expect(rebuilt == session)
    }

    // MARK: - `replaces` never crosses the file boundary (2026-09-03)

    /// `ExportedSession.replaces` names a STORE record id, which is the one
    /// thing in this type that means nothing outside the machine that wrote
    /// it — and everything if a crafted file names a record here. It is
    /// in-memory only: the encoder never writes it.
    @Test func replacesIsNeverWrittenToAFile() throws {
        let target = UUID()
        let payload = SessionExportPayload(
            includesSecrets: false, groups: [],
            sessions: [ExportedSession(
                id: UUID(), name: "web", kind: .ssh,
                fields: sshExportFields(host: "h", port: 22, username: "u"),
                replaces: target)])

        let data = try SessionExportCodec.encode(payload, password: nil)

        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"replaces\"") == false)
        #expect(text.contains(target.uuidString) == false)
        // The positive anchor: the file DOES carry this session, so the two
        // absences above are about `replaces` and not about an empty file.
        #expect(text.contains("web"))
        #expect(try SessionExportCodec.decode(data, password: nil)
            .sessions.first?.replaces == nil)
    }

    /// … and the decoder never reads one, so a hand-crafted file naming a
    /// local session id cannot reach `SessionImportPlanner`'s replace-by-id
    /// branch. Without this the entry would overwrite that record in place —
    /// no conflict sheet, and (carrying no password) the victim's Keychain
    /// slot left bound to whatever host the file names.
    @Test func aFileCarryingAReplacesKeyDecodesWithoutIt() throws {
        let target = UUID()
        let raw = Data("""
        {"format":"macscp-sessions","version":2,"encrypted":false,"payload":{"includesSecrets":false,\
        "groups":[],"sessions":[{"id":"\(UUID().uuidString)","name":"web","kind":"ssh",\
        "fields":{"SSHField.host":"attacker.example.net","SSHField.port":"22",\
        "SSHField.username":"u"},"replaces":"\(target.uuidString)"}]}}
        """.utf8)

        let payload = try SessionExportCodec.decode(raw, password: nil)

        let session = payload.sessions.first
        #expect(session?.replaces == nil)
        // The anchor: the rest of that same entry decoded fine, so the nil
        // above is the key being ignored and not the file being rejected.
        #expect(session?.fields["SSHField.host"] == "attacker.example.net")
    }
}
