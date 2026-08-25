import Foundation
import Testing
@testable import MacSCPAppKit
@testable import macSCPCore

/// Direct tests over `ConnectFailurePlan.content(hasStoredSession:)`
/// (failed-connect surface, Task 2) — the plain, testable decision behind
/// what a failed connect attempt says and which actions it offers.
/// Nothing in this project renders SwiftUI, so this cannot prove what lands
/// on screen; what it CAN prove, and does, is the mapping itself: the
/// general message stays fixed, and exactly one of the actions
/// (`editSessionButton`) toggles on the one fact the caller supplies.
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
        #expect(content.retryButton.key == "connection.failed.retry")
        #expect(content.editButton.key == "connection.failed.edit")
        #expect(content.editSessionButton?.key == "connection.failed.editSession")
        #expect(content.closeButton.key == "connection.failed.close")
    }

    /// The other direction: an ad-hoc connection, never saved, has nothing
    /// stored to edit for good — `editSessionButton` is absent — while the
    /// three actions that make sense regardless are still there. A mutation
    /// that swapped which `hasStoredSession` value turns `editSessionButton`
    /// on fails BOTH this test and the one above: the one above asserts the
    /// key is present, this one asserts it is absent, and an inversion
    /// violates each. (Task 2's own report claimed it would fail "exactly
    /// one of the two"; that was wrong, and the report has been corrected.)
    @Test func editSessionIsAbsentForAnAdHocConnection() {
        let content = ConnectFailurePlan.content(hasStoredSession: false)
        #expect(content.editSessionButton == nil)
        #expect(content.retryButton.key == "connection.failed.retry")
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

    /// The design spec's own point: the surface carries one general
    /// message, not one text per case. Whether the attempt started from a
    /// stored session must not change the title or body — only which
    /// actions are offered changes.
    ///
    /// Compares the whole `Message` values against each other, not just
    /// their keys: `Message` is `Equatable` over key AND fallback, so a
    /// version that kept one key and varied its English default with the
    /// flag is caught here. (The first version of this test compared only
    /// `.key`, which its own name did not claim and which would have let
    /// exactly that through.) The two fixed keys are asserted as well, so
    /// the test still fails if BOTH sides change together.
    @Test func theGeneralMessageDoesNotDependOnWhetherASessionIsStored() {
        let stored = ConnectFailurePlan.content(hasStoredSession: true)
        let adHoc = ConnectFailurePlan.content(hasStoredSession: false)
        #expect(stored.title == adHoc.title)
        #expect(stored.body == adHoc.body)
        #expect(stored.title.key == "connection.failed.title")
        #expect(stored.body.key == "connection.failed.body")
    }

    /// Every message this plan can produce, across both `hasStoredSession`
    /// values. Shared by the key-set sweep and the catalog check below so
    /// the two cannot disagree about what "reachable" means.
    private static func everyReachableMessage() -> [ConnectFailureContent.Message] {
        [true, false].flatMap { hasStoredSession -> [ConnectFailureContent.Message] in
            let content = ConnectFailurePlan.content(hasStoredSession: hasStoredSession)
            return [
                content.title, content.body, content.retryButton, content.editButton,
                content.closeButton, content.detailsButton, content.detailsTitle,
            ] + [content.editSessionButton].compactMap { $0 }
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
    /// Eight keys, counted while writing this sentence: title, body, the
    /// four action labels, and the details control's label and headline.
    @Test func everyReachableMessageComesFromTheFixedCatalogKeySet() {
        let allowedKeys: Set<String> = [
            "connection.failed.title",
            "connection.failed.body",
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
        // The details control is deliberately excluded: "Details" is the
        // German word too, so an identical value there is a translation,
        // not an omission. Six keys are checked, counted while writing this
        // sentence: title, body and the four action labels.
        let translated = Set(Self.everyReachableMessage().map(\.key)).subtracting([
            "connection.failed.details", "connection.failed.details.title",
        ])
        #expect(translated.count == 6)
        for key in translated.sorted() {
            #expect(german[key] != english[key], """
                `\(key)` reads the same in German as in English \
                (\(german[key] ?? "<missing>")) — the German catalog has not been written \
                for this surface.
                """)
        }
    }
}

/// Direct tests over `ConnectFailureDetails.text(for:)` (failed-connect
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
/// and checkable thing this function is responsible for: it passes that
/// message through unchanged and cannot reach past it.
@Suite("Connect failure details")
struct ConnectFailureDetailsTests {
    /// Byte-for-byte the published message: not trimmed, not prefixed with
    /// a headline, not wrapped in a "Details:" label. Anything added here
    /// would be text no audit of the producing sites ever covered.
    @Test func theDetailsTextIsThePublishedMessageUnchanged() {
        let published = "Connection to 10.0.0.9:22 timed out after 15 seconds."
        #expect(
            ConnectFailureDetails.text(for: .failed(message: published, field: nil))
                == published)
    }

    /// The field a failure carries is meaningful only to the on-screen form
    /// (see `ContentView.fillForm`); it must not change what the dialog
    /// shows, and must not leak into it.
    @Test func theHighlightedFormFieldDoesNotChangeTheText() {
        let published = "Authentication failed."
        #expect(
            ConnectFailureDetails.text(
                for: .failed(message: published, field: .schema("SSHField.host")))
                == published)
    }

    /// No failure, nothing technical to show — and therefore no dialog to
    /// open. Both non-failure states are checked, so a mutation that
    /// answered with an empty string for one of them, which would offer an
    /// empty dialog rather than none, is caught.
    @Test(arguments: [ConnectionViewModel.State.idle, .connecting])
    func aStateThatIsNotAFailureHasNoDetails(state: ConnectionViewModel.State) {
        #expect(ConnectFailureDetails.text(for: state) == nil)
    }
}
