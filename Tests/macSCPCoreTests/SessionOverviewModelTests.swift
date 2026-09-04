import Foundation
import Testing

@testable import macSCPCore

/// The read-only overview a single click on a stored session shows: what it
/// derives, and — the half that matters more — what it can never carry.
///
/// No keychain is touched here. `SecretPresence` is the seam, and every test
/// below hands it `FakeSecretPresence`; the real
/// `KeychainSecretPresence` is exercised by nothing in this suite on
/// purpose, because a unit test that writes to (or reads from) the login
/// keychain is a test that needs `MACSCP_KEYCHAIN=1` and a machine.
@Suite("Session overview model")
struct SessionOverviewModelTests {
    /// Answers "is a secret stored" from a set of slots, and records what it
    /// was asked — so a test can prove the model asks about the SLOT
    /// (`loginSetID ?? id`) rather than about the session id.
    private final class FakeSecretPresence: SecretPresence, @unchecked Sendable {
        private let slots: Set<UUID>
        private let lock = NSLock()
        private var seen: [UUID] = []

        init(slots: Set<UUID>) { self.slots = slots }

        func hasSecret(for slot: UUID) -> Bool {
            lock.lock()
            seen.append(slot)
            lock.unlock()
            return slots.contains(slot)
        }

        var asked: [UUID] {
            lock.lock()
            defer { lock.unlock() }
            return seen
        }
    }

    private static let noSecrets = FakeSecretPresence(slots: [])

    private func model(
        _ session: StoredSession,
        knownKey: KnownHostKey? = nil,
        secrets: (any SecretPresence)? = nil,
        events: [AuditEvent] = [],
        snippets: [Snippet] = [],
        groupName: String? = nil,
        loginSetName: String? = nil
    ) -> SessionOverviewModel {
        SessionOverviewModel(
            session: session,
            descriptor: .descriptor(for: session.kind),
            knownKey: knownKey,
            secrets: secrets ?? Self.noSecrets,
            events: events,
            snippets: snippets,
            groupName: groupName,
            loginSetName: loginSetName)
    }

    private func sshSession(
        name: String = "web-01",
        host: String = "web-01.example.com",
        port: Int = 2222,
        username: String = "deploy",
        authKind: StoredSession.AuthKind = .privateKey,
        keyPath: String? = "/Users/tester/.ssh/id_ed25519",
        jump: StoredSession.JumpSpec? = nil,
        tags: [String] = [],
        loginSetID: UUID? = nil
    ) -> StoredSession {
        StoredSession(
            name: name, loginSetID: loginSetID, kind: .ssh,
            ssh: StoredSSHConfig(
                host: host, port: port, username: username, authKind: authKind,
                keyPath: keyPath, jump: jump),
            tags: tags)
    }

    private func text(_ model: SessionOverviewModel, _ id: String) -> String? {
        model.facts.first { $0.id == id }?.text
    }

    // MARK: - Head

    @Test func theHeadIsTheNameTheKindAndTheDescriptorsEndpoint() {
        let overview = model(sshSession())

        #expect(overview.name == "web-01")
        #expect(overview.kind == .ssh)
        #expect(overview.endpointText == "web-01.example.com:2222")
    }

    @Test func anS3SessionsEndpointTextComesFromTheDescriptor() {
        let session = StoredSession(
            name: "backups", kind: .s3,
            s3: StoredS3Config(
                accessKeyID: "AKIAEXAMPLE", region: "eu-central-1",
                endpoint: "https://minio.lan:9000", bucket: "backups",
                usePathStyle: true, startsAtBucketList: false))

        let overview = model(session)

        #expect(overview.kind == .s3)
        #expect(overview.endpointText == "minio.lan:9000")
        #expect(text(overview, "bucket") == "backups")
    }

