import Foundation
import Testing
@testable import macSCPCore

@Suite("FTP as a connection kind")
struct FTPFieldSchemaTests {
    // A value this suite must not leak: it lives in a named constant and every
    // comparison is computed into a `Bool` first, because `#expect` prints the
    // source text of its expression when it fails.
    private static let secret = "ftp-secret-\(UUID().uuidString)"

    private func config(_ security: FTPSecurityMode) -> FTPConnectionConfig {
        FTPConnectionConfig(
            host: "files.example.com", port: security.defaultPort, username: "tim",
            security: security)
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
    ])
    func aHostIsTrimmedAndAnIPv6LiteralLosesItsBrackets(raw: String, expected: String) {
        #expect(FTPFieldSchema.normalizedHost(raw) == expected)
    }

    @Test(arguments: [
        "", "   ", "files example.com", "ftp://files.example.com", "files.example.com/pub",
        "tim@files.example.com", "files.example.com:21", "[files.example.com]", "[]",
        "files.example.com?x", "files.example.com#x", "a\u{0}b", "a\tb", "2001:db8::g",
    ])
    func aHostThatIsNotAHostIsRefused(raw: String) {
        #expect(FTPFieldSchema.normalizedHost(raw) == nil)
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

    @Test func makeConfigRefusesABadHostAndABadPort() {
        var badHost = filledValues()
        badHost[FTPField.host] = "ftp://files.example.com"
        #expect(throws: (any Error).self) { _ = try FTPFieldSchema.makeConfig(badHost, "") }

        var badPort = filledValues()
        badPort[FTPField.port] = "99999"
        #expect(throws: (any Error).self) { _ = try FTPFieldSchema.makeConfig(badPort, "") }
    }

    // MARK: - Persisted shape

    /// The secret never reaches an encoding. The keys are compared with an
    /// explicit list so a stored property added later without a decision is
    /// seen here rather than written to disk.
    @Test func anEncodedConfigHoldsNoPasswordAndRoundTripsTheRest() throws {
        var original = config(.explicitTLS)
        original.initialPath = "/pub"
        original.password = Self.secret

        let data = try JSONEncoder().encode(original)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["host", "port", "username", "security", "initialPath"])

        let text = String(decoding: data, as: UTF8.self)
        let leaked = text.contains(Self.secret)
        #expect(leaked == false)

        let back = try JSONDecoder().decode(FTPConnectionConfig.self, from: data)
        #expect(back.password.isEmpty)
        var expected = original
        expected.password = ""
        #expect(back == expected)
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
    func theNotAvailableSentenceIsDeclaredInTheCoreCatalogue(locale: String) throws {
        let url = LocalizationCatalogs.repoRoot.appendingPathComponent(
            "Sources/macSCPCore/Resources/\(locale).lproj/Localizable.strings")
        let catalogue = try #require(NSDictionary(contentsOf: url) as? [String: String])
        #expect(catalogue["core.connect.ftpNotAvailableYet"]?.isEmpty == false)
    }
}
