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
    static func failure(of kind: FTPConnectionFailure.Kind) -> FTPConnectionFailure {
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
    static let expectedKinds: [FTPConnectionFailure.Kind: TunnelFailureKind] = [
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

        let isItsOwn = sentence == failure.logSentence
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

    /// The log's sentence is its own text and fixed English: not the
    /// catalogue's (that one is looked up per locale and is for the UI), not a
    /// key, not empty, and one per kind. The catalogue half is held by
    /// `FTPControlConnectionTests.everyConnectionFailureHasItsOwnSentence`;
    /// this is the other half, walked over the same `CaseIterable` tag so a
    /// kind added without a sentence cannot slip past.
    @Test func everyKindHasAFixedEnglishLogSentenceOfItsOwn() {
        var seen: [String: FTPConnectionFailure.Kind] = [:]
        for kind in FTPConnectionFailure.Kind.allCases {
            let sentence = Self.failure(of: kind).logSentence
            #expect(!sentence.isEmpty, "\(kind) has no log sentence")
            #expect(sentence != kind.messageKey, "\(kind) logs its catalogue key")
            let isAKey = sentence.hasPrefix("core.")
            #expect(isAKey == false, "\(kind) logs a key")
            // The structural half, and the one that does not depend on
            // luck (F12 of fix round 2): the sentence is not what the
            // catalogue answers for the same key. The property this test
            // wants is "this text does not change with the locale", and
            // nothing in this suite can set a locale; this is the closest
            // check that needs none.
            //
            // It replaces nothing — the ASCII check below stays — but it is
            // the one the catalogue-lookup plant is caught by on purpose
            // rather than by accident. The re-review of fix round 1 measured
            // that plant going red ONLY through the ASCII check, and only
            // because the `en` catalogue's own sentences happen to carry
            // typographic punctuation (the em dash in "Authentication
            // failed — check username or password."). Under an `en`
            // catalogue that happened to be plain ASCII, a localized
            // `logSentence` would have passed every check here.
            let catalogued = CoreL10n.string(kind.messageKey)
            // The positive beside the negative: the catalogue really answers
            // for this key. `CoreL10n.string` returns the key it was given
            // when no catalogue declares it, so without this the inequality
            // below could be a comparison against a key rather than against
            // a sentence — satisfied by a catalogue that has gone missing.
            let catalogueAnswers = catalogued != kind.messageKey
            #expect(catalogueAnswers, "\(kind)'s catalogue key does not resolve")
            let isTheCatalogues = sentence == catalogued
            #expect(isTheCatalogues == false, "\(kind) logs the catalogue's own text")
            // Fixed English means ASCII words: a looked-up translation would
            // carry accents or another script in some locale.
            let isASCII = sentence.allSatisfy(\.isASCII)
            #expect(isASCII, "\(kind)'s log sentence is not plain ASCII")
            if let earlier = seen[sentence] {
                Issue.record("\(kind) and \(earlier) share the log sentence")
            }
            seen[sentence] = kind
        }
        // The positive beside the walk: it found the kinds at all.
        #expect(seen.count == FTPConnectionFailure.Kind.allCases.count)
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
