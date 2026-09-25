import Foundation
import MacSCPTestSupport
import Testing
import macSCPCore

@testable import MacSCPAppKit

/// A transfer's failure is shown in the app's language, on the three
/// surfaces that render a cause: the transfer bar's failed row, the path
/// bar's failed listing, and the editor's open-failed banner.
///
/// Every kind is reached through `TransferFailureKind.Name.allCases`, never
/// through a list written here, so a kind added in Core is covered the
/// moment it compiles — and `sample(_:)` below, an exhaustive switch, is
/// where the compiler asks for it.
///
/// ## What "no catalogue entry" does, and why it is loud
///
/// `L10n.string(key, english)` falls back to its English argument when the
/// catalogue has nothing for `key`, exactly as `CoreL10n.string` falls back
/// to the key text — a silent English leak, which is the failure mode this
/// task exists to end. Two things make it loud instead. The classification
/// (`TransferFailureLabel.sentence(for:)`) is an exhaustive switch over
/// `Name`, so a kind added in Core does not compile until someone decides
/// which catalogue answers for it; and
/// `everyKindIsClassifiedAndTranslated` below reads the four `.lproj`
/// files off disk and requires an App-owned kind's key to be declared in
/// all four, with the three translations differing from the English. A
/// missing entry, or one pasted unchanged from English, is a red with the
/// locale and the key named in it.
@MainActor @Suite struct TransferFailureLabelGuardTests {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let appResources = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/Resources")
    private static let barFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/TransferQueueBar.swift")
    private static let labelFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/TransferFailureLabel.swift")

    /// The four the App is localized into, per `CLAUDE.md`.
    private static let locales = ["en", "de", "fr", "pl"]

    private static func catalogue(_ locale: String) throws -> [String: String] {
        let url = appResources.appendingPathComponent("\(locale).lproj/Localizable.strings")
        return try #require(NSDictionary(contentsOf: url) as? [String: String])
    }

    /// The free text a fixture gives a detail-carrying cause. Distinctive
    /// enough that finding it in a label is proof it was carried, not
    /// proof that two sentences happen to share a word.
    nonisolated static let detailFixture = "the server hung up (RFC-0000)"

    /// One value per name. Payloads are placeholders a rendered label can
    /// be searched for.
    nonisolated static func sample(_ name: TransferFailureKind.Name) -> TransferFailureKind {
        switch name {
        case .notFound: return .notFound(path: "/srv/x")
        case .permissionDenied: return .permissionDenied(path: "/srv/x")
        case .connectionFailed: return .connectionFailed(detail: detailFixture)
        case .protocolError: return .protocolError(detail: detailFixture)
        case .authenticationFailed: return .authenticationFailed
        case .jumpAuthenticationFailed: return .jumpAuthenticationFailed
        case .bucketListForbidden: return .bucketListForbidden
        case .bucketListEmpty: return .bucketListEmpty
        case .bucketLevelRefused: return .bucketLevelRefused(operation: .rename)
        case .crossBucketRenameRefused: return .crossBucketRenameRefused
        case .connectionLost: return .connectionLost
        case .interrupted: return .interrupted
        case .noFreeName: return .noFreeName
        case .unknown: return .unknown(detail: detailFixture)
        }
    }

    // MARK: - Every cause is covered

    /// The positive this suite is built around: every kind is classified,
    /// and whichever catalogue answers for it really answers, in all four
    /// languages.
    ///
    /// An App-owned kind's key is required in each of the four `.lproj`
    /// files, with the three translations differing from the English one —
    /// so a key added to `en` alone, or pasted across unchanged, is red
    /// rather than an English leak on a German screen. A Core-owned kind is
    /// held to the sentence Core renders; that Core's own four catalogues
    /// declare it is `macSCPCoreTests`' job
    /// (`TransferFailureKindTests.everyKindHasANameAndACatalogueSentence`
    /// asks the catalogue to ANSWER, and `LocalizableStringsTests` that all
    /// four declare the same keys), and duplicating it here would be a
    /// third copy of the same claim.
    @Test(arguments: TransferFailureKind.Name.allCases)
    func everyKindIsClassifiedAndTranslated(_ name: TransferFailureKind.Name) throws {
        let cause = Self.sample(name)
        let label = TransferFailureLabel.label(cause)
        #expect(!label.isEmpty)

        switch TransferFailureLabel.sentence(for: name) {
        case .core:
            #expect(label == cause.message, "\(name.rawValue) does not read Core's sentence")
        case .app(let key, let english):
            #expect(key == "transfers.failure.\(name.rawValue)", "\(key) is not named after \(name.rawValue)")
            var declaredEnglish: String?
            for locale in Self.locales {
                let value = try #require(try Self.catalogue(locale)[key], "\(locale) has no \(key)")
                if locale == "en" {
                    declaredEnglish = value
                    #expect(value == english, "en.lproj's \(key) is not the source text")
                } else {
                    #expect(value != declaredEnglish, "\(locale)'s \(key) is still the English sentence")
                }
            }
            // The App's sentence replaces Core's frame, it does not wrap it.
            #expect(label != cause.message, "\(name.rawValue) still renders Core's frame")
        }
    }

