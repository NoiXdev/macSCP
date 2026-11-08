import Foundation
import Testing
@testable import macSCPCore

@Suite("LoginSetExportCodec")
struct LoginSetExportCodecTests {
    private func sample(secret: String? = nil, key: EmbeddedKey? = nil) -> LoginSetExportPayload {
        LoginSetExportPayload(
            includesSecrets: secret != nil,
            includesKeyFiles: key != nil,
            sets: [ExportedLoginSet(
                id: UUID(), name: "Prod", kind: .ssh, username: "deploy",
                authKind: .password, keyPath: nil, accessKeyID: nil,
                secret: secret, embeddedKey: key)])
    }

    @Test func roundTripsUnencrypted() throws {
        let payload = sample()
        let data = try LoginSetExportCodec.encode(payload, password: nil)
        #expect(try LoginSetExportCodec.probe(data) == false)
        #expect(try LoginSetExportCodec.decode(data, password: nil) == payload)
    }

    @Test func roundTripsEncrypted() throws {
        let payload = sample(secret: "s3cret")
        let data = try LoginSetExportCodec.encode(payload, password: "pw")
        #expect(try LoginSetExportCodec.probe(data) == true)
        #expect(try LoginSetExportCodec.decode(data, password: "pw") == payload)
    }

    @Test func rejectsTheWrongPassword() throws {
        let data = try LoginSetExportCodec.encode(sample(secret: "s3cret"), password: "pw")
        #expect(throws: SessionExportError.wrongPasswordOrCorrupted) {
            _ = try LoginSetExportCodec.decode(data, password: "nope")
        }
    }

    // A sessions file must not import as logins -- the two formats are
    // distinct, and the shared envelope rejects a format mismatch the same
    // way it rejects any other file that isn't a macSCP export: as
    // structurally unrecognized, not as a decode failure.
    @Test func rejectsASessionsFile() throws {
        let sessions = try SessionExportCodec.encode(
            SessionExportPayload(includesSecrets: false, groups: [], sessions: []), password: nil)
        #expect(throws: SessionExportError.notAnExportFile) {
            _ = try LoginSetExportCodec.decode(sessions, password: nil)
        }
    }

    @Test func rejectsAnUnsupportedVersion() throws {
        let data = try LoginSetExportCodec.encode(sample(), password: nil)
        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        json["version"] = 2
        let tampered = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: SessionExportError.unsupportedVersion(2)) {
            _ = try LoginSetExportCodec.decode(tampered, password: nil)
        }
    }

    // Secret hygiene: without the opt-in, nothing sensitive reaches the
    // file. Asserted on the produced file bytes -- the property that
    // actually matters, not on the in-memory struct.
    @Test func aPlainExportWithoutOptInCarriesNoSecrets() throws {
        let data = try LoginSetExportCodec.encode(sample(), password: nil)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("s3cret"))
        #expect(!text.lowercased().contains("private key"))
    }

    // A privateKey-auth set with the key-files opt-in OFF must not carry an
    // embedded key -- the opt-in gates the field, `authKind` alone doesn't.
    @Test func aPlainExportOfAPrivateKeySetCarriesNoEmbeddedKey() throws {
        let payload = LoginSetExportPayload(
            includesSecrets: false, includesKeyFiles: false,
            sets: [ExportedLoginSet(
                id: UUID(), name: "Build box", kind: .ssh, username: "ci",
                authKind: .privateKey, keyPath: "/managed/keys/abc",
                accessKeyID: nil, secret: nil, embeddedKey: nil)])
        let data = try LoginSetExportCodec.encode(payload, password: nil)
        #expect(try LoginSetExportCodec.decode(data, password: nil) == payload)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("embeddedKey"))
    }

    // MARK: - FTP (the fourth kind, 2026-11-08)

    /// An FTP login set survives the envelope. FTP's credential schema is
    /// username + password, so the set's `authKind` is `.password` and its
    /// secret rides the shared `secret` slot — the same shape an S3 or
    /// WebDAV set has.
    ///
    /// Every expectation is a `Bool` computed first: `#expect` reports what
    /// its operands evaluated to, and `#expect(decoded == payload)` on a
    /// payload carrying a secret prints that secret on the red run.
    @Test func anFTPLoginSetRoundTripsThroughTheExportEnvelope() throws {
        let payload = LoginSetExportPayload(
            includesSecrets: true, includesKeyFiles: false,
            sets: [ExportedLoginSet(
                id: UUID(), name: "Uploads", kind: .ftp, username: "tim",
                authKind: .password, keyPath: nil, accessKeyID: nil,
                secret: Self.ftpSecret, embeddedKey: nil)])

        let data = try LoginSetExportCodec.encode(payload, password: Self.envelopePassword)
        let decoded = try LoginSetExportCodec.decode(data, password: Self.envelopePassword)

        let roundTripped = decoded == payload
        #expect(roundTripped)
        let set: ExportedLoginSet? = decoded.sets.count == 1 ? decoded.sets[0] : nil
        #expect(set?.name == "Uploads")
        #expect(set?.kind == .ftp)
        let secretSurvived = set?.secret == Self.ftpSecret
        #expect(secretSurvived)
        #expect(decoded.skippedKinds.isEmpty)
    }

    /// The login-set half of "an unknown kind refuses its entry, not the
    /// document". `ExportedLoginSet.kind` is NON-optional, so before this
    /// task one set naming a kind this build has no case for threw out of
    /// the whole `sets` array and the file imported nothing.
    ///
    /// The positive control is in the same test: the byte-for-byte same
    /// file with `"ftp"` in place of `"smb"` keeps both sets and skips none,
    /// so a decoder that dropped every set would not satisfy this.
    @Test func aLoginSetFileCarryingAnUnknownKindSkipsThatSetAndKeepsTheRest() throws {
        let unknown = try LoginSetExportCodec.decode(
            Self.twoSetFile(secondKind: "smb"), password: nil)
        #expect(unknown.sets.map(\.name) == ["keep"])
        #expect(unknown.skippedKinds == ["smb"])
        #expect(unknown.includesSecrets == false)
        #expect(unknown.includesKeyFiles == false)
        #expect(unknown.sets.first?.kind == .ssh)

        let known = try LoginSetExportCodec.decode(
            Self.twoSetFile(secondKind: "ftp"), password: nil)
        #expect(known.sets.map(\.name) == ["keep", "future"])
        #expect(known.skippedKinds.isEmpty)
        #expect(known.sets.last?.kind == .ftp)
    }

    /// `skippedKinds` describes the file that was read and must not be
    /// writable into one.
    @Test func aLoginSetExportNeverWritesSkippedKinds() throws {
        let decoded = try LoginSetExportCodec.decode(
            Self.twoSetFile(secondKind: "smb"), password: nil)
        #expect(decoded.skippedKinds == ["smb"])  // the anchor: there IS one to lose

        let data = try LoginSetExportCodec.encode(decoded, password: nil)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("skippedKinds") == false)
        #expect(text.contains("smb") == false)
        #expect(try LoginSetExportCodec.decode(data, password: nil).skippedKinds.isEmpty)
    }

    private static let envelopePassword = "envelope-pw"
    private static let ftpSecret = "ftp-secret"

    /// Two sets, the second one's `kind` as given. Built as bytes, because a
    /// kind this build has no case for cannot be encoded from here.
    private static func twoSetFile(secondKind: String) -> Data {
        Data("""
        {"format":"macscp-logins","version":1,"encrypted":false,\
        "payload":{"includesSecrets":false,"includesKeyFiles":false,"sets":[\
        {"id":"\(UUID().uuidString)","name":"keep","kind":"ssh","username":"u",\
        "authKind":"password"},\
        {"id":"\(UUID().uuidString)","name":"future","kind":"\(secondKind)","username":"u",\
        "authKind":"password"}]}}
        """.utf8)
    }
}
