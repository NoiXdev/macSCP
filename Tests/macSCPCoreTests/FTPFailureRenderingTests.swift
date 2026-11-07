import Foundation
import Testing

@testable import macSCPCore

/// How an `FTPConnectionFailure` reaches the places that render an error:
/// `DialSupport.reason(for:)` (the connect form's audit reason, the browser
/// banner's fallback, the diagnostics rows) and `DialSupport.failureKind(for:)`.
///
/// **Both halves are asserted, and separately.** An arm that returned the
/// right sentence and defaulted the kind would pass every sentence check and
/// silently reclassify the failure for each consumer of
/// `DialSupport.failureKind(for:)`; an arm that returned the right kind and
/// let the bridge render the sentence would pass the kind check and show a
/// case index. The `.finding` arm of the same function carries the same
/// warning, and this file is the FTP half of the test that holds it.
@Suite("FTP failures through the dial mapper")
struct FTPFailureRenderingTests {
    /// One representative failure per `FTPConnectionFailure.Kind`, built by a
    /// `switch` with no `default`, so a kind added to the enum does not
    /// compile here until it has a failure to hand the mapper.
    private static func failure(of kind: FTPConnectionFailure.Kind) -> FTPConnectionFailure {
        switch kind {
        case .greetingRefused: .greetingRefused(code: 421)
        case .timedOut: .timedOut
        case .connectionClosed: .connectionClosed
        case .protocolViolation: .protocolViolation
        case .tlsUpgradeRefused: .tlsUpgradeRefused(code: 534)
        case .tlsHandshakeFailed: .tlsHandshakeFailed
        case .loginRefused: .loginRefused
        case .binaryModeRefused: .binaryModeRefused(code: 504)
        case .credentialNotSendable: .credentialNotSendable
        case .certificateRejected: .certificateRejected
        case .certificateMismatch: .certificateMismatch
        case .trustStoreUnreadable: .trustStoreUnreadable
        case .dataCertificateDiffers: .dataCertificateDiffers
        case .sessionFromAnotherConnection: .sessionFromAnotherConnection
        case .sessionRefusedByTLS: .sessionRefusedByTLS
        case .passiveAddressRefused: .passiveAddressRefused
        case .passiveModeRefused: .passiveModeRefused(code: 500)
        case .transferRefused: .transferRefused(code: 553)
        case .restRefused: .restRefused(code: 501)
        case .leaseAlreadyReturned: .leaseAlreadyReturned
        }
    }

    /// The kind each failure is classified as. Written out per case rather
    /// than derived, so the table is a statement that can be disagreed with:
    ///
    /// - a login the server refused is `authenticationFailed`, the one FTP
    ///   failure that has a kind of its own;
    /// - everything that ended or refused the connection itself (the greeting,
    ///   the clock, the TLS upgrade and every certificate verdict) is
    ///   `connectionFailed`;
    /// - a server that ANSWERED something this client cannot use (a stream
    ///   that cannot be read, a refused binary mode, passive mode, `REST` or
    ///   transfer) is `serverAnswerUnusable`;
    /// - what is macSCP's own guard or a local fault (an unsendable
    ///   credential, a TLS session offered to the wrong connection, a lease
    ///   used twice, an unreadable trust store) is `unknown`, which is
    ///   what `DialSupport` says of an error a forwarding does not produce.
    private static let expectedKinds: [FTPConnectionFailure.Kind: TunnelFailureKind] = [
        .greetingRefused: .connectionFailed,
        .timedOut: .connectionFailed,
        .connectionClosed: .connectionFailed,
        .protocolViolation: .serverAnswerUnusable,
        .tlsUpgradeRefused: .connectionFailed,
        .tlsHandshakeFailed: .connectionFailed,
        .loginRefused: .authenticationFailed,
        .binaryModeRefused: .serverAnswerUnusable,
        .credentialNotSendable: .unknown,
        .certificateRejected: .connectionFailed,
        .certificateMismatch: .connectionFailed,
        .trustStoreUnreadable: .unknown,
        .dataCertificateDiffers: .connectionFailed,
        .sessionFromAnotherConnection: .unknown,
        .sessionRefusedByTLS: .connectionFailed,
        .passiveAddressRefused: .serverAnswerUnusable,
        .passiveModeRefused: .serverAnswerUnusable,
        .transferRefused: .serverAnswerUnusable,
        .restRefused: .serverAnswerUnusable,
        .leaseAlreadyReturned: .unknown,
    ]

    /// The table has a row for every kind the enum declares, and no other.
    /// Without this the parameterised cases below would cover whatever the
    /// table happened to list, and a kind missing from it would be tested
    /// against `nil`.
    @Test func theExpectationsCoverEveryKindExactly() {
        #expect(Set(Self.expectedKinds.keys) == Set(FTPConnectionFailure.Kind.allCases))
        // The positive beside the equality: two empty sets are equal.
        #expect(!FTPConnectionFailure.Kind.allCases.isEmpty)
    }

    @Test(arguments: FTPConnectionFailure.Kind.allCases)
    func theSentenceIsTheFailuresOwnAndNotTheBridgedCaseIndex(_ kind: FTPConnectionFailure.Kind) {
        let failure = Self.failure(of: kind)
        let sentence = DialSupport.reason(for: failure)
        let bridged = (failure as NSError).localizedDescription

        let isItsOwn = sentence == failure.message
        let isTheBridge = sentence == bridged
        let isAKey = sentence == failure.messageKey
        #expect(isItsOwn)
        #expect(isTheBridge == false)
        // `CoreL10n.string` returns the key for a key no catalogue declares,
        // so a sentence equal to its key would pass the first check.
        #expect(isAKey == false)
    }

    @Test(arguments: FTPConnectionFailure.Kind.allCases)
    func theKindIsPreservedAndNotDefaulted(_ kind: FTPConnectionFailure.Kind) throws {
        let expected = try #require(Self.expectedKinds[kind])
        #expect(DialSupport.failureKind(for: Self.failure(of: kind)) == expected)
    }

    /// The reason a failure's PAYLOAD does not reach the sentence: a reply
    /// code is the most any case holds, and the sentence is a catalogue entry.
    /// Two failures of one kind with different codes read the same.
    @Test func aReplyCodeIsNotPartOfTheSentence() {
        let first = DialSupport.reason(for: FTPConnectionFailure.transferRefused(code: 553))
        let second = DialSupport.reason(for: FTPConnectionFailure.transferRefused(code: 452))
        #expect(first == second)
        let carriesTheCode = first.contains("553") || first.contains("452")
        #expect(carriesTheCode == false)
    }
}
