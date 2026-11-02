import AppKit
import Foundation
import Testing
import macSCPCore

@testable import MacSCPAppKit

/// Which file-action rows the context menu offers, and what it says when it
/// declines one -- and the guard that every action the descriptors declare has
/// a title in every shipped language.
///
/// The menu cases build the real `NSMenu` through the table coordinator, with
/// no window and no running app (the way `RemoteFileTableTypeColumnGuardTests`
/// drives the coordinator's cell mapping). No test in this project draws a
/// view.
@Suite("File action availability")
struct FileActionAvailabilityTests {
    /// The four locales the app ships in; `en` is the source text.
    static let languages = ["en", "de", "fr", "pl"]

    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    /// One catalogue's text, read from the source tree like the guards that
    /// scan source, so it is the file that ships and not the test bundle's
    /// locale.
    private static func catalogue(_ language: String) throws -> String {
        try String(
            contentsOf: repoRoot.appendingPathComponent(
                "Sources/MacSCPAppKit/Resources/\(language).lproj/Localizable.strings"),
            encoding: .utf8)
    }

    /// Whether a catalogue's text carries an entry for `key`.
    private static func hasEntry(_ key: String, in text: String) -> Bool {
        text.contains("\"\(key)\" =")
    }

    /// Every file action any descriptor declares, once per descriptor entry.
    static let contributions: [FileActionContribution] =
        ConnectionKind.allCases.flatMap { BackendDescriptor.descriptor(for: $0).fileActions }

    private static var versionsAction: FileActionContribution? {
        BackendDescriptor.descriptor(for: .s3).fileActions.first {
            $0.id == VersionsRowAvailability.actionID
        }
    }

    // MARK: - The catalogue guard

