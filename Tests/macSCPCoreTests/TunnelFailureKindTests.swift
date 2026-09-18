import Foundation
import Testing

@testable import macSCPCore

/// `DialSupport.failureKind(for:)` and `DialSupport.reason(for:)` read one
/// switch: the kind the forwarding STATE carries, and the English sentence
/// the diagnostic LOG keeps.
///
/// The sentences below are literals on purpose. Every one of them, except
/// the Keychain's and the two local-bind causes', is the text `reason(for:)`
/// produced before the kind existed (BASE `9167f325`), so a row that goes
/// red here is log-text churn — which this change was not allowed to cause.
@Suite struct TunnelFailureKindTests {
    struct Row: CustomTestStringConvertible, Sendable {
        let label: String
        let error: any Error & Sendable
        let kind: TunnelFailureKind
        let sentence: String
        var testDescription: String { label }
    }

    static let rows: [Row] = [
        Row(
            label: "host key mismatch",
            error: HostKeyError.mismatch(
                host: "server.test", expected: "SHA256:expected", presented: "SHA256:presented"),
            kind: .hostKeyMismatch(host: "server.test"),
            sentence:
                "host key MISMATCH for server.test: the presented key differs from the recorded one"),
        Row(
            label: "host key not accepted", error: HostKeyError.rejectedByUser,
            kind: .hostKeyNotAccepted,
            sentence: "the host key is not known to this app and was not accepted"),
        Row(
            label: "authentication", error: RemoteFSError.authenticationFailed,
            kind: .authenticationFailed, sentence: "authentication failed"),
        Row(
            label: "jump authentication", error: RemoteFSError.jumpAuthenticationFailed,
            kind: .authenticationFailed, sentence: "authentication at the jump host failed"),
        Row(
            label: "key file missing", error: SSHKeyError.fileNotFound(path: "/keys/id_test"),
            kind: .keyFileNotFound(path: "/keys/id_test"), sentence: "no key file at /keys/id_test"),
        Row(
            label: "passphrase required", error: SSHKeyError.passphraseRequired,
            kind: .keyPassphraseRequired,
            sentence: "the key is encrypted and no passphrase was available"),
        Row(
            label: "passphrase wrong", error: SSHKeyError.wrongPassphrase,
            kind: .keyPassphraseRejected, sentence: "the key's passphrase was rejected"),
        Row(
            label: "key unparsable", error: SSHKeyError.unsupportedFormat(reason: "dropped"),
            kind: .keyUnparsable, sentence: "the key file could not be parsed"),
        Row(
            label: "key type", error: SSHKeyError.typeNotLoadable(algorithm: "ssh-dss"),
            kind: .keyTypeNotLoadable(algorithm: "ssh-dss"),
            sentence: "this app cannot load a key of type ssh-dss"),
        Row(
            label: "PEM", error: SSHKeyError.pemNotReadable(.cipher("dropped")),
            kind: .keyPEMNotReadable,
            sentence: "the key is a PEM file with a feature this app does not read"),
        Row(
            label: "agent socket", error: AgentError.socketUnavailable, kind: .agentUnavailable,
            sentence: "no ssh-agent answered on SSH_AUTH_SOCK"),
        Row(
            label: "agent empty", error: AgentError.noIdentities, kind: .agentHasNoIdentities,
            sentence: "the ssh-agent holds no identities"),
        Row(
            label: "agent unusable", error: AgentError.noUsableIdentities,
            kind: .agentHasNoUsableIdentity,
            sentence: "the ssh-agent holds no identity of a type this app can offer"),
        Row(
            label: "agent refused", error: AgentError.refused, kind: .agentRefusedEveryIdentity,
            sentence: "the ssh-agent refused every identity it offered"),
        Row(
            label: "agent protocol", error: AgentError.protocolError(reason: "dropped"),
            kind: .agentMisbehaved, sentence: "the ssh-agent connection misbehaved"),
        // The one NEW sentence: this was "The operation couldn’t be completed.
        // (macSCPCore.KeychainError error 1.)" (BACKLOG, 2026-09-16).
        Row(
            label: "keychain", error: KeychainError(status: -25293), kind: .keychainUnreadable,
            sentence: "the keychain could not be read"),
        Row(
            label: "connection", error: RemoteFSError.connectionFailed(reason: "dropped"),
            kind: .connectionFailed, sentence: "the connection failed"),
        Row(
            label: "server answer", error: RemoteFSError.protocolError(reason: "dropped"),
            kind: .serverAnswerUnusable,
            sentence: "the server answered something this app could not use"),
        Row(
            label: "login set", error: TunnelRefusal.loginSet(session: "prod"),
            kind: .sessionUsesLoginSet(session: "prod"),
            sentence: "session prod belongs to a login set; forwardings dial with the session's own login"),
        Row(
            label: "jump host", error: TunnelRefusal.jumpHost(session: "behind"),
            kind: .sessionUsesJumpHost(session: "behind"),
            sentence: "session behind uses a jump host; forwardings cannot dial through one"),
        Row(
            label: "S3", error: TunnelRefusal.notSSH(session: "objects", connectionKind: .s3),
            kind: .sessionIsNotSSH(session: "objects", connectionKind: .s3),
            sentence: "session objects is an S3 session; forwardings need SSH"),
        Row(
            label: "WebDAV", error: TunnelRefusal.notSSH(session: "cloud", connectionKind: .webdav),
            kind: .sessionIsNotSSH(session: "cloud", connectionKind: .webdav),
            sentence: "session cloud is a WebDAV session; forwardings need SSH"),
        Row(
            label: "session missing", error: TunnelRefusal.sessionMissing, kind: .sessionMissing,
            sentence: "the connection this forwarding belongs to no longer exists"),
        Row(
            label: "port in use", error: TunnelFailure.portInUse(port: 8080),
            kind: .portInUse(port: 8080), sentence: "port 8080 is already in use"),
        // NEW sentences (2026-09-18): both were "The operation couldn’t be
        // completed. (NIOCore.IOError error 1.)" as `bindFailed` before.
        Row(
            label: "bind address unavailable",
            error: TunnelFailure.bindAddressUnavailable(address: "192.0.2.1"),
            kind: .bindAddressUnavailable(address: "192.0.2.1"),
            sentence:
                "the bind address 192.0.2.1 is not an address of this machine (EADDRNOTAVAIL)"),
        Row(
            label: "bind permission denied", error: TunnelFailure.bindPermissionDenied(port: 80),
            kind: .bindPermissionDenied(port: 80),
            sentence: "binding port 80 was not permitted (EACCES)"),
        // The four free-text `TunnelFailure` cases: the kind drops the
        // payload, the log keeps it verbatim.
        Row(
            label: "bind", error: TunnelFailure.bindFailed(reason: "payload one"),
            kind: .bindFailed, sentence: "payload one"),
        Row(
            label: "channel", error: TunnelFailure.channelOpenFailed(reason: "payload two"),
            kind: .channelOpenFailed, sentence: "payload two"),
        Row(
            label: "connect", error: TunnelFailure.connectFailed(reason: "payload three"),
            kind: .connectFailed, sentence: "payload three"),
        Row(
            label: "pump", error: TunnelFailure.pumpFailed(reason: "payload four"),
            kind: .pumpFailed, sentence: "payload four"),
        Row(
            label: "already started", error: TunnelFailure.alreadyStarted, kind: .alreadyStarted,
            sentence: "this forward has already been started"),
        // The three remote-forward start failures that were `bindFailed`
        // with a fixed sentence until fix round 1: the log text is what the
        // throw sites wrote at `ab4a2c4c`.
        Row(
            label: "remote port zero", error: TunnelFailure.remotePortZeroRefused,
            kind: .remotePortZeroRefused,
            sentence:
                "a remote forward must name the port the server listens on; "
                + "letting the server choose it is not supported by this client"),
        Row(
            label: "remote bind, non-loopback",
            error: TunnelFailure.remoteBindRefused(
                reason: "server text", needsGatewayPorts: true),
            kind: .remoteBindRefused(needsGatewayPorts: true),
            sentence:
                "server text (a bind address other than loopback needs the server's GatewayPorts)"),
        Row(
            label: "remote bind, loopback",
            error: TunnelFailure.remoteBindRefused(reason: "server text", needsGatewayPorts: false),
            kind: .remoteBindRefused(needsGatewayPorts: false), sentence: "server text"),
        Row(
            label: "remote unanswered", error: TunnelFailure.remoteForwardUnanswered,
            kind: .remoteForwardUnanswered,
            sentence: "the server did not answer the forwarding request"),
        // Errors a forwarding's dial does not produce keep their sentence and
        // are `unknown` as a kind.
        Row(
            label: "not found", error: RemoteFSError.notFound(path: "/srv/x"), kind: .unknown,
            sentence: "nothing at /srv/x"),
        Row(
            label: "bucket list", error: RemoteFSError.bucketListEmpty, kind: .unknown,
            sentence: "the account has no buckets"),
    ]

