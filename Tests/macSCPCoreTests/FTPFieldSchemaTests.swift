import Foundation
import Testing
@testable import macSCPCore

private struct NoSecrets: SecretPresence {
    func hasSecret(for slot: UUID) -> Bool { false }
}

@Suite("FTP as a connection kind")
struct FTPFieldSchemaTests {
    // A value this suite must not leak: it lives in a named constant and every
    // comparison is computed into a `Bool` first, because `#expect` prints the
    // source text of its expression when it fails.
    private static let secret = "ftp-secret-\(UUID().uuidString)"

    private func config(_ security: FTPSecurityMode) -> FTPConnectionConfig {
        FTPConnectionConfig(
            host: "files.example.com", port: security.defaultPort, username: "tim",
            security: security, password: "")
    }

    private func filledValues() -> FieldValues {
        var values = FieldValues()
        values[FTPField.host] = "files.example.com"
        values[FTPField.port] = "2121"
        values[FTPField.security] = FTPSecurityMode.implicitTLS.rawValue
        values[FTPField.initialPath] = "/pub"
        values[FTPField.username] = "tim"
        return values
    }

    // MARK: - The plaintext gate

    @Test func plainFTPAsksForConfirmationAndNeitherTLSFormDoes() {
        #expect(PlaintextTransportGate.requiresConfirmation(for: .ftp(config(.plain))))
        #expect(PlaintextTransportGate.requiresConfirmation(for: .ftp(config(.explicitTLS))) == false)
        #expect(PlaintextTransportGate.requiresConfirmation(for: .ftp(config(.implicitTLS))) == false)
    }

    /// The capability is one fixed value for all three modes: the gate's
    /// second question is answered by the config, so no per-connection
    /// capability field exists. Pinned beside the gate test because the two
    /// are the same decision.
    @Test func theCapabilityIsOptionalTLSWhateverTheMode() {
        #expect(BackendDescriptor.descriptor(for: .ftp).capabilities.transport == .optionalTLS)
    }

    // MARK: - Security modes

    @Test func theDefaultPortFollowsTheSecurityMode() {
        #expect(FTPSecurityMode.implicitTLS.defaultPort == 990)
        #expect(FTPSecurityMode.explicitTLS.defaultPort == 21)
        #expect(FTPSecurityMode.plain.defaultPort == 21)
    }

    @Test func aBlankPortMeansTheModesDefaultAndNothingElseDoes() {
        for mode in FTPSecurityMode.allCases {
            #expect(FTPFieldSchema.port("", for: mode) == mode.defaultPort)
            #expect(FTPFieldSchema.port("  \n", for: mode) == mode.defaultPort)
            #expect(FTPFieldSchema.port("2121", for: mode) == 2121)
            #expect(FTPFieldSchema.port(" 2121\n", for: mode) == 2121)
        }
    }

    @Test(arguments: ["0", "65536", "-1", "21.5", "abc", "21a", "٢١", "+21"])
    func aPortThatIsNotAPortIsRefusedNotDefaulted(raw: String) {
        // A value that does not parse must NOT fall back to the default:
        // dialling 21 when the user typed something else is the silent
        // wrong-port bug.
        #expect(FTPFieldSchema.port(raw, for: .explicitTLS) == nil)
    }

    @Test func thePortBoundsAreInclusive() {
        #expect(FTPFieldSchema.port("1", for: .plain) == 1)
        #expect(FTPFieldSchema.port("65535", for: .plain) == 65535)
    }

    @Test func theSecurityModesRawValuesAreThePersistedSpelling() {
        #expect(FTPSecurityMode.allCases.map(\.rawValue) == ["plain", "explicitTLS", "implicitTLS"])
    }

    // MARK: - Host

    @Test(arguments: [
        ("files.example.com", "files.example.com"),
        ("  files.example.com\n", "files.example.com"),
        ("192.0.2.7", "192.0.2.7"),
        ("[2001:db8::1]", "2001:db8::1"),
        ("2001:db8::1", "2001:db8::1"),
        ("::1", "::1"),
        ("[::1]", "::1"),
        ("::ffff:192.0.2.7", "::ffff:192.0.2.7"),
    ])
    func aHostIsTrimmedAndAnIPv6LiteralLosesItsBrackets(raw: String, expected: String) {
        #expect(FTPFieldSchema.normalizedHost(raw) == expected)
    }