    @Test func aWebDAVSessionShowsItsBaseURL() {
        let session = StoredSession(
            name: "nextcloud", kind: .webdav,
            webdav: StoredWebDAVConfig(
                baseURL: "https://cloud.example.com/remote.php/dav",
                username: "carol", useNextcloudPath: true))

        let overview = model(session)

        #expect(overview.kind == .webdav)
        #expect(overview.endpointText == "cloud.example.com:443")
        #expect(text(overview, "baseURL") == "https://cloud.example.com/remote.php/dav")
    }

    // MARK: - Facts, per kind

    @Test func anSSHKeySessionNamesItsUserItsAuthenticationAndItsKeyFile() {
        let overview = model(sshSession())

        #expect(text(overview, "username") == "deploy")
        #expect(text(overview, "keyPath") == "/Users/tester/.ssh/id_ed25519")
        let authentication = text(overview, "authentication")
        #expect(authentication?.isEmpty == false)
        // The auth kind is a WORD, so it is looked up rather than spelled
        // here — this pins that the model resolved a real catalogue entry
        // instead of handing back the key, which is what `CoreL10n.string`
        // returns when no catalogue declares it.
        let resolvedToItsOwnKey =
            authentication == SessionOverviewModel.authTextKey(for: .privateKey)
        #expect(resolvedToItsOwnKey == false)
    }

    @Test func aPasswordSessionHasNoKeyPathFact() {
        let overview = model(sshSession(authKind: .password, keyPath: nil))

        #expect(text(overview, "username") == "deploy")
        #expect(text(overview, "keyPath") == nil)
    }

    @Test func aJumpHostIsNamedByHostAndPortAndByNothingElse() {
        let jump = StoredSession.JumpSpec(
            host: "bastion.example.com", port: 2200, username: "hopper",
            authKind: .password)
        let overview = model(sshSession(jump: jump))

        #expect(text(overview, "jump") == "bastion.example.com:2200")
    }

    @Test func aSessionWithNoJumpHasNoJumpFact() {
        #expect(text(model(sshSession()), "jump") == nil)
    }

    @Test func tagsAreOneFactAndOnlyWhenThereAreAny() {
        #expect(text(model(sshSession(tags: [])), "tags") == nil)
        #expect(text(model(sshSession(tags: ["prod", "eu"])), "tags") == "prod, eu")
    }

    @Test func importProvenanceAppearsOnlyForAnImportedSession() {
        var imported = sshSession()
        imported.importSource = "cyberduck"
        imported.importID = "abc"
        imported.importedAt = Date(timeIntervalSince1970: 1_700_000_000)

        #expect(text(model(sshSession()), "importedFrom") == nil)
        let provenance = text(model(imported), "importedFrom")
        #expect(provenance?.contains("cyberduck") == true)
    }

    /// A `.ssh` record with no stored block cannot reach the app (the store
    /// drops it on load), but the model must still answer rather than
    /// fabricate: no SSH facts, and an empty endpoint text.
    @Test func aSessionWithoutItsStoredBlockYieldsNoBackendFacts() {
        let session = StoredSession(name: "broken", kind: .ssh, ssh: nil)
        let overview = model(session)

        #expect(overview.endpointText.isEmpty)
        #expect(text(overview, "username") == nil)
        #expect(text(overview, "authentication") == nil)
    }

    /// Built with every optional fact present, so the uniqueness check
    /// covers the whole vocabulary rather than the subset a bare session
    /// happens to produce.
    @Test func everyFactCarriesAnIdAndALabelKeyAndTheIdsAreUnique() {
        var session = sshSession(
            jump: StoredSession.JumpSpec(
                host: "bastion.example.com", port: 2200, username: "hopper",
                authKind: .password),
            tags: ["prod"])
        session.importSource = "cyberduck"
        session.importedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let overview = model(session, groupName: "Production", loginSetName: "Deploy key")

        #expect(overview.facts.isEmpty == false)
        for fact in overview.facts {
            #expect(fact.id.isEmpty == false)
            #expect(fact.labelKey.hasPrefix("overview.fact."))
            #expect(fact.text.isEmpty == false)
        }
        #expect(Set(overview.facts.map(\.id)).count == overview.facts.count)
    }

