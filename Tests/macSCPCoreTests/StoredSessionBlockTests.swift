import Foundation
import Testing
@testable import macSCPCore

/// The per-backend blocks of a `StoredSession`, taken as a set.
///
/// Two functions each listed the blocks by hand and each missed `ftp`
/// (`SessionDuplication.copy`, `SessionListViewModel.save`). The exhaustive
/// `switch` in `StoredSession.clearBackendBlocks()` / `copyBackendBlocks(from:)`
/// is the structural half of the fix; this suite is the other half, for the
/// block the switch cannot see.
@Suite("StoredSession backend blocks")
struct StoredSessionBlockTests {
    private func fullSession() -> StoredSession {
        StoredSession(
            name: "all", kind: .ssh,
            ssh: StoredSSHConfig(host: "h", username: "u"),
            s3: StoredS3Config(
                accessKeyID: "AK", region: "r", endpoint: "https://e.example.com",
                bucket: "b", usePathStyle: false),
            webdav: StoredWebDAVConfig(
                baseURL: "https://d.example.com", username: "u", useNextcloudPath: false),
            ftp: StoredFTPConfig(host: "f.example.com", port: 21, username: "u", security: .plain))
    }

    /// Every stored property of `StoredSession` that holds an optional
    /// `Stored…Config` -- a per-backend block -- by its label.
    ///
    /// A Mirror over a value, because the thing being asked is "what does the
    /// type declare", which no `ConnectionKind` switch can answer: a block
    /// keyed by nothing would pass every switch in the project. Its positive
    /// companion is the assertion below that the four known labels are found
    /// at all, so a reflection that stopped seeing properties cannot pass by
    /// returning an empty set that happens to equal an empty expectation.
    private func blockLabels() -> Set<String> {
        let mirror = Mirror(reflecting: fullSession())
        return Set(mirror.children.compactMap { child -> String? in
            let type = String(describing: type(of: child.value))
            guard type.hasPrefix("Optional<Stored"), type.hasSuffix("Config>") else { return nil }
            return child.label
        })
    }

    @Test func everyBackendBlockIsAccountedFor() {
        let labels = blockLabels()
        #expect(labels.isEmpty == false)
        #expect(labels == ["ssh", "s3", "webdav", "ftp"], """
            `StoredSession` carries a per-backend block this rule has not been told about \
            (found: \(labels.sorted())). A new block has to be wired into ALL of these, and \
            only the first is checked by the compiler: the `switch` over `ConnectionKind` \
            in `StoredSession.clearBackendBlock(for:)` and `copyBackendBlock(for:from:)` \
            (so `SessionListViewModel.save` clears it on a kind change and \
            `SessionDuplication.copy` carries it), then `CodingKeys` and `init(from:)` \
            here, the memberwise `init`, the descriptor's `apply`, `sessionValues` and \
            `hasStoredConfiguration`, `SessionCatalog.target(for:)`, the overview facts, \
            and the export codec. Then add its label to this set.
            """)
    }

    @Test func clearingEmptiesEveryBlockAndTouchesNothingElse() {
        var session = fullSession()
        session.tags = ["keep"]
        session.clearBackendBlocks()
        #expect(session.ssh == nil && session.s3 == nil && session.webdav == nil && session.ftp == nil)
        #expect(session.tags == ["keep"])
        #expect(session.name == "all")
    }

    @Test func copyingTakesEveryBlockFromTheOtherSession() {
        var target = StoredSession(name: "target", kind: .ftp)
        let source = fullSession()
        target.copyBackendBlocks(from: source)
        #expect(target.ssh == source.ssh)
        #expect(target.s3 == source.s3)
        #expect(target.webdav == source.webdav)
        #expect(target.ftp == source.ftp)
        #expect(target.name == "target")
        #expect(target.kind == .ftp)
    }
}