    /// The last two are UNBALANCED brackets, and they are the only inputs here
    /// that reach the `[` and `]` members of `normalizedHost`'s character
    /// scan: every other bracketed input is a matched outer pair, which the
    /// strip above the scan removes, so the scan never sees a bracket.
    ///
    /// The re-review of 2026-11-05 measured the then-committed inputs GREEN
    /// with both members deleted from the scanned set. With these two added it
    /// is RED, measured in fix round 4 by the command below, which printed
    /// `RESULT: RED — 1 test(s) ran, and the plant was caught by:
    /// macSCPCoreTests.FTPFieldSchemaTests/aHostThatIsNotAHostIsRefused(raw:)`:
    ///
    ///     scripts/mutation-probe --filter 'aHostThatIsNotAHostIsRefused' --apply "perl -pi -e 's{if \"/\?#\[\]\"\.unicodeScalars\.contains\(scalar\) \{ return nil \}}{if \"/?#\".unicodeScalars.contains(scalar) { return nil }}' Sources/macSCPCore/FTP/FTPFieldSchema.swift"
    @Test(arguments: [
        "", "   ", "files example.com", "ftp://files.example.com", "files.example.com/pub",
        "tim@files.example.com", "[files.example.com]", "[]",
        "files.example.com:21", "[files.example.com:21]", "2001:db8::g", "[2001:db8::g]",
        "192.0.2.7:21", "beef:21",
        "files.example.com?x", "files.example.com#x", "a\u{0}b", "a\tb",
        "[files.example.com", "a]b",
    ])
    func aHostThatIsNotAHostIsRefused(raw: String) {
        #expect(FTPFieldSchema.normalizedHost(raw) == nil)
    }

    // MARK: - A host never carries user-info