    /// The frame that marks a technical detail exists in all four
    /// languages, keeps both positional specifiers, and is not the English
    /// one three times over.
    @Test func theTechnicalDetailFrameIsTranslated() throws {
        let key = TransferFailureLabel.detailFrameKey
        var english: String?
        for locale in Self.locales {
            let value = try #require(try Self.catalogue(locale)[key], "\(locale) has no \(key)")
            #expect(value.contains("%1$@"), "\(locale)'s \(key) lost the prose slot")
            #expect(value.contains("%2$@"), "\(locale)'s \(key) lost the detail slot")
            if locale == "en" {
                english = value
                #expect(value == TransferFailureLabel.detailFrameEnglish)
            } else {
                #expect(value != english, "\(locale)'s \(key) is still the English frame")
            }
        }
    }

    /// The two classifications agree on which kinds carry free text: every
    /// App-owned kind has a detail to show, and no Core-owned kind does.
    /// Without this the two exhaustive switches could drift into disagreeing
    /// — a kind classified `.app` whose detail is dropped would silently
    /// lose the only actionable half of its message.
    @Test(arguments: TransferFailureKind.Name.allCases)
    func everyAppOwnedKindCarriesADetail(_ name: TransferFailureKind.Name) {
        let cause = Self.sample(name)
        let detail = TransferFailureLabel.technicalDetail(of: cause)
        switch TransferFailureLabel.sentence(for: name) {
        case .app: #expect(detail == Self.detailFixture, "\(name.rawValue) shows no detail")
        case .core: #expect(detail == nil, "\(name.rawValue) carries a detail nothing shows")
        }
    }

    /// Exactly three kinds are the App's own, and they are the three whose
    /// payload is free text a backend wrote — the `docs/BACKLOG.md` row's
    /// finding, stated as a number so it is checked rather than remembered.
    @Test func exactlyTheThreeFreeTextKindsAreTheAppsOwn() {
        let appOwned = TransferFailureKind.Name.allCases.filter {
            if case .app = TransferFailureLabel.sentence(for: $0) { return true }
            return false
        }
        #expect(Set(appOwned) == [.connectionFailed, .protocolError, .unknown])
        #expect(appOwned.count == 3)
        #expect(TransferFailureKind.Name.allCases.count == 14)
    }

    // MARK: - What the rendered line says

    /// A detail-carrying cause reads as translated prose FIRST and the
    /// technical detail behind it — the decision of 2026-09-25, as a
    /// rendering rather than as a comment.
    @Test(arguments: [
        TransferFailureKind.connectionFailed(detail: detailFixture),
        .protocolError(detail: detailFixture),
        .unknown(detail: detailFixture),
    ])
    func aFreeTextCauseKeepsItsDetailBehindTranslatedProse(_ cause: TransferFailureKind) throws {
        guard case .app(let key, let english) = TransferFailureLabel.sentence(for: cause.name)
        else { Issue.record("\(cause.name.rawValue) is not App-owned"); return }
        let prose = L10n.string(key, english)
        let label = TransferFailureLabel.label(cause)
        #expect(label.hasPrefix(prose), "the translated sentence is not what the row starts with")
        #expect(label.contains(Self.detailFixture), "the detail was dropped")
        #expect(label != Self.detailFixture)
        #expect(!label.contains("%1$@"), "a raw placeholder reached the row")
        #expect(!label.contains("%2$@"), "a raw placeholder reached the row")
        #expect(label.count > prose.count)
    }

    /// An empty detail — a backend that said nothing — leaves the prose
    /// alone rather than rendering an empty pair of brackets.
    @Test func anEmptyDetailIsNotShownAtAll() {
        let label = TransferFailureLabel.label(.unknown(detail: ""))
        #expect(label == L10n.string("transfers.failure.unknown", "The transfer failed."))
    }

