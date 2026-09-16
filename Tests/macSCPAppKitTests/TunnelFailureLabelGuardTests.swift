import Foundation
import MacSCPTestSupport
import Testing
import macSCPCore

@testable import MacSCPAppKit

/// A forwarding's failure is shown in the app's language, on all four
/// surfaces that read `TunnelProfilesSheet.stateLabel` — the profiles sheet,
/// the autostart sheet, the Dock menu and the sidebar glyph.
///
/// Every kind is reached through `TunnelFailureKind.Name.allCases`, never
/// through a list written here, so a kind added in Core is covered the
/// moment it compiles — and `sample(_:)` below, an exhaustive switch, is
/// where the compiler asks for it.
@MainActor @Suite struct TunnelFailureLabelGuardTests {
    private static let sentinel = "ZZ-UNRESOLVED-ZZ"

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let sheetFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/TunnelProfilesSheet.swift")

    /// One value per name. Payloads are placeholders a rendered label can
    /// be searched for.
    static func sample(_ name: TunnelFailureKind.Name) -> TunnelFailureKind {
        switch name {
        case .hostKeyMismatch: return .hostKeyMismatch(host: "server.test")
        case .hostKeyNotAccepted: return .hostKeyNotAccepted
        case .authenticationFailed: return .authenticationFailed
        case .keyFileNotFound: return .keyFileNotFound(path: "/keys/id_test")
        case .keyPassphraseRequired: return .keyPassphraseRequired
        case .keyPassphraseRejected: return .keyPassphraseRejected
        case .keyUnparsable: return .keyUnparsable
        case .keyTypeNotLoadable: return .keyTypeNotLoadable(algorithm: "ssh-test")
        case .keyPEMNotReadable: return .keyPEMNotReadable
        case .agentUnavailable: return .agentUnavailable
        case .agentHasNoIdentities: return .agentHasNoIdentities
        case .agentHasNoUsableIdentity: return .agentHasNoUsableIdentity
        case .agentRefusedEveryIdentity: return .agentRefusedEveryIdentity
        case .agentMisbehaved: return .agentMisbehaved
        case .keychainUnreadable: return .keychainUnreadable
        case .connectionFailed: return .connectionFailed
        case .serverAnswerUnusable: return .serverAnswerUnusable
        case .sessionUsesLoginSet: return .sessionUsesLoginSet(session: "session-one")
        case .sessionUsesJumpHost: return .sessionUsesJumpHost(session: "session-two")
        case .sessionIsNotSSH:
            return .sessionIsNotSSH(session: "session-three", connectionKind: .webdav)
        case .sessionMissing: return .sessionMissing
        case .portInUse: return .portInUse(port: 48213)
        case .bindFailed: return .bindFailed
        case .channelOpenFailed: return .channelOpenFailed
        case .connectFailed: return .connectFailed
        case .pumpFailed: return .pumpFailed
        case .alreadyStarted: return .alreadyStarted
        case .connectionLost: return .connectionLost
        case .unknown: return .unknown
        }
    }

    /// The payload a label must show, where its key has a placeholder.
    private static func shownPayload(_ kind: TunnelFailureKind) -> String? {
        switch kind {
        case .hostKeyMismatch(let host): return host
        case .keyFileNotFound(let path): return path
        case .keyTypeNotLoadable(let algorithm): return algorithm
        case .sessionUsesLoginSet(let session), .sessionUsesJumpHost(let session),
            .sessionIsNotSSH(let session, _):
            return session
        case .portInUse(let port): return String(port)
        default: return nil
        }
    }