    // MARK: - The stored secret

    @Test func aStoredSecretIsReportedAsPresentWithoutItsValue() {
        let session = sshSession(authKind: .password, keyPath: nil)
        let secrets = FakeSecretPresence(slots: [session.secretSlot])

        let overview = model(session, secrets: secrets)

        #expect(overview.hasStoredSecret == true)
        #expect(secrets.asked == [session.secretSlot])
    }

    @Test func anAbsentSecretIsReportedAsAbsent() {
        let session = sshSession(authKind: .password, keyPath: nil)
        let overview = model(session, secrets: FakeSecretPresence(slots: []))

        #expect(overview.hasStoredSecret == false)
    }

    /// Agent authentication needs no secret at all, so the question is not
    /// asked — `nil` is "there is nothing to store here", which is a
    /// different sentence from "nothing is stored".
    @Test func agentAuthenticationIsAskedNothingAndAnswersNil() {
        let session = sshSession(authKind: .agent, keyPath: nil)
        let secrets = FakeSecretPresence(slots: [session.secretSlot])

        let overview = model(session, secrets: secrets)

        #expect(overview.hasStoredSecret == nil)
        #expect(secrets.asked.isEmpty)
    }

    /// A session in a login set does not own its credential — the SET does,
    /// under the set's id. Asking about the session's own id would report
    /// "no secret" for a session that has one.
    @Test func theSlotAskedAboutIsTheLoginSetsWhenOneOwnsTheCredential() {
        let setID = UUID()
        let session = sshSession(authKind: .password, keyPath: nil, loginSetID: setID)
        let secrets = FakeSecretPresence(slots: [setID])

        let overview = model(session, secrets: secrets)

        #expect(overview.hasStoredSecret == true)
        #expect(secrets.asked == [setID])
    }

    // MARK: - Host key

    @Test func aKnownHostKeyIsReportedWithItsTypeAndFingerprint() {
        let key = KnownHostKey(
            host: "web-01.example.com", port: 2222, keyType: "ssh-ed25519",
            publicKeyBase64: Data("a-host-key-blob".utf8).base64EncodedString())

        let overview = model(sshSession(), knownKey: key)

        guard case .known(let type, let fingerprint) = overview.hostKey else {
            Issue.record("expected a known host key, got \(overview.hostKey)")
            return
        }
        #expect(type == "ssh-ed25519")
        #expect(fingerprint == key.fingerprintSHA256)
        #expect(fingerprint.hasPrefix("SHA256:"))
    }

    @Test func anSSHSessionWithNoRememberedKeyIsUnknown() {
        #expect(model(sshSession(), knownKey: nil).hostKey == .unknown)
    }

    @Test func theTwoBackendsWithoutTOFUReportNotApplicable() {
        let s3 = StoredSession(
            name: "backups", kind: .s3,
            s3: StoredS3Config(
                accessKeyID: "AKIAEXAMPLE", region: "eu-central-1",
                endpoint: "https://minio.lan:9000", bucket: "backups",
                usePathStyle: true, startsAtBucketList: false))
        let webdav = StoredSession(
            name: "nextcloud", kind: .webdav,
            webdav: StoredWebDAVConfig(
                baseURL: "https://cloud.example.com/dav", username: "carol",
                useNextcloudPath: false))

        #expect(model(s3).hostKey == .notApplicable)
        #expect(model(webdav).hostKey == .notApplicable)
    }

    // MARK: - History and snippets

    @Test func theHistoryIsDerivedFromTheEventsHandedIn() {
        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        let events = [
            AuditEvent(timestamp: epoch, kind: .connected, detail: "connected to web-01 as deploy"),
            AuditEvent(
                timestamp: epoch.addingTimeInterval(30), kind: .disconnected,
                detail: "disconnected"),
        ]

        let overview = model(sshSession(), events: events)

        #expect(overview.history.count == 1)
        #expect(overview.history[0].outcome == .connected(duration: .seconds(30)))
    }

