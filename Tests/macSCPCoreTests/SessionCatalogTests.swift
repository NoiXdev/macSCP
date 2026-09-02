import Foundation
import Testing
@testable import macSCPCore

/// `SessionCatalog` lists and filters an in-memory set of stored sessions —
/// no disk, no keychain. Every store here is hand-built.
@Suite("Session catalog")
struct SessionCatalogTests {
    // MARK: - (a) No filter: every session, in sidebar order

    @Test func noFilterReturnsEverySessionInSidebarOrder() {
        // Two top-level groups (Alpha before Beta), one session inside each,
        // and one top-level session that sorts after both groups — the same
        // (position, kind) merge `SidebarOrdering.children` performs.
        let alpha = StoredGroup(name: "Alpha", position: 0)
        let beta = StoredGroup(name: "Beta", position: 1)
        var inAlpha = sshSession(name: "in-alpha", groupID: alpha.id)
        inAlpha.position = 0
        var inBeta = sshSession(name: "in-beta", groupID: beta.id)
        inBeta.position = 0
        var top = sshSession(name: "top")
        top.position = 2

        let catalog = SessionCatalog(
            sessions: [top, inBeta, inAlpha], groups: [beta, alpha])
        let names = catalog.rows(matching: .init()).map(\.name)

        #expect(names == ["in-alpha", "in-beta", "top"])
    }

    // MARK: - (b) group matches ancestor name

    @Test func groupFilterMatchesTheSessionsGroupOrAnyAncestor() {
        let work = StoredGroup(name: "Work")
        let prod = StoredGroup(name: "Prod", parentID: work.id)
        let inProd = sshSession(name: "deep", groupID: prod.id)
        let elsewhere = sshSession(name: "elsewhere")

        let catalog = SessionCatalog(sessions: [inProd, elsewhere], groups: [work, prod])

        #expect(catalog.rows(matching: .init(group: "Work")).map(\.name) == ["deep"])
        #expect(catalog.rows(matching: .init(group: "Prod")).map(\.name) == ["deep"])
        #expect(catalog.rows(matching: .init(group: "work")).map(\.name) == ["deep"])
        #expect(catalog.rows(matching: .init(group: "Nowhere")).isEmpty)
    }

    // MARK: - (c) kind

    @Test func kindFilterKeepsOnlyThatBackend() {
        let ssh = sshSession(name: "a")
        let s3 = s3Session(name: "b")
        let webdav = webdavSession(name: "c")
        let catalog = SessionCatalog(sessions: [ssh, s3, webdav], groups: [])

        #expect(catalog.rows(matching: .init(kind: .s3)).map(\.name) == ["b"])
    }

    // MARK: - (d) name: case-insensitive substring, not a glob

    @Test func nameFilterIsACaseInsensitiveSubstringNotAGlob() {
        let session = sshSession(name: "Production")
        let catalog = SessionCatalog(sessions: [session], groups: [])

        #expect(catalog.rows(matching: .init(name: "prod")).map(\.name) == ["Production"])
        #expect(catalog.rows(matching: .init(name: "PRODUCTION")).map(\.name) == ["Production"])
        #expect(catalog.rows(matching: .init(name: "pro*")).isEmpty)
    }

    // MARK: - (e) tag: exact, case-insensitive

    @Test func tagFilterIsExactAndCaseInsensitive() {
        var docker = sshSession(name: "a")
        docker.tags = ["Docker"]
        var web = sshSession(name: "b")
        web.tags = ["web"]
        let catalog = SessionCatalog(sessions: [docker, web], groups: [])

        #expect(catalog.rows(matching: .init(tag: "docker")).map(\.name) == ["a"])
        #expect(catalog.rows(matching: .init(tag: "dock")).isEmpty)
    }

    // MARK: - (f) filters AND

    @Test func filtersCombineWithAnd() {
        var match = sshSession(name: "prod-box")
        match.tags = ["docker"]
        var wrongKind = s3Session(name: "prod-bucket")
        wrongKind.tags = ["docker"]
        var wrongTag = sshSession(name: "prod-other")
        wrongTag.tags = ["web"]
        var wrongName = sshSession(name: "staging-box")
        wrongName.tags = ["docker"]

        let catalog = SessionCatalog(
            sessions: [match, wrongKind, wrongTag, wrongName], groups: [])
        let filter = SessionCatalog.Filter(kind: .ssh, name: "prod", tag: "docker")

        #expect(catalog.rows(matching: filter).map(\.name) == ["prod-box"])
    }

    // MARK: - (g) target per kind

    @Test func targetIsFormattedPerKind() {
        let ssh = sshSession(name: "a", host: "box.example.com", port: 2222, username: "tim")
        let s3 = s3Session(
            name: "b",
            config: StoredS3Config(
                accessKeyID: "AKIA", region: "eu-central-1",
                endpoint: "https://s3.example.com", bucket: "my-bucket", usePathStyle: false))
        let webdav = webdavSession(
            name: "c",
            config: StoredWebDAVConfig(
                baseURL: "https://cloud.example.com/remote.php/dav",
                username: "tim", useNextcloudPath: false))

        let catalog = SessionCatalog(sessions: [ssh, s3, webdav], groups: [])
        let rows = Dictionary(uniqueKeysWithValues: catalog.rows(matching: .init()).map { ($0.name, $0) })

        #expect(rows["a"]?.target == "tim@box.example.com:2222")
        #expect(rows["b"]?.target == "my-bucket @ https://s3.example.com")
        #expect(rows["c"]?.target == "https://cloud.example.com/remote.php/dav")
    }

    @Test func sshTargetAlwaysShowsThePortEvenTheDefault() {
        let session = sshSession(name: "a", host: "box.example.com", port: 22, username: "tim")
        let catalog = SessionCatalog(sessions: [session], groups: [])

        #expect(catalog.rows(matching: .init()).first?.target == "tim@box.example.com:22")
    }

    // MARK: - (h) secrecy shape

    /// Structural, not a string search on values: `Row` must carry no
    /// property a secret could hide behind, even when the underlying session
    /// has a `keyPath` and a `loginSetID` set.
    @Test func rowCarriesNothingASecretCouldHideBehind() {
        let session = sshSession(
            name: "a", keyPath: "/Users/tim/.ssh/id_ed25519",
            loginSetID: UUID())
        let catalog = SessionCatalog(sessions: [session], groups: [])
        let row = catalog.rows(matching: .init())[0]

        let fieldNames = Set(Mirror(reflecting: row).children.compactMap(\.label))
        #expect(!fieldNames.contains("keyPath"))
        #expect(!fieldNames.contains("loginSetID"))
        #expect(!fieldNames.contains("secretID"))
        // Positive half of the check: the row actually has fields to scan,
        // so the three assertions above are testing an inspected structure
        // rather than vacuously passing on an empty one.
        #expect(fieldNames.contains("name"))
    }
}
