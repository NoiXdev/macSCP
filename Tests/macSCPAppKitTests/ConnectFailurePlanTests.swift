import Foundation
import Testing
@testable import MacSCPAppKit
@testable import macSCPCore

/// Direct tests over `ConnectFailurePlan.content(hasStoredSession:)`
/// (failed-connect surface, Task 2) — the plain, testable decision behind
/// what a failed connect attempt says and which actions it offers.
/// Nothing in this project renders SwiftUI, so this cannot prove what lands
/// on screen; what it CAN prove, and does, is the mapping itself: the
/// headline stays fixed, and everything that depends on there being
/// something stored — the two actions `retryButton` and
/// `editSessionButton`, and since the maintainer's decision of 2026-08-25
/// the `body` sentence as well — turns together on the one fact the caller
/// supplies.
///
/// Mirrors `ReconnectPlanTests`' "LostConnectionPlan" section for the same
/// reason: a value that decides which actions appear can be wrong by
/// offering too many just as easily as too few, so both directions of
/// `hasStoredSession` are checked, plus the exhaustive catalog-key sweep
/// that pins the surface's structural safety (`ConnectFailureContent` has
/// no field a host name, a server message, or a form value could occupy —
/// see that type's own doc comment).
///
/// Task 3 added the details control's two keys and, with them, the check
/// that every key this plan produces is actually translated in all four
/// catalogs — a key set that is internally consistent and absent from the
/// catalogs renders as the raw key on screen, in every language.
@Suite("Connect failure plan")
struct ConnectFailurePlanTests {
    /// All four actions appear when the failed attempt started from a
    /// stored session. A test that only checked `editSessionButton` here
    /// would not catch a mutation that also dropped one of the other three
    /// under this same condition — so every button's key is asserted.
    @Test func allFourActionsAppearWithAStoredSession() {
        let content = ConnectFailurePlan.content(hasStoredSession: true)
        #expect(content.retryButton?.key == "connection.failed.retry")
        #expect(content.editButton.key == "connection.failed.edit")
        #expect(content.editSessionButton?.key == "connection.failed.editSession")
        #expect(content.closeButton.key == "connection.failed.close")
    }

