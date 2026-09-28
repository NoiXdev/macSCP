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
    /// no entry, so a missing sentence is silent at the lookup. These three
    /// expectations are what make it loud: the message is not the key, it
    /// does not begin with the key's own prefix, and the log's English is
    /// there at all.
    @Test func everyFindingResolvesToASentenceAndNotToItsKey() {
        for finding in RemoteFSFinding.everyCase {
            #expect(finding.message != finding.messageKey, "\(finding.name) renders as its key")
            #expect(finding.logSentence.isEmpty == false)
            // The positive: the sentence is the catalogue's, not the key text.
            #expect(finding.message.hasPrefix("core.finding.") == false)
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
    /// IS an endpoint fails both halves of `noFindingCarriesForeignText`.
    ///
    /// Written as two halves so neither the value nor its spelling can
    /// reach a failure message from this file (`CLAUDE.md`, "A value a test
    /// must not leak has two exits"), and the `Bool`s are computed before
    /// the expectations for the same reason.
    @Test func theURLGuardSeesAPlantedEndpoint() {
        let credential = "AKIAEXAMPLE" + ":" + "s3cr3t"
        let planted = RemoteFSFinding.pathExistsAndIsNotADirectory(
            path: "https://" + credential + "@example.invalid/b")
        let text = planted.logSentence
        let carriesUserinfo = text != URLText.withoutUserinfo(text)
        let carriesURL = text.contains("://")
        #expect(carriesUserinfo)
        #expect(carriesURL)
    }
}

extension RemoteFSFinding {
    /// One value per `Name`, by exhaustive switch — so a finding added to
    /// the enum does not compile until it has a sample, and cannot be left
    /// out of the guards above.
    ///
    /// The payloads are placeholders: a status code and a path this project
    /// owns, which is exactly what the two payload-carrying findings are
    /// allowed to hold.
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
            }
        }
    }
}