    @Test func theSnippetsAreTheOnesHandedInUnchanged() {
        let snippets = [
            Snippet(name: "Disk", command: "df -h"),
            Snippet(name: "Log", command: "tail -f /var/log/syslog"),
        ]

        let overview = model(sshSession(), snippets: snippets)

        #expect(overview.snippets == snippets)
    }

    // MARK: - What can never appear

    /// The whole point of the `SecretPresence` seam. The value below is
    /// never handed to the model at all — it is planted in the two places a
    /// secret has historically reached a screen through a stored record:
    /// a URL's userinfo, and a session's own name.
    ///
    /// Every check computes its `Bool` BEFORE the expectation, and the value
    /// itself lives in a named constant: `#expect` reports the SOURCE TEXT
    /// of what it checks, so a secret written into an expectation leaks
    /// through the failure message — the exact thing this test forbids.
    @Test func noRenderedTextEverCarriesASecretPlantedInAStoredURL() {
        let planted = "s3cr3t-passphrase-value"
        let session = StoredSession(
            name: "nextcloud", kind: .webdav,
            webdav: StoredWebDAVConfig(
                baseURL: "https://carol:\(planted)@cloud.example.com/remote.php/dav",
                username: "carol", useNextcloudPath: false))

        let overview = model(session)

        let rendered = overview.facts.map(\.text) + [overview.endpointText, overview.name]
        // The positive companion, without which an empty fact list would
        // satisfy both negatives below: the URL IS rendered, stripped. The
        // host is spelled here; the secret never is.
        let strippedURLIsRendered = rendered.contains {
            $0 == "https://cloud.example.com/remote.php/dav"
        }
        #expect(strippedURLIsRendered)
        let hostIsRendered = rendered.contains { $0.contains("cloud.example.com") }
        #expect(hostIsRendered)

        let anyCarriesIt = rendered.contains { $0.contains(planted) }
        #expect(anyCarriesIt == false)

        let anyEqualsIt = rendered.contains { $0 == planted }
        #expect(anyEqualsIt == false)
    }

    /// The same plant on the S3 side, where the endpoint field takes
    /// `scheme://KEY:SECRET@host` as ordinary input.
    @Test func noRenderedTextEverCarriesASecretPlantedInAnS3Endpoint() {
        let planted = "s3cr3t-access-key-value"
        let session = StoredSession(
            name: "backups", kind: .s3,
            s3: StoredS3Config(
                accessKeyID: "AKIAEXAMPLE", region: "eu-central-1",
                endpoint: "https://AKIAEXAMPLE:\(planted)@minio.lan:9000",
                bucket: "backups", usePathStyle: true, startsAtBucketList: false))

        let overview = model(session)

        let rendered = overview.facts.map(\.text) + [overview.endpointText, overview.name]
        // The positive companion — see the WebDAV plant above.
        let strippedEndpointIsRendered = rendered.contains { $0 == "https://minio.lan:9000" }
        #expect(strippedEndpointIsRendered)
        let hostIsRendered = rendered.contains { $0.contains("minio.lan") }
        #expect(hostIsRendered)

        let anyCarriesIt = rendered.contains { $0.contains(planted) }
        #expect(anyCarriesIt == false)
    }

    // MARK: - Group and login set

    /// Both are NAMES the caller resolves, because `StoredSession` carries
    /// only ids. Absent by default, so a session in no group and no set
    /// grows no rows.
    @Test func aGroupedSessionNamesItsGroup() {
        #expect(text(model(sshSession()), "group") == nil)
        #expect(text(model(sshSession(), groupName: "Production"), "group") == "Production")
    }