    @Test(arguments: rows)
    func theErrorMapsToItsKindAndKeepsItsSentence(_ row: Row) {
        #expect(DialSupport.failureKind(for: row.error) == row.kind)
        #expect(DialSupport.reason(for: row.error) == row.sentence)
    }

    /// A foreign error is `unknown`, and its log text is still what it was.
    @Test func aForeignErrorIsUnknownAndKeepsItsDescription() {
        let error = NSError(domain: "test.domain", code: 7)
        #expect(DialSupport.failureKind(for: error) == .unknown)
        #expect(DialSupport.reason(for: error) == error.localizedDescription)
    }

    /// Where a kind's payload is everything its sentence needs, the log's
    /// sentence IS the kind's — one spelling, read from the kind.
    @Test(arguments: rows)
    func aKindThatCarriesItsWholeSentenceIsTheLogSentence(_ row: Row) {
        let freeText: Set<TunnelFailureKind.Name> = [
            .bindFailed, .channelOpenFailed, .connectFailed, .pumpFailed, .unknown,
            .remoteBindRefused,
        ]
        guard !freeText.contains(row.kind.name), row.label != "jump authentication" else { return }
        #expect(row.kind.sentence == row.sentence)
    }

    /// Every kind renders a sentence, and `name` round-trips — reached
    /// through `Name.allCases`, so a new kind is covered without an edit
    /// here beyond the compiler's demand in `TunnelFailureKindSamples`.
    @Test(arguments: TunnelFailureKind.Name.allCases)
    func everyKindHasANameAndAnEnglishSentence(_ name: TunnelFailureKind.Name) {
        let kind = TunnelFailureKindSamples.sample(name)
        #expect(kind.name == name)
        #expect(!kind.sentence.isEmpty)
    }