    /// Nothing the label shows describes the cause: a described value would
    /// print a case name and a payload label, and for two kinds it would put
    /// a path into the row verbatim.
    @Test(arguments: TransferFailureKind.Name.allCases)
    func noLabelDescribesTheCause(_ name: TransferFailureKind.Name) {
        let cause = Self.sample(name)
        let described = String(describing: cause)
        let labelDescribes = TransferFailureLabel.label(cause) == described
        #expect(labelDescribes == false, "\(name.rawValue) is described rather than said")
        #expect(!TransferFailureLabel.label(cause).contains(name.rawValue + "("))
    }

    /// The error-to-sentence door the path bar and the editor banner use
    /// reaches the same text as the row's, so the three surfaces cannot
    /// disagree.
    @Test func theErrorDoorAgreesWithTheCauseDoor() {
        let error = RemoteFSError.protocolError(reason: Self.detailFixture)
        #expect(
            TransferFailureLabel.text(for: error)
                == TransferFailureLabel.label(.protocolError(detail: Self.detailFixture)))
    }

    // MARK: - Source: which expression each surface hands to its frame

    /// The bar's failed row reads the App's mapper, never Core's rendering
    /// and never a described value.
    ///
    /// This is the line Task 5's review left unpinned: a planted
    /// `String(describing: cause)` there left the whole suite green, which
    /// would put a path or a free-text detail into the row verbatim. The
    /// positive beside the two negatives is what keeps them from going
    /// stale — a renamed mapper turns this red rather than leaving the
    /// negatives matching nothing.
    @Test func theFailedRowReadsTheAppsOwnLabel() throws {
        let code = try SourceCorpus.code(of: Self.barFile)
        let body = try TransferQueueBarCancelGuardTests.declarationBody(
            of: "private func row(_ item: TransferQueueViewModel.Item) -> some View", in: code)
        #expect(body.contains("TransferFailureLabel.label(cause)"), "the row maps no cause")
        #expect(body.contains("case .failed(let cause):"), "the row no longer binds a cause")
        #expect(!body.contains("cause.message"), "the row shows Core's rendering")
        #expect(!body.contains("String(describing:"), "the row describes the cause")
        #expect(!body.contains("\\(cause"), "the row interpolates the cause")
    }

    /// The other two surfaces that turn an error into a sentence inside a
    /// localized frame go through the same door.
    @Test(arguments: [
        ("PathBar.swift", "browser.pathBar.listingFailed %@"),
        ("ContentView+Transfers.swift", "edit.openFailed"),
    ])
    func everyLocalizedFrameFillsItselfFromTheAppsLabel(
        _ surface: (file: String, key: String)
    ) throws {
        let url = Self.repoRoot.appendingPathComponent("Sources/MacSCPAppKit/\(surface.file)")
        let code = try SourceCorpus.code(of: url)
        let withLiterals = try SourceCorpus.commentFree(of: url)
        #expect(withLiterals.contains(surface.key), "\(surface.file) lost its frame's key")
        #expect(
            code.contains("TransferFailureLabel.text(for: error)"),
            "\(surface.file) does not fill its frame from the app's label")
        #expect(
            !code.contains("TransferQueueViewModel.message(for: error)"),
            "\(surface.file) still formats Core's sentence into a localized frame")
    }

    /// The mapper translates — it reads `L10n` — and never describes a
    /// cause or interpolates one into a string.
    @Test func theMapperTranslatesAndNeverDescribesTheCause() throws {
        let strict = try SourceCorpus.code(of: Self.labelFile)
        let withLiterals = try SourceCorpus.commentFree(of: Self.labelFile)
        let bodyStrict = try TransferQueueBarCancelGuardTests.declarationBody(
            of: "static func label(_ cause: TransferFailureKind) -> String", in: strict)
        let bodyLiterals = try TransferQueueBarCancelGuardTests.declarationBody(
            of: "static func label(_ cause: TransferFailureKind) -> String", in: withLiterals)

        // Positives: the scanned body is the one that translates.
        #expect(bodyStrict.contains("L10n.string("), "label reads no catalogue")
        #expect(bodyStrict.contains("sentence(for: cause.name)"), "label classifies nothing")
        #expect(bodyLiterals.count == bodyStrict.count, "the two views lost their alignment")

        #expect(!bodyLiterals.contains("String(describing:"), "label describes a value")
        #expect(!bodyLiterals.contains("\\(cause"), "label interpolates the cause")
        #expect(!bodyLiterals.contains("\\(detail"), "label interpolates the detail")
    }
}
