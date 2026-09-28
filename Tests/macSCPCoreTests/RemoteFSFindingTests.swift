import Foundation
import Testing

@testable import macSCPCore

/// `RemoteFSFinding` is the case a mapper can translate: a finding this
/// project named, with a catalogue key derived from the name and a fixed
/// English sentence beside it for the log.
///
/// Every check here walks `everyCase` below rather than a list written in
/// the check, so a finding added to the enum is covered the moment it
/// compiles — and `everyCase`, an exhaustive switch over `Name`, is where
/// the compiler asks for it.
@Suite struct RemoteFSFindingTests {
    /// The three redirect refusals are the findings that read as a
    /// connection failure, and nothing else does. A set rather than a
    /// negative filter: the check is a comparison per finding, so it is red
    /// in both directions — a fourth that starts reading that way, and one
    /// of these three that stops.
    @Test func exactlyTheRedirectFindingsReadAsAConnectionFailure() {
        let connectionFailures: Set<RemoteFSFinding.Name> =
            [.redirectUnreadable, .redirectBodyNotResendable, .redirectNotResignable]
        for finding in RemoteFSFinding.everyCase {
            #expect(
                finding.readsAsConnectionFailure
                    == connectionFailures.contains(finding.name),
                "\(finding.name) reads as a connection failure: \(finding.readsAsConnectionFailure)")
            // The positive beside the negative: the error wrapping it agrees.
            #expect(
                RemoteFSError.finding(finding).isConnectionFailure
                    == finding.readsAsConnectionFailure)
        }
    }

    /// `CoreL10n.string` falls back to the KEY text when the catalogue has
    /// no entry, so a missing sentence is silent at the lookup.
    ///
    /// Three checks, labelled for what they are. Two are NEGATIVE — the
    /// message is not the key, and it does not begin with the key's prefix
    /// either. The POSITIVE beside them is `catalogueAnswers`: the
    /// catalogue really resolves the derived key, and the message is that
    /// resolved value with the finding's own argument in the slot the
    /// catalogue put it. That is the shape
    /// `TransferFailureKindTests.everyKindHasANameAndACatalogueSentence`
    /// uses, and it is locale-independent — a machine running in `de` reads
    /// its own catalogue and both halves still agree.
    ///
    /// That the catalogue FILES declare all seventeen keys, in all four
    /// languages, is `everyRemoteFSFindingHasItsOwnSentence`'s job.
    @Test func everyFindingResolvesToASentenceAndNotToItsKey() {
        for finding in RemoteFSFinding.everyCase {
            let resolved = CoreL10n.string(finding.messageKey)
            let catalogueAnswers = resolved != finding.messageKey
            #expect(catalogueAnswers, """
                the catalogue does not answer for \(finding.messageKey) — CoreL10n fell back \
                to the key text.
                """)
            #expect(finding.message != finding.messageKey, "\(finding.name) renders as its key")
            #expect(finding.message.hasPrefix("core.finding.") == false)
            #expect(finding.logSentence.isEmpty == false)

            let argument = Self.argument(of: finding)
            #expect(
                finding.message == (argument.map { String(format: resolved, $0) } ?? resolved),
                "\(finding.name)'s message is not the catalogue's sentence with its argument")
        }
    }

    /// The one argument each payload-carrying finding interpolates, as the
    /// text `String(format:)` receives, or `nil` for a finding that takes
    /// none. Exhaustive for the reason `messageKey(for:)` is: a finding
    /// added later with a payload must say what it interpolates rather than
    /// silently interpolating nothing.
    private static func argument(of finding: RemoteFSFinding) -> String? {
        switch finding {
        case .unexpectedStatus(let code): return String(code)
        case .pathExistsAndIsNotADirectory(let path): return path
        case .uploadPartUnacknowledged(let part): return String(part)
        case .resumeRangeIgnored, .sourceChangedSinceInterruption,
            .directoryAlreadyExists, .destinationAlreadyExists, .outOfStorage,
            .uploadStreamUnavailable, .nonHTTPResponse, .listingUnparsable,
            .redirectUnreadable, .redirectBodyNotResendable, .redirectNotResignable,
            .resumeNotSupported, .noSuchBucket, .requestBodyUnencodable:
            return nil
        }
    }

    /// The property the whole type rests on, and the reason no consumer
    /// filters a finding: neither text a finding produces carries a URL,
    /// so neither can carry the userinfo of an endpoint the user typed.
    @Test func noFindingCarriesForeignText() {
        for finding in RemoteFSFinding.everyCase {
            for text in [finding.message, finding.logSentence] {
                let carriesUserinfo = text != URLText.withoutUserinfo(text)
                #expect(carriesUserinfo == false, "\(finding.name) carries a URL with userinfo")
                #expect(text.contains("://") == false, "\(finding.name) carries a URL")
            }
        }
    }

    /// The guard is not blind to what it forbids: a finding whose payload
    /// IS an endpoint fails both halves of `noFindingCarriesForeignText`,
    /// in BOTH texts that guard scans. Planting into only one of them would
    /// leave the other free to go stale into scanning nothing.
    ///
    /// The credential is written as two halves so neither the value nor its
    /// spelling can reach a failure message from this file (`CLAUDE.md`,
    /// "A value a test must not leak has two exits"), and the `Bool`s are
    /// computed before the expectations for the same reason.
    @Test func theURLGuardSeesAPlantedEndpoint() {
        let credential = "AKIAEXAMPLE" + ":" + "s3cr3t"
        let planted = RemoteFSFinding.pathExistsAndIsNotADirectory(
            path: "https://" + credential + "@example.invalid/b")
        var scanned = 0
        for text in [planted.message, planted.logSentence] {
            scanned += 1
            let carriesUserinfo = text != URLText.withoutUserinfo(text)
            let carriesURL = text.contains("://")
            #expect(carriesUserinfo)
            #expect(carriesURL)
        }
        // The list above is the same two texts `noFindingCarriesForeignText`
        // scans; if one is dropped there, this count says which.
        #expect(scanned == 2)
    }
}

extension RemoteFSFinding {
    /// One value per `Name`, by exhaustive switch — so a finding added to
    /// the enum does not compile until it has a sample, and cannot be left
    /// out of the guards above.
    ///
    /// The payloads are placeholders: a status code, a path this project
    /// owns and an upload part number it counted out itself, which is
    /// exactly what the three payload-carrying findings are allowed to hold
    /// (counted in the switch below, 2026-09-28).
    static var everyCase: [RemoteFSFinding] {
        Name.allCases.map { name in
            switch name {
            case .resumeRangeIgnored: return .resumeRangeIgnored
            case .sourceChangedSinceInterruption: return .sourceChangedSinceInterruption
            case .unexpectedStatus: return .unexpectedStatus(code: 418)
            case .directoryAlreadyExists: return .directoryAlreadyExists
            case .destinationAlreadyExists: return .destinationAlreadyExists
            case .outOfStorage: return .outOfStorage
            case .uploadStreamUnavailable: return .uploadStreamUnavailable
            case .pathExistsAndIsNotADirectory:
                return .pathExistsAndIsNotADirectory(path: "/srv/x")
            case .nonHTTPResponse: return .nonHTTPResponse
            case .listingUnparsable: return .listingUnparsable
            case .redirectUnreadable: return .redirectUnreadable
            case .redirectBodyNotResendable: return .redirectBodyNotResendable
            case .redirectNotResignable: return .redirectNotResignable
            case .resumeNotSupported: return .resumeNotSupported
            case .noSuchBucket: return .noSuchBucket
            case .uploadPartUnacknowledged: return .uploadPartUnacknowledged(part: 7)
            case .requestBodyUnencodable: return .requestBodyUnencodable
            }
        }
    }
}
