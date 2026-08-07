import Foundation
import Testing
@testable import macSCPCore

@Suite("StoredSession kind/s3 (M12)")
struct StoredSessionTests {
    /// Retargeted at `LegacyStoredSession` by M23/T8 fix round 1. Decoded
    /// through `StoredSession` this had become VACUOUS: `host`/`port`/
    /// `username`/`authKind` left `CodingKeys`, so the decoder discards them
    /// and `kind == .ssh` / `s3 == nil` hold for any payload carrying an `id`
    /// and a `name` — including one with no SSH content at all.
    ///
    /// The real question — does a pre-M12 file with no `kind` still land as an
    /// SSH session — is now answered by the type that reads that shape, and
    /// the assertions reach into the block to prove the content arrived rather
    /// than just the default.
    @Test func legacyJSONWithoutKindDecodesAsSSH() throws {
        let legacy = """
        {"id":"\(UUID().uuidString)","name":"old","host":"h","port":22,"username":"u","authKind":"password"}
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(LegacyStoredSession.self, from: legacy).upgraded()
        #expect(s.kind == .ssh)
        #expect(s.s3 == nil)
        #expect(s.ssh?.host == "h")
        #expect(s.ssh?.port == 22)
        #expect(s.ssh?.username == "u")
    }

    /// The hazard the test above uncovered, pinned rather than fixed
    /// (M23/T8 fix round 1).
    ///
    /// `StoredSession.init(from:)` accepts a pre-M23 payload WITHOUT error and
    /// yields a block-less session that reports `kind == .ssh` — an "SSH"
    /// session with no host. Every field it needs is optional or defaulted, so
    /// there is nothing left for the decoder to fail on.
    ///
    /// CONCLUSION (deliberate, see the report): this is NOT made a decode
    /// error. `StoredSession` must keep decoding a payload with no `ssh` block,
    /// because that is exactly what a valid `.s3` or `.webdav` session looks
    /// like — the two cases are indistinguishable at the decoder, so rejecting
    /// one rejects the other. Requiring `ssh` when `kind == .ssh` would also
    /// make the store throw on a single malformed record instead of loading
    /// the rest, which is the failure mode M1 in this same round removed from
    /// the migration.
    ///
    /// What protects against it is routing, not validation: `SessionStore`
    /// reads `sessions.json` only through `LegacyStoredSession`, and this test
    /// exists so that a future caller handing legacy JSON to the wrong type
    /// finds the trap documented instead of a hostless connection.
    @Test func aLegacyPayloadDecodedAsStoredSessionIsSilentlyBlockLess() throws {
        let legacy = """
        {"id":"\(UUID().uuidString)","name":"old","host":"h","port":22,"username":"u","authKind":"password"}
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(StoredSession.self, from: legacy)
        #expect(s.kind == .ssh)
        #expect(s.ssh == nil)
        // The conveniences then report a connection nobody can dial — the
        // reason this must never be the decode path for a legacy file.
        #expect(s.host == "")
        #expect(s.port == 22)
    }

    @Test func s3SessionRoundtrips() throws {
        let s = s3Session(
            name: "obj",
            config: StoredS3Config(accessKeyID: "AK", region: "us-east-1",
                endpoint: "https://s3.amazonaws.com", bucket: "b", usePathStyle: false))
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(StoredSession.self, from: data)
        #expect(back.kind == .s3)
        #expect(back.s3 == s.s3)
        // The persisted session JSON never contains the secret access key.
        #expect(!String(data: data, encoding: .utf8)!.lowercased().contains("secretaccesskey"))
    }
}