    @Test func aSessionInALoginSetNamesTheSet() {
        #expect(text(model(sshSession()), "loginSet") == nil)
        #expect(
            text(model(sshSession(), loginSetName: "Deploy key"), "loginSet") == "Deploy key")
    }

    /// A name the caller could not resolve arrives as an empty string just
    /// as often as it arrives as `nil`; neither may become a labelled blank.
    @Test func anEmptyNameIsNoFactAtAll() {
        let overview = model(sshSession(), groupName: "", loginSetName: "")
        #expect(text(overview, "group") == nil)
        #expect(text(overview, "loginSet") == nil)
    }

    /// The design's order: the login set sits directly after the credential
    /// facts and BEFORE the jump host — a jump is a second login, not part
    /// of this one — and the group sits after both, before the tags.
    @Test func theLoginSetPrecedesTheJumpAndTheGroupPrecedesTheTags() throws {
        let jump = StoredSession.JumpSpec(
            host: "bastion.example.com", port: 2200, username: "hopper", authKind: .password)
        let overview = model(
            sshSession(jump: jump, tags: ["prod"]), groupName: "Production",
            loginSetName: "Deploy key")

        let ids = overview.facts.map(\.id)
        let keyPath = try #require(ids.firstIndex(of: "keyPath"))
        let loginSet = try #require(ids.firstIndex(of: "loginSet"))
        let jumpIndex = try #require(ids.firstIndex(of: "jump"))
        let group = try #require(ids.firstIndex(of: "group"))
        let tags = try #require(ids.firstIndex(of: "tags"))

        #expect(keyPath < loginSet)
        #expect(loginSet < jumpIndex)
        #expect(jumpIndex < group)
        #expect(group < tags)
    }

    /// The two backends with no jump still place the set after their own
    /// credential facts and before the group.
    @Test func theOtherTwoBackendsAlsoNameTheirLoginSet() throws {
        let session = StoredSession(
            name: "backups", kind: .s3,
            s3: StoredS3Config(
                accessKeyID: "AKIAEXAMPLE", region: "eu-central-1",
                endpoint: "https://minio.lan:9000", bucket: "backups",
                usePathStyle: true, startsAtBucketList: false))

        let overview = model(session, groupName: "Production", loginSetName: "Backup key")
        let ids = overview.facts.map(\.id)

        #expect(text(overview, "loginSet") == "Backup key")
        let loginSet = try #require(ids.firstIndex(of: "loginSet"))
        let pathStyle = try #require(ids.firstIndex(of: "pathStyle"))
        let group = try #require(ids.firstIndex(of: "group"))
        #expect(pathStyle < loginSet)
        #expect(loginSet < group)
    }

    // MARK: - Empty data never becomes a labelled blank

    /// An S3 session that names neither a bucket nor the bucket list is an
    /// incomplete record. It gets no bucket row, rather than one whose value
    /// is the empty string.
    @Test func anS3SessionWithNoBucketAndNoBucketListHasNoBucketFact() {
        let session = StoredSession(
            name: "half-configured", kind: .s3,
            s3: StoredS3Config(
                accessKeyID: "AKIAEXAMPLE", region: "eu-central-1",
                endpoint: "https://minio.lan:9000", bucket: "",
                usePathStyle: true, startsAtBucketList: false))

        let overview = model(session)

        #expect(text(overview, "bucket") == nil)
        // The positive companion: the rest of the S3 facts are still there,
        // so this is an omitted row and not an empty model.
        #expect(text(overview, "region") == "eu-central-1")
    }

    @Test func anS3SessionRootedAtTheBucketListSaysSoWithNoBucketName() {
        let session = StoredSession(
            name: "everything", kind: .s3,
            s3: StoredS3Config(
                accessKeyID: "AKIAEXAMPLE", region: "eu-central-1",
                endpoint: "https://minio.lan:9000", bucket: "",
                usePathStyle: true, startsAtBucketList: true))

        let bucket = text(model(session), "bucket")

        #expect(bucket?.isEmpty == false)
        let resolvedToItsOwnKey = bucket == "core.overview.s3.bucketList"
        #expect(resolvedToItsOwnKey == false)
    }
}
