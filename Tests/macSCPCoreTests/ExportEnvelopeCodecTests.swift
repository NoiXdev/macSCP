import Foundation
import Testing
@testable import macSCPCore

@Suite("ExportEnvelopeCodec")
struct ExportEnvelopeCodecTests {
    private struct Probe: Codable, Equatable {
        var name: String
        var count: Int
    }

    @Test func roundTripsAnyPayloadUnencrypted() throws {
        let payload = Probe(name: "x", count: 3)
        let data = try ExportEnvelopeCodec.encode(payload, format: "macscp-probe", version: 1, password: nil)
        #expect(try ExportEnvelopeCodec.probe(
            data, as: Probe.self, format: "macscp-probe", currentVersion: 1) == false)
        let back = try ExportEnvelopeCodec.decode(
            data, as: Probe.self, format: "macscp-probe", currentVersion: 1, password: nil)
        #expect(back == payload)
    }

    @Test func roundTripsAnyPayloadEncrypted() throws {
        let payload = Probe(name: "x", count: 3)
        let data = try ExportEnvelopeCodec.encode(payload, format: "macscp-probe", version: 1, password: "pw")
        #expect(try ExportEnvelopeCodec.probe(
            data, as: Probe.self, format: "macscp-probe", currentVersion: 1) == true)
        let back = try ExportEnvelopeCodec.decode(
            data, as: Probe.self, format: "macscp-probe", currentVersion: 1, password: "pw")
        #expect(back == payload)
        // The plaintext must not survive anywhere in the encrypted envelope.
        #expect(!String(decoding: data, as: UTF8.self).contains("\"name\""))
    }

    /// Two formats sharing one envelope core must still refuse to read each
    /// other's files — the format string is the discriminator.
    @Test func rejectsAForeignFormat() throws {
        let data = try ExportEnvelopeCodec.encode(Probe(name: "x", count: 1),
                                                 format: "macscp-probe", version: 1, password: nil)
        #expect(throws: SessionExportError.notAnExportFile) {
            _ = try ExportEnvelopeCodec.decode(
                data, as: Probe.self, format: "macscp-other", currentVersion: 1, password: nil)
        }
    }

    @Test func rejectsAFutureVersion() throws {
        let data = try ExportEnvelopeCodec.encode(Probe(name: "x", count: 1),
                                                 format: "macscp-probe", version: 2, password: nil)
        #expect(throws: SessionExportError.unsupportedVersion(2)) {
            _ = try ExportEnvelopeCodec.decode(
                data, as: Probe.self, format: "macscp-probe", currentVersion: 1, password: nil)
        }
    }

    /// `probe` gates on format and version too — the UI calls it first, and a
    /// file from a newer app version must be named as such rather than
    /// reported as "not an export file".
    @Test func probeRejectsAFutureVersion() throws {
        let data = try ExportEnvelopeCodec.encode(Probe(name: "x", count: 1),
                                                 format: "macscp-probe", version: 2, password: nil)
        #expect(throws: SessionExportError.unsupportedVersion(2)) {
            _ = try ExportEnvelopeCodec.probe(
                data, as: Probe.self, format: "macscp-probe", currentVersion: 1)
        }
    }

    @Test func encryptedPayloadWithoutPasswordAsksForOne() throws {
        let data = try ExportEnvelopeCodec.encode(Probe(name: "x", count: 1),
                                                 format: "macscp-probe", version: 1, password: "pw")
        #expect(throws: SessionExportError.passwordRequired) {
            _ = try ExportEnvelopeCodec.decode(
                data, as: Probe.self, format: "macscp-probe", currentVersion: 1, password: nil)
        }
    }

    /// The M9a iteration clamp now lives in the shared core, so it must be
    /// provable there and not only through the session facade: a hostile
    /// `iterations` is rejected before it can reach `CCKeyDerivationPBKDF`
    /// (negative/huge values trap the process; merely-large in-range values
    /// freeze the caller for minutes).
    @Test(arguments: [-1, 0, 5_000_000_000])
    func hostileIterationCountsAreRejectedBeforeKeyDerivation(override: Int) throws {
        let data = try ExportEnvelopeCodec.encode(Probe(name: "x", count: 1),
                                                  format: "macscp-probe", version: 1, password: "pw")
        var envelope = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        envelope["iterations"] = override
        let hostile = try JSONSerialization.data(withJSONObject: envelope)
        #expect(throws: SessionExportError.notAnExportFile) {
            _ = try ExportEnvelopeCodec.decode(
                hostile, as: Probe.self, format: "macscp-probe", currentVersion: 1, password: "pw")
        }
    }

    @Test func wrongPasswordFailsWithoutOracle() throws {
        let data = try ExportEnvelopeCodec.encode(Probe(name: "x", count: 1),
                                                 format: "macscp-probe", version: 1, password: "right")
        #expect(throws: SessionExportError.wrongPasswordOrCorrupted) {
            _ = try ExportEnvelopeCodec.decode(
                data, as: Probe.self, format: "macscp-probe", currentVersion: 1, password: "wrong")
        }
    }
}