    /// One shape per refusal. The refusals are the FORM's and the DIAL's:
    /// `FieldFormat.hostWithoutUserinfo` on the host field, and
    /// `normalizedHost` under `makeConfig`. They are not the STORE's --
    /// `FTPFieldSchema.stored(from:)` only trims -- so this test is not
    /// evidence that a render site can print a stored host as it is.
    /// `displaySummary`'s fallback filters (fix round 4), which covers the
    /// sidebar row and its search; `SessionCatalog.target(for:)` and the FTP
    /// overview's host fact still print a stored host as stored, and that is
    /// the `docs/BACKLOG.md` row beginning "A stored host can carry user-info
    /// on SSH and FTP".
    ///
    /// (Withdrawn wording, verbatim: "A host that held `tim:secret@host`
    /// would be stored and then printed raw by the sidebar row and the
    /// overview's host fact, neither of which filters it; the schema refuses
    /// it so that neither has to." Both halves are wrong. The sidebar row IS
    /// filtered, since fix round 4 put `displaySummary`'s fallback through
    /// `URLText.withoutUserinfo`. And the store path is still open, so the
    /// schema's refusal does not mean no render site has to filter.)
    @Test(arguments: [
        "tim@files.example.com", "tim:secret@files.example.com", "@files.example.com",
        "files.example.com@", "ftp://files.example.com", "ftps://tim:secret@files.example.com/",
        "  tim@files.example.com  ",
    ])
    func aHostWithUserinfoOrASchemeIsRefusedEverywhere(raw: String) throws {
        #expect(FTPFieldSchema.hostCarriesUserinfo(raw))
        #expect(FTPFieldSchema.normalizedHost(raw) == nil)

        // The form's own validation, so a save is refused before anything is
        // stored -- with the sentence that names this problem, not the
        // blank-host one.
        var values = filledValues()
        values[FTPField.host] = raw
        let violation = try #require(
            BackendDescriptor.descriptor(for: .ftp).firstViolation(
                in: values, requireSecrets: false))
        #expect(violation.messageKey == "core.connect.ftpHostInvalid")
        #expect(violation.fieldKey == "\(FTPField.namespace).\(FTPField.host.rawValue)")
    }

    /// The positive beside the refusals above: an ordinary host, an address
    /// and a bracketed IPv6 literal all pass both the parse and the form.
    @Test(arguments: ["files.example.com", "ftp-1.example.com", "192.0.2.7", "[2001:db8::1]"])
    func anOrdinaryHostPassesBothTheParseAndTheForm(raw: String) {
        #expect(FTPFieldSchema.hostCarriesUserinfo(raw) == false)
        #expect(FTPFieldSchema.normalizedHost(raw) != nil)
        var values = filledValues()
        values[FTPField.host] = raw
        #expect(BackendDescriptor.descriptor(for: .ftp).firstViolation(
            in: values, requireSecrets: false) == nil)
    }

    /// The colon rule, both sides together, as `normalizedHost` answers it:
    /// one colon is a port in the wrong field and is refused, two or more are
    /// an IPv6 literal and pass. The refusals and the positives sit in one
    /// test so neither half can be satisfied by deleting the other.
    ///
    /// (Corrected in fix round 4. This paragraph read, verbatim: "one colon is
    /// a port in the wrong field and is refused (by `makeConfig`, with the
    /// host sentence)". Nothing in this body calls `makeConfig`; that half is
    /// `makeConfigRefusesEachBadFieldWithItsOwnSentence`, which pins
    /// `files.example.com:21` to `core.connect.ftpHostInvalid`.)
    @Test func oneColonIsAPortInTheWrongFieldAndSeveralAreIPv6() {
        #expect(FTPFieldSchema.normalizedHost("files.example.com:21") == nil)
        // Hex digits, dots and ONE colon: the content check alone would pass
        // these, so only the colon count refuses them. The address-and-port
        // is the commonest way to get this wrong.
        #expect(FTPFieldSchema.normalizedHost("192.0.2.7:21") == nil)
        #expect(FTPFieldSchema.normalizedHost("beef:21") == nil)
        #expect(FTPFieldSchema.normalizedHost("[::1]") == "::1")
        #expect(FTPFieldSchema.normalizedHost("::1") == "::1")
        #expect(FTPFieldSchema.normalizedHost("files.example.com") == "files.example.com")
    }

    // MARK: - Registration

    @Test func schemaCoversEveryDeclaredField() {
        #expect(SchemaConformance.check(
            BackendDescriptor.descriptor(for: .ftp), fields: FTPField.self).isEmpty)
    }

    @Test func credentialSchemaCarriesOnlyTheLoginFields() {
        let ids = Set(BackendDescriptor.descriptor(for: .ftp).credentialSchema.fields.map(\.id))
        #expect(ids == [FTPField.username.rawValue, FTPField.password.rawValue])
    }

    @Test func theCapabilityRowIsTheSpecsRowForFTP() {
        let capabilities = BackendDescriptor.descriptor(for: .ftp).capabilities
        #expect(capabilities == ProtocolCapabilities(
            supportsShell: false, permissionModel: .posixMode, supportsSymlinks: true,
            atomicRename: false, directoriesAreReal: true, resumeMode: .restOffset,
            supportsPresignedURL: false, supportsRemoteChecksum: false,
            transport: .optionalTLS, authenticatesHostKey: false))
    }

    @Test func aFreshFormStartsOnExplicitFTPSWithItsPort() {
        let defaults = BackendDescriptor.descriptor(for: .ftp).defaultValues
        #expect(defaults[FTPField.security] == FTPSecurityMode.explicitTLS.rawValue)
        #expect(defaults[FTPField.port] == "21")
        #expect(FTPFieldSchema.security(FieldValues()) == .explicitTLS)
    }

    @Test func theSecurityPickerOffersExactlyTheThreeModes() throws {
        let field = try #require(
            FTPFieldSchema.connection.fields.first { $0.id == FTPField.security.rawValue })
        guard case .picker(.fixed(let options)) = field.kind else {
            Issue.record("expected a fixed picker")
            return
        }
        #expect(options.map(\.id) == FTPSecurityMode.allCases.map(\.rawValue))
    }

    // MARK: - makeConfig

    @Test func makeConfigBuildsAnFTPConfigWithTheSecretAttached() throws {
        let built = try FTPFieldSchema.makeConfig(filledValues(), Self.secret)
        guard case .ftp(let ftp) = built else {
            Issue.record("expected .ftp")
            return
        }
        #expect(ftp.host == "files.example.com")
        #expect(ftp.port == 2121)
        #expect(ftp.username == "tim")
        #expect(ftp.security == .implicitTLS)
        #expect(ftp.initialPath == "/pub")
        let carriesSecret = ftp.password == Self.secret
        #expect(carriesSecret)
        #expect(built.kind == .ftp)
    }

    @Test func aBlankPortFollowsTheModeAndABlankPathIsNil() throws {
        var values = filledValues()
        values[FTPField.port] = ""
        values[FTPField.initialPath] = "  "
        let built = try FTPFieldSchema.makeConfig(values, "")
        guard case .ftp(let ftp) = built else {
            Issue.record("expected .ftp")
            return
        }
        #expect(ftp.port == 990)
        #expect(ftp.initialPath == nil)
    }

    /// The `reason` of the `.connectionFailed` a refused form throws, or nil
    /// when `makeConfig` did not throw one.
    private func refusalReason(_ values: FieldValues) -> String? {
        do {
            _ = try FTPFieldSchema.makeConfig(values, "")
            return nil
        } catch RemoteFSError.connectionFailed(let reason) {
            return reason
        } catch {
            return nil
        }
    }

    /// Each refusal is pinned to the sentence that names ITS problem: a blank
    /// host, a host that is more than a name or an address (user-info, a
    /// scheme, a port, whitespace), and a port that is not one.
    /// `(any Error).self` accepted any of them for any reason, which is how a
    /// credential-shaped host once got the blank-host sentence.
    @Test func makeConfigRefusesEachBadFieldWithItsOwnSentence() {
        func reason(host: String? = nil, port: String? = nil) -> String? {
            var values = filledValues()
            if let host { values[FTPField.host] = host }
            if let port { values[FTPField.port] = port }
            return refusalReason(values)
        }
        #expect(reason(host: "  ") == CoreL10n.string("core.connect.emptyHost"))
        #expect(reason(host: "tim@files.example.com") == CoreL10n.string("core.connect.ftpHostInvalid"))
        #expect(reason(host: "ftp://files.example.com") == CoreL10n.string("core.connect.ftpHostInvalid"))
        #expect(reason(host: "files example.com") == CoreL10n.string("core.connect.ftpHostInvalid"))
        #expect(reason(host: "files.example.com:21") == CoreL10n.string("core.connect.ftpHostInvalid"))
        #expect(reason(port: "99999") == CoreL10n.string("core.connect.portNumeric"))

        // Positive: the sentences are different, resolved texts, so the
        // equalities above cannot all hold by every key being unresolved.
        let keys = ["core.connect.emptyHost", "core.connect.ftpHostInvalid",
                    "core.connect.portNumeric"]
        #expect(Set(keys.map { CoreL10n.string($0) }).count == keys.count)
        #expect(keys.allSatisfy { CoreL10n.string($0) != $0 })
    }

    /// A BLANK host answers with TWO different sentences, on purpose: the form
    /// shows the host sentence, `makeConfig` shows the empty-host one.
    ///
    /// The host field carries one `invalidMessageKey` for blank-and-unparsable
    /// alike (`firstViolation` returns it for a blank required field too), and
    /// `core.connect.ftpHostInvalid` names what to type, so it serves the
    /// blank field as well -- the identical shape S3's endpoint field has, for
    /// the identical stated reason. `makeConfig` is the stricter reader and
    /// keeps `core.connect.emptyHost`, because nothing typed is its own
    /// complaint.
    ///
    /// Pinned so the divergence is a decision on the record rather than a
    /// surprise for whoever next touches either path. Measured sensitive in
    /// fix round 4 by the command below -- setting the field's key back to
    /// what it was before this task -- which printed `RESULT: RED — 1 test(s)
    /// ran, and the plant was caught by:` this test:
    ///
    ///     scripts/mutation-probe --filter 'aBlankHostShowsTheHostSentenceInTheFormAndTheEmptyOneAtTheConfig' --apply "perl -pi -e 's{invalidMessageKey: \"core.connect.ftpHostInvalid\",\$}{invalidMessageKey: \"core.connect.emptyHost\",}' Sources/macSCPCore/FTP/FTPFieldSchema.swift"
    @Test func aBlankHostShowsTheHostSentenceInTheFormAndTheEmptyOneAtTheConfig() throws {
        var values = filledValues()
        values[FTPField.host] = "   "
        let violation = try #require(
            BackendDescriptor.descriptor(for: .ftp).firstViolation(
                in: values, requireSecrets: false))
        #expect(violation.fieldKey == "\(FTPField.namespace).\(FTPField.host.rawValue)")

        // Asserted as the resolved SENTENCES, not as the keys: that is what a
        // user is shown, and it is what tells the two paths apart.
        let formSentence = CoreL10n.string(violation.messageKey)
        #expect(formSentence == CoreL10n.string("core.connect.ftpHostInvalid"))
        #expect(refusalReason(values) == CoreL10n.string("core.connect.emptyHost"))

        // The positives: both sentences are resolved (a key no catalogue
        // declares comes back as itself), and they are genuinely different, so
        // neither equality above can hold by both texts being the same string.
        #expect(formSentence != violation.messageKey)
        let diverge = CoreL10n.string("core.connect.ftpHostInvalid")
            != CoreL10n.string("core.connect.emptyHost")
        #expect(diverge)
    }

    // MARK: - Persisted shape

    /// The persisted block has exactly these keys, so a sixth field is a
    /// decision somebody makes here on purpose. The secret cannot be among
    /// them for a structural reason: `StoredFTPConfig` has no such property,
    /// and the runtime `FTPConnectionConfig`, which has, is not `Codable`
    /// (nothing here can encode it -- it would not compile).
    @Test func theStoredBlockHasExactlyTheDeclaredKeysAndRoundTrips() throws {
        let original = StoredFTPConfig(
            host: "files.example.com", port: 990, username: "tim",
            security: .implicitTLS, initialPath: "/pub")
        let data = try JSONEncoder().encode(original)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["host", "port", "username", "security", "initialPath"])
        #expect(try JSONDecoder().decode(StoredFTPConfig.self, from: data) == original)
    }

    /// The whole session file, not just the block: the password a form
    /// resolved never reaches `StoredSession`, because `makeConfig`'s secret
    /// lands only in the runtime config.
    @Test func aSavedSessionCarriesNoPasswordOnDisk() throws {
        var session = StoredSession(name: "files", kind: .ftp)
        // The secret IS on the path into `apply`: the form's password field
        // holds it. Without this line the test could not fail, whatever
        // `apply` did.
        var values = filledValues()
        values[FTPField.password] = Self.secret
        BackendDescriptor.descriptor(for: .ftp).apply(values, &session)

        let text = String(decoding: try JSONEncoder().encode(session), as: UTF8.self)
        let leaked = text.contains(Self.secret)
        #expect(leaked == false)
        #expect(session.ftp != nil)
    }

    // MARK: - The stored block

    @Test func applyWritesTheBlockAndLeavesTheRestOfTheSessionAlone() {
        let group = UUID(), set = UUID()
        var session = ftpSession(name: "files", groupID: group, loginSetID: set)
        session.tags = ["a"]
        BackendDescriptor.descriptor(for: .ftp).apply(filledValues(), &session)
        #expect(session.ftp == StoredFTPConfig(
            host: "files.example.com", port: 2121, username: "tim",
            security: .implicitTLS, initialPath: "/pub"))
        #expect(session.groupID == group)
        #expect(session.loginSetID == set)
        #expect(session.tags == ["a"])
    }

    @Test func aBlankPortStoresTheModesDefaultAndABlankFolderStoresNil() {
        var values = filledValues()
        values[FTPField.port] = " "
        values[FTPField.initialPath] = ""
        let stored = FTPFieldSchema.stored(from: values)
        #expect(stored.port == 990)
        #expect(stored.initialPath == nil)
    }

    /// A session of `kind` with its block populated. No `default`: a fifth
    /// kind does not compile here until it has a fixture.
    private func session(of kind: ConnectionKind) -> StoredSession {
        switch kind {
        case .ssh: return sshSession(name: "files")
        case .s3: return s3Session(name: "files")
        case .webdav: return webdavSession(name: "files")
        case .ftp:
            return ftpSession(
                name: "files",
                config: StoredFTPConfig(
                    host: "files.example.com", port: 2121, username: "tim",
                    security: .plain, initialPath: "/pub"))
        }
    }

    /// Store encode/decode and `SessionDuplication.copy`, for every kind.
    /// (A no-op `apply` is caught by `BackendApplyTests
    /// .applyIsTheInverseOfSessionValues`, which is total over kinds; this
    /// test's scope is the store and the copy.)
    @Test(arguments: ConnectionKind.allCases)
    func aStoredSessionRoundTripsThroughTheStoreAndDuplication(kind: ConnectionKind) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ftp-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let session = session(of: kind)
        let store = SessionStore(directory: directory)
        try store.upsert(session)
        let loaded = try #require(try store.all().first)
        #expect(loaded == session)

        let copy = SessionDuplication.copy(of: session, avoiding: [session])
        #expect(copy.kind == kind)
        #expect(copy.ssh == session.ssh)
        #expect(copy.s3 == session.s3)
        #expect(copy.webdav == session.webdav)
        #expect(copy.ftp == session.ftp)
    }

    @Test func aSessionFileWithoutAnFTPKeyStillDecodes() throws {
        let json = #"{"id":"\#(UUID().uuidString)","name":"old","kind":"webdav"}"#
        let decoded = try JSONDecoder().decode(StoredSession.self, from: Data(json.utf8))
        #expect(decoded.ftp == nil)
    }

    @Test func theCatalogDescribesTheTargetAsUserAtHostAndPort() {
        let catalog = SessionCatalog(
            sessions: [ftpSession(
                name: "files",
                config: StoredFTPConfig(
                    host: "files.example.com", port: 2121, username: "tim", security: .plain))],
            groups: [])
        #expect(catalog.rows(matching: .init()).map(\.target) == ["tim@files.example.com:2121"])
    }

    @Test func theOverviewShowsAddressSecurityAndUserButNoPassword() {
        let session = ftpSession(
            name: "files",
            config: StoredFTPConfig(
                host: "files.example.com", port: 990, username: "tim",
                security: .implicitTLS, initialPath: "/pub"))
        let descriptor = BackendDescriptor.descriptor(for: .ftp)
        let model = SessionOverviewModel(
            session: session, descriptor: descriptor, knownKey: nil,
            secrets: NoSecrets(), events: [], snippets: [])
        let ids = model.facts.map(\.id)
        #expect(ids.contains("host") && ids.contains("port") && ids.contains("security"))
        #expect(ids.contains("username") && ids.contains("initialPath"))
        #expect(model.hostKey == .notApplicable)
        let namesAPassword = ids.contains { $0.lowercased().contains("password") }
        #expect(namesAPassword == false)
    }

    // MARK: - Summary, endpoint, login set

    @Test func theSummaryNamesUserAndHostAndShowsAnUnusualPort() {
        var values = filledValues()
        values[FTPField.security] = FTPSecurityMode.explicitTLS.rawValue
        values[FTPField.port] = "21"
        #expect(FTPFieldSchema.displaySummary(values) == "tim @ files.example.com")
        values[FTPField.port] = "2121"
        #expect(FTPFieldSchema.displaySummary(values) == "tim @ files.example.com:2121")
    }

    /// The summary's parse-failure fallback prints no credential.
    ///
    /// This is the one site that asks the validator, is told the string is not
    /// a host, and renders it anyway. It is reached without a form:
    /// `SessionImportPlanner.displaySummary(for:)` builds it from a FILE's raw
    /// fields, and from there it goes to the sidebar row, the sidebar's
    /// search, the audit summary and the stored tab's title.
    ///
    /// The secret lives in a named constant and the comparison is computed
    /// into a `Bool` before the expectation, because `#expect` prints the
    /// SOURCE TEXT of the expression it checks: an expectation written over
    /// the value would leak it in the very failure message saying it leaked.
    @Test func theSummaryDoesNotPrintAUserinfoSecretItRefusedToParse() {
        var values = filledValues()
        values[FTPField.host] = "  tim:\(Self.secret)@files.example.com  "
        let summary = FTPFieldSchema.displaySummary(values)
        let leaked = summary.contains(Self.secret)
        #expect(leaked == false)
        // The positive beside it: a fallback that returned "" would not leak
        // either, and would be useless. The host survives, trimmed, and so
        // does the rest of the summary's shape. Computed into a `Bool` for the
        // same reason as above -- `summary` IS the carrier here, and an
        // expectation over it printed the secret when this test was first run
        // red.
        let isTheExpectedShape = summary == "tim @ files.example.com:2121"
        #expect(isTheExpectedShape)
    }

    @Test func theEndpointIsTheHostAndPortAndNilForNoHost() {
        #expect(FTPFieldSchema.endpoint(filledValues()) == Endpoint(host: "files.example.com", port: 2121))
        var blank = filledValues()
        blank[FTPField.host] = " "
        #expect(FTPFieldSchema.endpoint(blank) == nil)
    }

    @Test func aBareEndpointRoundTripsThroughTheDescriptor() {
        let descriptor = BackendDescriptor.descriptor(for: .ftp)
        let withPort = descriptor.endpointValues(host: "files.example.com", port: 2121)
        #expect(descriptor.endpoint(withPort) == Endpoint(host: "files.example.com", port: 2121))
        // No port given: the mode's own default, explicit FTPS' 21.
        let withoutPort = descriptor.endpointValues(host: "files.example.com", port: nil)
        #expect(descriptor.endpoint(withoutPort) == Endpoint(host: "files.example.com", port: 21))
    }

    @Test func aLoginSetRoundTripsItsUserNameAndIsOfKindFTP() {
        let descriptor = BackendDescriptor.descriptor(for: .ftp)
        var values = FieldValues()
        values[FTPField.username] = "  tim "
        let set = descriptor.loginSet(id: UUID(), name: "files", from: values)
        #expect(set.kind == .ftp)
        #expect(set.username == "tim")
        #expect(descriptor.loginSetValues(set)[FTPField.username] == "tim")
    }

    // MARK: - Until the file system exists

    /// Connecting says something true and does not trap. The sentence is
    /// looked up, so a key no catalogue declares would come back as the key
    /// itself; that is the second expectation.
    @Test func connectingRefusesWithALocalizedSentenceUntilTheFileSystemExists() async {
        let key = "core.connect.ftpNotAvailableYet"
        do {
            _ = try await BackendDescriptor.openConnection(
                .ftp(config(.explicitTLS)), hostKey: .refusing, certificate: .refusing,
                timeoutSeconds: 1)
            Issue.record("expected a refusal")
        } catch let error as RemoteFSError {
            guard case .connectionFailed(let reason) = error else {
                Issue.record("expected .connectionFailed")
                return
            }
            #expect(reason == CoreL10n.string(key))
            #expect(reason != key)
        } catch {
            Issue.record("expected a RemoteFSError")
        }
    }

    // MARK: - Localization

    /// Every key the FTP descriptor names in the App's catalogue exists in all
    /// four languages. `LocalizationParityTests` holds the key SETS equal; this
    /// holds the FTP keys PRESENT, which parity cannot do for a key that is
    /// missing from every language at once.
    @Test(arguments: ["en", "de", "fr", "pl"])
    func everyFTPLabelKeyIsDeclaredInTheAppCatalogue(locale: String) throws {
        let descriptor = BackendDescriptor.descriptor(for: .ftp)
        var keys = [descriptor.badgeLabelKey]
        for field in descriptor.connectionSchema.fields + descriptor.credentialSchema.fields {
            keys.append(field.labelKey)
            if case .picker(.fixed(let options)) = field.kind {
                keys += options.map(\.labelKey)
            }
        }
        #expect(keys.count >= 8)  // the positive companion: the walk found keys at all

        let url = LocalizationCatalogs.repoRoot.appendingPathComponent(
            "Sources/MacSCPAppKit/Resources/\(locale).lproj/Localizable.strings")
        let catalogue = try #require(NSDictionary(contentsOf: url) as? [String: String])
        let missing = keys.filter { catalogue[$0] == nil }
        #expect(missing.isEmpty, Comment(rawValue: "missing from \(locale): \(missing)"))
    }

    @Test(arguments: ["en", "de", "fr", "pl"])
    func theFTPSentencesAreDeclaredInTheCoreCatalogue(locale: String) throws {
        let url = LocalizationCatalogs.repoRoot.appendingPathComponent(
            "Sources/macSCPCore/Resources/\(locale).lproj/Localizable.strings")
        let catalogue = try #require(NSDictionary(contentsOf: url) as? [String: String])
        for key in ["core.connect.ftpNotAvailableYet", "core.connect.ftpHostInvalid"] {
            #expect(catalogue[key]?.isEmpty == false, Comment(rawValue: "\(key) missing from \(locale)"))
        }
    }
}
