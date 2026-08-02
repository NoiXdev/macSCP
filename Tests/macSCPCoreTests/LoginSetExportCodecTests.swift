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
}