/// Byte-for-byte proof that making the envelope generic (M19/T1) did not move
/// a single byte of the `macscp-sessions` on-disk format. Both blobs were
/// produced by the pre-refactor `SessionExportCodec` and pasted in verbatim;
/// if a future change to the envelope alters the encoding, these fail.
@Suite("SessionExportCodec on-disk compatibility")
struct SessionExportCodecByteCompatibilityTests {
    /// Written by the concrete (pre-M19) codec with `password: nil`.
    private static let goldenClear = #"""
    {
      "encrypted" : false,
      "format" : "macscp-sessions",
      "payload" : {
        "groups" : [
          {
            "id" : "11111111-2222-3333-4444-555555555555",
            "name" : "Prod"
          }
        ],
        "includesSecrets" : true,
        "sessions" : [
          {
            "authKind" : "privateKey",
            "groupID" : "11111111-2222-3333-4444-555555555555",
            "host" : "Web-01.example.COM",
            "id" : "66666666-7777-8888-9999-AAAAAAAAAAAA",
            "jumpAuthKind" : "agent",
            "jumpHost" : "bastion.example.com",
            "jumpKeyPath" : "\/k",
            "jumpPassword" : "jp",
            "jumpPort" : 2222,
            "jumpUsername" : "jumper",
            "keyPath" : "\/Users\/x\/.ssh\/id_ed25519",
            "kind" : "s3",
            "name" : "wärter-01 🚀",
            "password" : "geh€im🔑",
            "port" : 2222,
            "s3AccessKeyID" : "AKIAEXAMPLE",
            "s3Bucket" : "my-bucket",
            "s3Endpoint" : "https:\/\/s3.eu-central-1.amazonaws.com",
            "s3Region" : "eu-central-1",
            "s3SecretAccessKey" : "shh-secret",
            "s3UsePathStyle" : true,
            "username" : "deploy"
          }
        ]
      },
      "version" : 1
    }
    """#

    /// Written by the concrete (pre-M19) codec with `password: "päss wörd 🔒"`.
    /// Salt and nonce are random per export, so this exact blob can only ever
    /// be proved decodable — not reproducible.
    private static let goldenEncrypted = #"""
    {
      "ciphertext" : "QgtVU7WCOddySNnupT70Of8ReMe+3uNs58psyu+p7UuU0YDytxIWQrSZG4u7tJg7st5QdpHu9w0QV93XQ0tPkheR6yNrajgqxVD2\/eagZ6xXGNEfwAq5jpIg39UD1mPWdpYfM0V+xunnVg96XWMi72rTGfwCtLRxUJ94DakvX5dZE4t1Z3gGsnHek42A22p8BdhRxoLEMza4jObHwkP016wi\/iJfxPzQ58GJXlEbOhvrxSVtUzPRBvi2WHwUUntxPaqxyIQ\/Src9BudzmH7ao0Gc8a1L51VKTTNzZN3VrHvruIQoU9A3qZkSSLVzT0JBzImPXJPAL\/lnqNZ880WyZRgNYDQxZDuyr9SuoZcBzSyLx0wqTCgrQEtNdOSNesWcNrzPZsiyAQnuoPqNhok1TkgWCQGiwr+SUVvyoRC8MWWlIlycMwIKlochK5T5R9F6pTf7UBSwc9SaHj0g3XJnpu\/EUT29DwntHb3S52oemNLfNd8TvJnlvZBFJYv81fCa7jjXnszAqwlBojnHuKyxcanbwK66oon9pUDHVijaRDUJsWsmiFj3a\/s1XiEn1\/Vzvs\/1\/wFXYp\/i5Ek\/wl1WF0AaiiYQWL6psxMi0JKL082DWFPtJ+WvAawgarK8+agDNMIbqgN0PgPISrKLSpiGOeSmyzzl+Hu7Dn+rthFbQ7F8vk8\/Uyt78+N77uaIfQn4JtOATS07kE70Jon\/6lPWhToYECD8zDxC+HvqV6nkUtkASUR68+NhSP2msUFrNLbFlVlNhCvoVR9KDdFCOtAEcOnJPsATlXu0KGoSLjuk2O2TI0DnEllLaTtKfjOd3sjLlp9EPj94lN51VhqtK6\/SR+Wz0ONTvcuptkOf+HdUjFPe5VmH9OGMR30TTFG9oX8iQrDGMV1UoHlq0G91oHTlbZ4pkOdZFnqoZFoQGp7y6xnRNN9R5EnlMUMZSvTUs\/9Z+pjTmSQgrfiB8iaVUp8zPLtVzJpe1E4h",
      "encrypted" : true,
      "format" : "macscp-sessions",
      "iterations" : 600000,
      "salt" : "OAh\/mfIkjEwZB6pP\/UytOQ==",
      "version" : 1
    }
    """#

    /// What those v1 blobs decode to since M23/P3: the S3 block folded into
    /// the field bag, and the flat SSH triple — `Web-01.example.COM`, port
    /// 2222, `deploy`, a key path — DROPPED, because this session's kind is
    /// `.s3` and that triple was never its connection. The jump, the group
    /// reference and all three secrets survive untouched; they are not
    /// backend fields.
    private func expectedPayload() -> SessionExportPayload {
        let groupID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let sessionID = UUID(uuidString: "66666666-7777-8888-9999-AAAAAAAAAAAA")!
        return SessionExportPayload(
            includesSecrets: true,
            groups: [ExportedGroup(id: groupID, name: "Prod")],
            sessions: [ExportedSession(
                id: sessionID, name: "wärter-01 🚀", kind: .s3,
                fields: s3ExportFields(
                    accessKeyID: "AKIAEXAMPLE", region: "eu-central-1",
                    endpoint: "https://s3.eu-central-1.amazonaws.com", bucket: "my-bucket",
                    usePathStyle: true),
                groupID: groupID, password: "geh€im🔑",
                jumpHost: "bastion.example.com", jumpPort: 2222, jumpUsername: "jumper",
                jumpAuthKind: .agent, jumpKeyPath: "/k", jumpPassword: "jp",
                s3SecretAccessKey: "shh-secret")])
    }

    @Test func clearFileWrittenBeforeTheGenericRefactorStillDecodes() throws {
        let data = Data(Self.goldenClear.utf8)
        #expect(try SessionExportCodec.probe(data) == false)
        #expect(try SessionExportCodec.decode(data) == expectedPayload())
    }

    /// Re-encoding a decoded v1 file used to reproduce it byte for byte, which
    /// is how M19 proved the generic envelope moved nothing. M23/P3 ends that
    /// on purpose: the format takes a HARD CUT to version 2, so what comes back
    /// out is a v2 file. What this pins now is that the cut is exactly as deep
    /// as intended — the envelope itself is untouched (same format string,
    /// same pretty-printed sorted-key encoding, same nested `payload`), and
    /// every column-shaped key is gone from the session entry, replaced by the
    /// bag. A v1 file whose columns leaked back into the written bytes would
    /// fail here.
    @Test func reEncodingAV1FileWritesAVersion2FileWithTheBag() throws {
        let golden = Data(Self.goldenClear.utf8)
        let payload = try SessionExportCodec.decode(golden)
        let written = try SessionExportCodec.encode(payload, password: nil)
        let envelope = try #require(
            try JSONSerialization.jsonObject(with: written) as? [String: Any])

        #expect(envelope["format"] as? String == "macscp-sessions")
        #expect(envelope["version"] as? Int == 2)
        #expect(envelope["encrypted"] as? Bool == false)
        // The envelope's own encoding is unchanged: pretty-printed with
        // sorted keys and a nested payload object, exactly as the v1 blob
        // above is laid out.
        let text = String(decoding: written, as: UTF8.self)
        #expect(text.hasPrefix("{\n  \"encrypted\" : false,\n  \"format\" : \"macscp-sessions\","))

        for column in ["\"host\"", "\"port\"", "\"username\"", "\"authKind\"", "\"keyPath\"",
                       "\"s3AccessKeyID\"", "\"s3Region\"", "\"s3Endpoint\"", "\"s3Bucket\"",
                       "\"s3UsePathStyle\"", "\"webdavBaseURL\"", "\"webdavUsername\""] {
            #expect(!text.contains(column), "v1 column \(column) leaked into a v2 file")
        }
        #expect(text.contains("\"S3Field.bucket\" : \"my-bucket\""))
        // And it still round-trips: what was written decodes back unchanged.
        #expect(try SessionExportCodec.decode(written) == payload)
    }

    @Test func encryptedFileWrittenBeforeTheGenericRefactorStillDecodes() throws {
        let data = Data(Self.goldenEncrypted.utf8)
        #expect(try SessionExportCodec.probe(data) == true)
        #expect(try SessionExportCodec.decode(data, password: "päss wörd 🔒") == expectedPayload())
    }
}