    /// The other direction: an ad-hoc connection, never saved, has nothing
    /// stored to edit for good AND nothing stored to redial, so BOTH
    /// `editSessionButton` and `retryButton` are absent — while the two
    /// actions that make sense regardless are still there.
    ///
    /// `retryButton` joined `editSessionButton` in round 2, after review.
    /// Round 1 offered Retry unconditionally and had `retryConnect(_:)`
    /// hand an ad-hoc tab back to the form — the same call `onEdit` makes,
    /// so pressing "Erneut versuchen" produced the prefilled form and no
    /// dial at all, which is the behaviour this whole surface exists to
    /// stop. The alternative, a second ad-hoc dial site, is the thing the
    /// branch's security argument refuses.
    ///
    /// A mutation that swapped which `hasStoredSession` value turns these
    /// on fails BOTH this test and the one above: the one above asserts the
    /// keys are present, this one asserts they are absent, and an inversion
    /// violates each. (Task 2's own report claimed it would fail "exactly
    /// one of the two"; that was wrong, and the report has been corrected.)
    @Test func retryAndEditSessionAreAbsentForAnAdHocConnection() {
        let content = ConnectFailurePlan.content(hasStoredSession: false)
        #expect(content.editSessionButton == nil)
        #expect(content.retryButton == nil, """
            an ad-hoc failure has no stored session to redial, and there is deliberately no \
            second dial site to redial it with — so a Retry button here could only return the \
            user to the form, which is what Edit already does and what the maintainer \
            complained about in the first place.
            """)
        #expect(content.editButton.key == "connection.failed.edit")
        #expect(content.closeButton.key == "connection.failed.close")
    }

    /// The details control is offered whether or not a session is stored:
    /// the technical text of a failed dial is worth reading either way, and
    /// nothing about it depends on where the attempt came from.
    @Test(arguments: [true, false])
    func theDetailsControlIsOfferedEitherWay(hasStoredSession: Bool) {
        let content = ConnectFailurePlan.content(hasStoredSession: hasStoredSession)
        #expect(content.detailsButton.key == "connection.failed.details")
        #expect(content.detailsTitle.key == "connection.failed.details.title")
    }

    /// The headline is the same either way — what happened does not depend
    /// on where the attempt came from.
    ///
    /// Compares the whole `Message` values against each other, not just
    /// their keys: `Message` is `Equatable` over key AND fallback, so a
    /// version that kept one key and varied its English default with the
    /// flag is caught here. (The first version of this test compared only
    /// `.key`, which its own name did not claim and which would have let
    /// exactly that through.) The fixed key is asserted as well, so the
    /// test still fails if both sides change together.
    @Test func theHeadlineDoesNotDependOnWhetherASessionIsStored() {
        let stored = ConnectFailurePlan.content(hasStoredSession: true)
        let adHoc = ConnectFailurePlan.content(hasStoredSession: false)
        #expect(stored.title == adHoc.title)
        #expect(stored.title.key == "connection.failed.title")
    }

    /// The body, however, does depend on it — maintainer decision,
    /// 2026-08-25, recorded in the design spec.
    ///
    /// A stored-session failure keeps the plain line: Retry sits right
    /// there and needs no explanation. An ad-hoc failure has no Retry at
    /// all (see `retryAndEditSessionAreAbsentForAnAdHocConnection`), so its
    /// only way forward is a button labelled for EDITING — and a sentence
    /// that does not say so leaves someone hunting for a button that is not
    /// there.
    ///
    /// Asserts the two keys DIFFER rather than only spelling each one out:
    /// a mutation that dropped the branch and returned the general line for
    /// both cases keeps a key that is inside the fixed set, and would
    /// satisfy a test written as two independent lookups of whichever arm
    /// it kept.
    @Test func theBodyTellsAnAdHocFailureHowToGetBack() {
        let stored = ConnectFailurePlan.content(hasStoredSession: true)
        let adHoc = ConnectFailurePlan.content(hasStoredSession: false)
        #expect(stored.body.key != adHoc.body.key, """
            both cases now show the same sentence. The ad-hoc case has no Retry button, so \
            its body is the only thing that can say why "Edit" is the way to try again.
            """)
        #expect(stored.body.key == "connection.failed.body")
        #expect(adHoc.body.key == "connection.failed.body.adHoc")
        // The softening is of WHICH fixed key is chosen, never of the rule
        // that it is one — both bodies stay inside the enumerated set
        // `everyReachableMessageComesFromTheFixedCatalogKeySet` sweeps, so
        // an interpolated host name in either arm is still caught there.
        #expect(!adHoc.body.fallback.isEmpty)
    }

    /// Every message this plan can produce, across both `hasStoredSession`
    /// values. Shared by the key-set sweep and the catalog check below so
    /// the two cannot disagree about what "reachable" means.
    private static func everyReachableMessage() -> [ConnectFailureContent.Message] {
        [true, false].flatMap { hasStoredSession -> [ConnectFailureContent.Message] in
            let content = ConnectFailurePlan.content(hasStoredSession: hasStoredSession)
            return [
                content.title, content.body, content.editButton,
                content.closeButton, content.detailsButton, content.detailsTitle,
            ] + [content.retryButton, content.editSessionButton].compactMap { $0 }
        }
    }

    /// The structural safety property, checked the same way
    /// `ReconnectPlanTests.everyReachableMessageComesFromTheFixedCatalogKeySet`
    /// checks it for `LostConnectionContent`: every message this plan can
    /// produce, across both `hasStoredSession` values, must be one of a
    /// fixed, enumerated set of catalog keys. A future edit that
    /// interpolated a host name or a raw error string into any of them
    /// would have to invent a key outside this set, or change one of these
    /// strings, and either fails here.
    ///
    /// Nine keys, counted while writing this sentence: the title, the TWO
    /// bodies (stored and ad-hoc), the four action labels, and the details
    /// control's label and headline.
    ///
    /// The second body is exactly the kind of addition that makes this
    /// sweep worth keeping. `hasStoredSession` now selects a KEY rather
    /// than only toggling a button, and this claim — that every string
    /// reachable from the plan is one of an enumerated set of catalog
    /// entries, so no host name or server message can be interpolated into
    /// any of them — has to hold across both arms of that choice, not just
    /// the arm someone happened to look at. It was measured, not assumed:
    /// adding the second body turned this test red on both halves (an
    /// unknown key reached, and the two sets no longer equal) until the key
    /// was added below.
    @Test func everyReachableMessageComesFromTheFixedCatalogKeySet() {
        let allowedKeys: Set<String> = [
            "connection.failed.title",
            "connection.failed.body",
            "connection.failed.body.adHoc",
            "connection.failed.retry",
            "connection.failed.edit",
            "connection.failed.editSession",
            "connection.failed.close",
            "connection.failed.details",
            "connection.failed.details.title",
        ]
        var seen: Set<String> = []
        for message in Self.everyReachableMessage() {
            #expect(allowedKeys.contains(message.key), """
                `\(message.key)` is not one of the keys this surface is allowed \
                to show. Every string on the failed-connect surface must be a fixed \
                catalog entry, matching the design spec's rule for the surface's \
                sibling (`LostConnectionContent`).
                """)
            #expect(!message.fallback.isEmpty)
            seen.insert(message.key)
        }
        #expect(seen == allowedKeys, """
            the enumerated key set and the keys actually reachable from \
            `ConnectFailurePlan.content` have diverged: only \(seen.sorted()) were produced.
            """)
    }

    // MARK: - The catalogs

    /// `#filePath` is
    /// `<repoRoot>/Tests/macSCPAppKitTests/ConnectFailurePlanTests.swift`;
    /// three `deletingLastPathComponent()` calls recover the repo root
    /// regardless of `swift test`'s working directory.
    private static let catalogDirectory: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/MacSCPAppKit/Resources")

    /// Every language the App's catalog directory actually contains,
    /// discovered rather than listed: a hardcoded list would go stale in
    /// the silent direction — a language added later would simply never be
    /// checked for these keys.
    private static func locales() throws -> [String] {
        let contents = try FileManager.default.contentsOfDirectory(
            atPath: catalogDirectory.path(percentEncoded: false))
        return contents
            .filter { $0.hasSuffix(".lproj") }
            .map { String($0.dropLast(".lproj".count)) }
            .sorted()
    }

    private static func catalog(_ locale: String) throws -> [String: String] {
        let path = catalogDirectory
            .appendingPathComponent("\(locale).lproj")
            .appendingPathComponent("Localizable.strings")
            .path(percentEncoded: false)
        return try #require(
            NSDictionary(contentsOfFile: path) as? [String: String],
            "\(locale).lproj/Localizable.strings did not parse as a property list")
    }

    /// The gap the key-set sweep above cannot see, asked by looking at
    /// where the property could be violated FROM rather than at the plan
    /// alone: a key set that is perfectly self-consistent and simply absent
    /// from the catalogs. `L10n.string(key, fallback)` then renders the
    /// English fallback in every language and nothing goes red — the
    /// failure lands only in the languages nobody reviewing the change
    /// reads.
    ///
    /// `LocalizationParityTests` holds the catalogs to describing the same
    /// key set as each other; this holds them to describing the keys this
    /// plan actually produces. Neither implies the other: four catalogs can
    /// agree perfectly on a set that does not contain a single key of this
    /// surface.
    @Test func everyKeyThisPlanProducesIsTranslatedInEveryLanguage() throws {
        let locales = try Self.locales()
        #expect(locales.count >= 2, """
            only \(locales.count) language(s) found under Sources/MacSCPAppKit/Resources — \
            this check is not reading the catalogs it is meant to compare.
            """)
        #expect(locales.contains("en") && locales.contains("de"), """
            the default language and its German translation must both be among \(locales).
            """)

        for locale in locales {
            let entries = try Self.catalog(locale)
            for message in Self.everyReachableMessage() {
                let value = entries[message.key]
                #expect(value != nil, """
                    `\(message.key)` is missing from \(locale).lproj/Localizable.strings. \
                    A key the plan produces but no catalog declares renders as the English \
                    fallback in every language, silently.
                    """)
                #expect(value?.isEmpty == false, """
                    `\(message.key)` is empty in \(locale).lproj/Localizable.strings.
                    """)
            }
        }
    }

    /// German is written as German, not left at the English source text.
    /// The parity guard cannot see this — a translation that copied the
    /// English value has the right key and a non-empty value — and the four
    /// action labels are exactly the strings most likely to be waved
    /// through as "the same word anyway".
    @Test func theGermanCatalogActuallyTranslatesThisSurface() throws {
        let english = try Self.catalog("en")
        let german = try Self.catalog("de")
        // One key is excluded, and only one: `connection.failed.details`
        // reads "Details…" in German too, so an identical value there is a
        // translation rather than an omission. `connection.failed.details
        // .title` was excluded alongside it in round 1 without earning it —
        // "Verbindungsdetails" is not "Connection details", and a check
        // that skips a key it could make is a check that would not notice
        // that key going untranslated. Seven keys are checked, counted
        // while writing this sentence: the title, both bodies, the four
        // action labels and the details headline — nine reachable keys
        // less the one exclusion.
        let translated = Set(Self.everyReachableMessage().map(\.key)).subtracting([
            "connection.failed.details",
        ])
        #expect(translated.count == 8)
        for key in translated.sorted() {
            #expect(german[key] != english[key], """
                `\(key)` reads the same in German as in English \
                (\(german[key] ?? "<missing>")) — the German catalog has not been written \
                for this surface.
                """)
        }
    }
}

/// Direct tests over `ConnectFailureDetailText.read(from:)` (failed-connect
/// surface plan, Task 3) — where the details dialog's technical text comes
/// from.
///
/// This is the first surface on this branch that shows a raw error text at
/// all; every other one is safe by construction, carrying nothing but
/// catalog keys. What keeps it safe is that it shows the message
/// `ConnectionViewModel` published and nothing else — the text the
/// connection form has always shown, whose producing sites this branch's
/// groundwork task audited. So what these tests pin is not "the message is
/// clean" (that is a property of the sources, tested there) but the weaker
/// and checkable thing this reader is responsible for: what it carries is
/// the message, all of the message, and nothing besides.
///
/// **What these tests can and cannot see.** The string is `fileprivate` to
/// `ConnectFailureDetails.swift`, which is what makes rendering it on the
/// general surface a compile error — and it also means no test can read it
/// back and compare characters. So the claims below are made through
/// `Equatable`: two failures with the same message must be equal however
/// they differ otherwise, and two with different messages must not be. That
/// catches anything the reader MIXES IN (the field, a prefix, the state
/// itself) because such a thing varies where the message does not. It
/// cannot catch a transformation applied uniformly to every message — a
/// trim, say. `ReconnectWiringGuardTests`' sanctioned line
/// `return ConnectFailureDetailText(text: message)` is the check for that
/// one: the construction is pinned character for character.
@Suite("Connect failure details")
struct ConnectFailureDetailsTests {
    /// The field a failure carries is meaningful only to the on-screen form
    /// (see `ContentView.fillForm`); it must not reach the dialog. A reader
    /// that appended it would make these two unequal.
    @Test func theHighlightedFormFieldDoesNotReachTheDetails() {
        let message = "Connection to 10.0.0.9:22 timed out after 15 seconds."
        #expect(
            ConnectFailureDetailText.read(from: .failed(message: message, field: nil))
                == ConnectFailureDetailText.read(
                    from: .failed(message: message, field: .schema("SSHField.host"))))
    }

    /// And the message IS what it carries, so the test above is not
    /// satisfied by a reader that carries nothing at all: two failures that
    /// differ only in their message must not be equal.
    @Test func theMessageIsWhatTheDetailsCarry() {
        #expect(
            ConnectFailureDetailText.read(from: .failed(message: "timed out", field: nil))
                != ConnectFailureDetailText.read(
                    from: .failed(message: "connection refused", field: nil)))
    }

    /// No failure, nothing technical to show — and therefore no dialog to
    /// open. Both non-failure states are checked, so a reader that answered
    /// with an empty value for one of them, which would offer an empty
    /// dialog rather than none, is caught.
    @Test(arguments: [ConnectionViewModel.State.idle, .connecting])
    func aStateThatIsNotAFailureHasNoDetails(state: ConnectionViewModel.State) {
        #expect(ConnectFailureDetailText.read(from: state) == nil)
    }
}