    /// A `titleKey` with no entry falls back to the English `titleDefault` in
    /// de, fr and pl with every other test green. This runs over every
    /// contribution every descriptor declares, in every shipped language, as a
    /// positive `contains`, so a catalogue that loses an entry fails here and
    /// names the action and the language. The key is read off the
    /// contribution, never spelled.
    @Test(arguments: FileActionAvailabilityTests.contributions, FileActionAvailabilityTests.languages)
    func everyFileActionHasATitleInEveryLanguage(
        action: FileActionContribution, language: String
    ) throws {
        let text = try Self.catalogue(language)
        #expect(
            Self.hasEntry(action.titleKey, in: text),
            "no catalogue entry for \(action.id) (\(action.titleKey)) in \(language)")
    }

    /// The positive beside the guard above: it is not iterating nothing, it
    /// finds the entries that are there, and it does not find one that is not.
    @Test func theCatalogueGuardSeesWhatItShouldAndOnlyThat() throws {
        let s3 = BackendDescriptor.descriptor(for: .s3).fileActions
        #expect(Self.contributions.count >= s3.count)
        #expect(s3.count >= 4, "the S3 descriptor declares \(s3.count) file actions")
        #expect(s3.contains { $0.id == VersionsRowAvailability.actionID })
        #expect(Self.versionsAction != nil)
        let english = try Self.catalogue("en")
        for action in s3 {
            #expect(Self.hasEntry(action.titleKey, in: english), "\(action.titleKey)")
        }
        #expect(!Self.hasEntry("browser.action.\u{0}absent", in: english))
    }

    /// The reason a declined row gives is user-visible text too: four entries,
    /// and the German one addresses the reader as du if it addresses them at
    /// all.
    @Test(arguments: FileActionAvailabilityTests.languages)
    func theUnavailableReasonHasAnEntryInEveryLanguage(language: String) throws {
        let text = try Self.catalogue(language)
        #expect(
            Self.hasEntry(VersionsRowAvailability.neverVersionedReasonKey, in: text),
            "no entry for the reason key in \(language)")
    }

    // MARK: - The predicate

    /// All three states are spelled out: `.never` is the unavailable one, and
    /// a suspended bucket still has a history to show.
    @Test func onlyABucketThatWasNeverVersionedOffersNoHistory() {
        #expect(VersionsRowAvailability(versioning: .enabled).isAvailable == true)
        #expect(VersionsRowAvailability(versioning: .suspended).isAvailable == true)
        #expect(VersionsRowAvailability(versioning: .never).isAvailable == false)
        // Paired with a total, so a list that shrank to nothing is red.
        #expect(BucketVersioning.allCases.count == 3)
        for state in BucketVersioning.allCases {
            let availability = VersionsRowAvailability(versioning: state)
            #expect(availability.isAvailable == (availability.reasonKey == nil), "\(state)")
        }
    }

    @Test func theUnavailableOneCarriesTheReasonAndTheOthersCarryNone() {
        #expect(
            VersionsRowAvailability(versioning: .never).reasonKey
                == VersionsRowAvailability.neverVersionedReasonKey)
        #expect(VersionsRowAvailability(versioning: .enabled).reasonKey == nil)
        #expect(VersionsRowAvailability(versioning: .suspended).reasonKey == nil)
    }

    // MARK: - The menu

    private static let file = RemoteFileItem(
        name: "a.txt", path: "/bucket/a.txt", kind: .file)

    /// The menu the coordinator builds for one selected file on a remote S3
    /// pane, with the availability closures a caller would hand the table.
    @MainActor
    private static func menu(
        availability: BucketVersioning?, supplyClosures: Bool = true
    ) -> NSMenu {
        let coordinator = RemoteFileTableView.Coordinator(
            onOpen: { _ in }, onSelect: { _ in }, side: .remote)
        coordinator.items = [file]
        let actions = BackendDescriptor.descriptor(for: .s3).fileActions
        coordinator.fileActions = { actions }
        if supplyClosures, let availability {
            let verdict = VersionsRowAvailability(versioning: availability)
            coordinator.isFileActionAvailable = { action in
                action.id == VersionsRowAvailability.actionID ? verdict.isAvailable : true
            }
            coordinator.fileActionUnavailableReason = { action in
                action.id == VersionsRowAvailability.actionID
                    ? verdict.reasonKey.map { L10n.string($0, "") } : nil
            }
        }
        let menu = NSMenu()
        coordinator.populate(menu, selection: [file])
        return menu
    }

    private static func row(for action: FileActionContribution, in menu: NSMenu) -> NSMenuItem? {
        let title = L10n.string(action.titleKey, action.titleDefault)
        return menu.items.first { $0.title == title }
    }

    /// The row a bucket without versioning gets: present, disabled, with the
    /// reason as its tooltip -- and the rows beside it untouched.
    @MainActor @Test func aRowThatIsNotAvailableIsDisabledAndSaysWhy() throws {
        let menu = Self.menu(availability: .never)
        let versions = try #require(Self.versionsAction)
        // The positive: the row is in the menu at all, so the absences below
        // are about this row and not about a menu that never had it.
        let row = try #require(Self.row(for: versions, in: menu))
        #expect(row.isEnabled == false)
        // Nothing to fire, so the menu's own validation has nothing to switch
        // back on when it opens.
        #expect(row.action == nil)
        let reason = L10n.string(VersionsRowAvailability.neverVersionedReasonKey, "")
        #expect(!reason.isEmpty)
        #expect(row.toolTip == reason)
        // The other file actions are still live and still carry no tooltip.
        let others = BackendDescriptor.descriptor(for: .s3).fileActions.filter { $0.id != versions.id }
        #expect(!others.isEmpty)
        for other in others {
            let item = try #require(Self.row(for: other, in: menu), "\(other.id)")
            #expect(item.isEnabled == true, "\(other.id)")
            #expect(item.action != nil, "\(other.id)")
            #expect(item.toolTip == nil, "\(other.id)")
        }
    }

    /// An available row carries no tooltip: for each of the two states that
    /// offer the history. The positive (the row is there and live) is asserted
    /// before the absence.
    @MainActor @Test(arguments: [BucketVersioning.enabled, BucketVersioning.suspended])
    func anAvailableRowIsLiveAndCarriesNoTooltip(state: BucketVersioning) throws {
        let menu = Self.menu(availability: state)
        let versions = try #require(Self.versionsAction)
        let row = try #require(Self.row(for: versions, in: menu), "\(state)")
        #expect(row.isEnabled == true, "\(state)")
        #expect(row.action != nil, "\(state)")
        #expect(row.toolTip == nil, "\(state)")
    }

    /// A table that was handed no availability closures (every call site that
    /// predates them, and the local pane) draws every row as it always did.
    @MainActor @Test func withoutTheClosuresEveryRowIsLiveAsBefore() throws {
        let menu = Self.menu(availability: nil, supplyClosures: false)
        let actions = BackendDescriptor.descriptor(for: .s3).fileActions
        #expect(!actions.isEmpty)
        for action in actions {
            let item = try #require(Self.row(for: action, in: menu), "\(action.id)")
            #expect(item.isEnabled == true, "\(action.id)")
            #expect(item.toolTip == nil, "\(action.id)")
        }
    }

    /// The reason comes from the closure and is what the tooltip says, in
    /// every language: not a string the table composes itself.
    @MainActor @Test func theTooltipIsTheClosuresReasonInEachLanguage() throws {
        let versions = try #require(Self.versionsAction)
        var seen = Set<String>()
        for language in Self.languages {
            let reason = L10n.$localeOverride.withValue(language) {
                L10n.string(VersionsRowAvailability.neverVersionedReasonKey, "")
            }
            #expect(!reason.isEmpty, "\(language)")
            seen.insert(reason)
            let tip = L10n.$localeOverride.withValue(language) {
                Self.row(for: versions, in: Self.menu(availability: .never))?.toolTip
            }
            #expect(tip == reason, "\(language)")
        }
        #expect(seen.count == Self.languages.count, "four languages, four sentences")
    }
}