    /// Every kind has its own key, named after it, and the catalogue
    /// answers it. That the other three catalogues declare the same keys is
    /// `LocalizableStringsTests`' and `LocalizationParityTests`' job.
    @Test(arguments: TunnelFailureKind.Name.allCases)
    func everyKindHasAKeyTheCatalogueAnswers(_ name: TunnelFailureKind.Name) {
        let key = TunnelProfilesSheet.failureKey(name)
        let stem = "tunnel.failure.\(name.rawValue)"
        #expect(key == stem || key.hasPrefix(stem + " "), "\(name.rawValue) has the key \(key)")
        #expect(
            L10n.string(key, Self.sentinel) != Self.sentinel,
            "the catalogue answers nothing for \(key)")
    }

    @Test func noTwoKindsShareAKey() {
        let keys = TunnelFailureKind.Name.allCases.map { TunnelProfilesSheet.failureKey($0) }
        #expect(Set(keys).count == keys.count)
    }

    /// Rendered: a key with a placeholder shows the payload, and no label
    /// shows a placeholder, a key, or the log's English sentence.
    @Test(arguments: TunnelFailureKind.Name.allCases)
    func everyKindRendersThroughTheCatalogue(_ name: TunnelFailureKind.Name) {
        let kind = Self.sample(name)
        let label = TunnelProfilesSheet.stateLabel(.failed(kind))
        let key = TunnelProfilesSheet.failureKey(name)
        #expect(!label.isEmpty)
        #expect(!label.contains("%@"), "\(name.rawValue) shows a raw placeholder")
        #expect(!label.contains("tunnel.failure."), "\(name.rawValue) shows its key")
        #expect(label != kind.sentence, "\(name.rawValue) shows the log's sentence")
        #expect(key.hasSuffix(" %@") == (Self.shownPayload(kind) != nil))
        if let payload = Self.shownPayload(kind) {
            #expect(label.contains(payload), "\(name.rawValue) does not show its payload")
        }
    }

    /// Source: the two functions translate — they read `L10n` — and never
    /// describe the kind or read its English sentence.
    ///
    /// Two views, because each blanks something the other needs: the strict
    /// view (comments and literals blanked) proves a call is CODE, and the
    /// comment-blanked view keeps literals, so an interpolation such as a
    /// described kind inside a string is still visible to the negative.
    @Test func theLabelsTranslateAndNeverDescribeTheKind() throws {
        let raw = try String(contentsOf: Self.sheetFile, encoding: .utf8)
        let strict = try SwiftSource.blankingCommentsAndStrings(raw)
        let withLiterals = try SwiftSource.blankingComments(raw)

        let stateStrict = try TransferQueueBarCancelGuardTests.declarationBody(
            of: "static func stateLabel(_ state: TunnelState) -> String", in: strict)
        let failureStrict = try TransferQueueBarCancelGuardTests.declarationBody(
            of: "static func failureLabel(_ kind: TunnelFailureKind) -> String", in: strict)
        let stateLiterals = try TransferQueueBarCancelGuardTests.declarationBody(
            of: "static func stateLabel(_ state: TunnelState) -> String", in: withLiterals)
        let failureLiterals = try TransferQueueBarCancelGuardTests.declarationBody(
            of: "static func failureLabel(_ kind: TunnelFailureKind) -> String", in: withLiterals)

        // Positives: the scanned bodies are the ones that translate.
        #expect(stateStrict.contains("failureLabel(kind)"), "stateLabel no longer maps a failure")
        #expect(failureStrict.contains("L10n.string("), "failureLabel reads no catalogue")
        #expect(failureStrict.contains("failureKey(kind.name)"), "failureLabel derives no key")
        #expect(stateLiterals.contains("tunnel.state.stopped"), "the literal view lost its span")
        #expect(failureLiterals.contains("%@"), "the literal view lost its span")

        for (label, body) in [
            ("stateLabel", stateLiterals), ("failureLabel", failureLiterals),
        ] {
            #expect(!body.contains("String(describing:"), "\(label) describes a value")
            #expect(!body.contains(".sentence"), "\(label) shows the log's English sentence")
            #expect(!body.contains("\\(kind"), "\(label) interpolates the kind")
            #expect(!body.contains("\\(state"), "\(label) interpolates the state")
            #expect(!body.contains("\\(reason"), "\(label) interpolates a reason")
        }
        #expect(
            !stateLiterals.contains("case .failed(let reason): return reason"),
            "stateLabel shows a failure verbatim again")
    }
}
