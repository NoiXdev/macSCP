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
    /// CONCLUSION (deliberate): this is NOT made a decode error.
    ///
    /// Note first what is NOT the reason, because an earlier draft of this
    /// comment claimed it and it is false: the legacy payload and a valid
    /// `.s3`/`.webdav` record are NOT indistinguishable at the decoder.
    /// `init(from:)` reads `kind` (`StoredSession.swift:129`) BEFORE `ssh`
    /// (`:130`), so a rule `if kind == .ssh && ssh == nil { throw }` would
    /// reject the legacy payload and accept every non-SSH record. Nor would it
    /// falsely reject a legitimate v2 record: `SSHFieldSchema.apply` installs
    /// the block unconditionally (`var ssh = session.ssh ?? StoredSSHConfig(…)`,
    /// then assigns it back) and is the only write adapter for `.ssh`, so no
    /// `.ssh` session is ever persisted without one. Such a rule is entirely
    /// implementable.
    ///
    /// The reason it is still not worth having is BLAST RADIUS.
    /// `SessionStore.StoreFile.sessions` is a plain `[StoredSession]` decoded
    /// as one array, so a single throwing element aborts the whole array and
    /// therefore the whole file. One malformed record would take every other
    /// connection down with it — precisely the "one bad thing hides all your
    /// connections" failure that M1 removed from the migration path in this
    /// same round. Trading a documented, unreachable-in-practice hazard for
    /// that is a bad trade.
    ///
    /// What protects against it is routing, not validation: `SessionStore`
    /// reads `sessions.json` only through `LegacyStoredSession`, and this test
    /// exists so that a future caller handing legacy JSON to the wrong type
    /// finds the trap documented instead of a hostless connection. If the
    /// store ever decodes sessions element-by-element (skipping and reporting
    /// bad records rather than failing the file), revisit this — at that point
    /// the rule costs nothing and should be added.
    @Test func aLegacyPayloadDecodedAsStoredSessionIsSilentlyBlockLess() throws {
        let legacy = """
        {"id":"\(UUID().uuidString)","name":"old","host":"h","port":22,"username":"u","authKind":"password"}
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(StoredSession.self, from: legacy)
        #expect(s.kind == .ssh)
        #expect(s.ssh == nil)
        // Through M25, the inventing `host`/`port` accessors reported a
        // connection nobody can dial — the reason this must never be the
        // decode path for a legacy file. M26 deletes those accessors;
        // `SSHFieldSchema.values(from:)`, their sole sanctioned successor,
        // now guards on the missing block and yields the empty bag instead.
        #expect(SSHFieldSchema.values(from: s).raw.isEmpty)
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
