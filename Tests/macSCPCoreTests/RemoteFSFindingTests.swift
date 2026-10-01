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
    /// That the catalogue FILES declare all eighteen keys, in all four
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
            .resourceDetailsUnparsable,
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

    /// `logSentence` is a second English text beside the `en` catalogue, on
    /// purpose — the log's sentences are lower-case phrases a `reason=`
    /// field completes (the doc comment on `RemoteFSFinding.logSentence`). Nothing held the two
    /// together, so they could drift silently; this is what holds them.
    ///
    /// Measured 2026-10-01 across all of them: equal, with the first
    /// character compared case-insensitively. The first character is the one
    /// difference the two texts are allowed to have, and it is a real one —
    /// `resumeRangeIgnored` opens with "S3", which must not be lower-cased
    /// to "s3". None of the catalogue sentences ends with a period, so
    /// nothing is stripped here.
    ///
    /// The catalogue is read off disk rather than through
    /// `CoreL10n.string` / `message`: those resolve through the test
    /// process's current locale, and this property must hold whatever locale
    /// runs the test, not only under `en`. Same reason, and same route, as
    /// `S3FileSystemTests.rangeIgnoredReasonStillMatchesTheFindingsEnglishCatalogueEntry`.
    @Test func everyLogSentenceMatchesItsEnglishCatalogueEntry() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let enCatalogue = repoRoot
            .appendingPathComponent("Sources/macSCPCore/Resources/en.lproj/Localizable.strings")
            .path(percentEncoded: false)
        let catalogue = try #require(NSDictionary(contentsOfFile: enCatalogue) as? [String: String])

        #expect(RemoteFSFinding.everySample.isEmpty == false, """
            everySample came back empty, so the loop below checked nothing.
            """)

        for (finding, argument) in RemoteFSFinding.everySample {
            let key = finding.messageKey
            let english = try #require(catalogue[key], """
                No en entry for \(finding.name) at key \(key).
                """)
            let expected = argument.map { String(format: english, $0) } ?? english
            let actual = finding.logSentence

            #expect(actual.count == expected.count, """
                \(finding.name): logSentence and its en entry differ in length.
                log: \(actual)
                en : \(expected)
                """)
            #expect(actual.dropFirst() == expected.dropFirst(), """
                \(finding.name): logSentence and its en entry differ after the \
                first character. Only the first character may differ, and only \
                in case.
                log: \(actual)
                en : \(expected)
                """)
            #expect(actual.prefix(1).lowercased() == expected.prefix(1).lowercased(), """
                \(finding.name): logSentence and its en entry differ in their \
                first character beyond case.
                log: \(actual)
                en : \(expected)
                """)
        }
    }
}

extension RemoteFSFinding {
    /// One sample per `Name`, with the argument its catalogue key
    /// interpolates — by exhaustive switch, so a finding added to the enum
    /// does not compile until it has a sample, and cannot be left out of
    /// the guards above.
    ///
    /// The payloads are placeholders: a status code, a path this project
    /// owns and an upload part number it counted out itself, which is
    /// exactly what the three payload-carrying findings are allowed to hold
    /// (counted in the switch below, 2026-10-01: three of eighteen).
    ///
    /// `formatArgument` is `nil` for a finding whose key carries no format
    /// specifier, and the interpolated value as a string for the three that
    /// do — which is what lets
    /// `everyLogSentenceMatchesItsEnglishCatalogueEntry` format the
    /// catalogue value the same way `message` would.
    static var everySample: [(finding: RemoteFSFinding, formatArgument: String?)] {
        Name.allCases.map { name in
            switch name {
            case .resumeRangeIgnored: return (.resumeRangeIgnored, nil)
            case .sourceChangedSinceInterruption: return (.sourceChangedSinceInterruption, nil)
            case .unexpectedStatus: return (.unexpectedStatus(code: 418), "418")
            case .directoryAlreadyExists: return (.directoryAlreadyExists, nil)
            case .destinationAlreadyExists: return (.destinationAlreadyExists, nil)
            case .outOfStorage: return (.outOfStorage, nil)
            case .uploadStreamUnavailable: return (.uploadStreamUnavailable, nil)
            case .pathExistsAndIsNotADirectory:
                return (.pathExistsAndIsNotADirectory(path: "/srv/x"), "/srv/x")
            case .nonHTTPResponse: return (.nonHTTPResponse, nil)
            case .listingUnparsable: return (.listingUnparsable, nil)
            case .resourceDetailsUnparsable: return (.resourceDetailsUnparsable, nil)
            case .redirectUnreadable: return (.redirectUnreadable, nil)
            case .redirectBodyNotResendable: return (.redirectBodyNotResendable, nil)
            case .redirectNotResignable: return (.redirectNotResignable, nil)
            case .resumeNotSupported: return (.resumeNotSupported, nil)
            case .noSuchBucket: return (.noSuchBucket, nil)
            case .uploadPartUnacknowledged: return (.uploadPartUnacknowledged(part: 7), "7")
            case .requestBodyUnencodable: return (.requestBodyUnencodable, nil)
            }
        }
    }

    /// The samples alone — what the guards that need no argument read.
    static var everyCase: [RemoteFSFinding] { everySample.map(\.finding) }
}