    /// Every row's kind is a different name, and together they reach every
    /// name but `connectionLost` — the plan's own, which no error produces.
    @Test func theRowsReachEveryKindAnErrorCanProduce() {
        let reached = Set(Self.rows.map(\.kind.name)).union([.connectionLost])
        #expect(reached == Set(TunnelFailureKind.Name.allCases))
    }

    /// The per-connection initialiser Task 7 reads is the same mapping.
    @Test func aTunnelFailureMapsThroughTheSameSwitch() {
        let failures: [TunnelFailure] = [
            .portInUse(port: 1), .bindAddressUnavailable(address: "192.0.2.1"),
            .bindPermissionDenied(port: 80), .bindFailed(reason: "a"), .channelOpenFailed(reason: "b"),
            .connectFailed(reason: "c"), .pumpFailed(reason: "d"), .alreadyStarted,
            .remotePortZeroRefused, .remoteBindRefused(reason: "e", needsGatewayPorts: true),
            .remoteForwardUnanswered,
        ]
        for failure in failures {
            #expect(TunnelFailureKind(failure) == DialSupport.failureKind(for: failure))
        }
        #expect(TunnelFailureKind(.portInUse(port: 1)) == .portInUse(port: 1))
        #expect(
            TunnelFailureKind(.remoteBindRefused(reason: "e", needsGatewayPorts: true))
                == .remoteBindRefused(needsGatewayPorts: true))
    }

    /// Decision (d) holds on the kind too: the mismatch carries the host
    /// and nothing that was compared.
    @Test func theMismatchKindCarriesNoFingerprint() {
        let expected = "SHA256:expected-fingerprint"
        let presented = "SHA256:presented-fingerprint"
        let kind = DialSupport.failureKind(
            for: HostKeyError.mismatch(host: "server.test", expected: expected, presented: presented))
        let rendered = "\(kind) \(kind.sentence)"
        let leaks = rendered.contains(expected) || rendered.contains(presented)
        #expect(leaks == false)
    }
}

/// One value per `TunnelFailureKind.Name`, by an exhaustive switch: a name
/// added to the enum does not compile here until it has a sample.
enum TunnelFailureKindSamples {
    static func sample(_ name: TunnelFailureKind.Name) -> TunnelFailureKind {
        switch name {
        case .hostKeyMismatch: return .hostKeyMismatch(host: "server.test")
        case .hostKeyNotAccepted: return .hostKeyNotAccepted
        case .authenticationFailed: return .authenticationFailed
        case .keyFileNotFound: return .keyFileNotFound(path: "/keys/id_test")
        case .keyPassphraseRequired: return .keyPassphraseRequired
        case .keyPassphraseRejected: return .keyPassphraseRejected
        case .keyUnparsable: return .keyUnparsable
        case .keyTypeNotLoadable: return .keyTypeNotLoadable(algorithm: "ssh-dss")
        case .keyPEMNotReadable: return .keyPEMNotReadable
        case .agentUnavailable: return .agentUnavailable
        case .agentHasNoIdentities: return .agentHasNoIdentities
        case .agentHasNoUsableIdentity: return .agentHasNoUsableIdentity
        case .agentRefusedEveryIdentity: return .agentRefusedEveryIdentity
        case .agentMisbehaved: return .agentMisbehaved
        case .keychainUnreadable: return .keychainUnreadable
        case .connectionFailed: return .connectionFailed
        case .serverAnswerUnusable: return .serverAnswerUnusable
        case .sessionUsesLoginSet: return .sessionUsesLoginSet(session: "prod")
        case .sessionUsesJumpHost: return .sessionUsesJumpHost(session: "behind")
        case .sessionIsNotSSH: return .sessionIsNotSSH(session: "objects", connectionKind: .s3)
        case .sessionMissing: return .sessionMissing
        case .portInUse: return .portInUse(port: 8080)
        case .bindAddressUnavailable: return .bindAddressUnavailable(address: "192.0.2.1")
        case .bindPermissionDenied: return .bindPermissionDenied(port: 80)
        case .bindFailed: return .bindFailed
        case .channelOpenFailed: return .channelOpenFailed
        case .connectFailed: return .connectFailed
        case .pumpFailed: return .pumpFailed
        case .alreadyStarted: return .alreadyStarted
        case .remotePortZeroRefused: return .remotePortZeroRefused
        case .remoteBindRefused: return .remoteBindRefused(needsGatewayPorts: true)
        case .remoteForwardUnanswered: return .remoteForwardUnanswered
        case .connectionLost: return .connectionLost
        case .unknown: return .unknown
        }
    }
}
