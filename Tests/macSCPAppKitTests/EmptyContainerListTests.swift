import Foundation
import MacSCPTestSupport
import Testing
import macSCPCore

@testable import MacSCPAppKit

/// The empty state of a pane standing at a list of containers with nothing in
/// it: when it is shown, what it says, and that the pane and its owner are
/// wired to it.
///
/// F3 of the final whole-branch review: an account with no buckets now
/// connects -- Task 6 removed the refusal that stopped it -- and reached
/// `.loaded` with zero rows, where `BrowserPane` drew nothing at all.
///
/// No test here draws a SwiftUI view. The decision is a `nonisolated static`
/// so it can be exercised without a window, the catalogue is read through
/// `L10n`, and the wiring is a scan of COMMENT-FREE source, because a comment
/// quoting the code it describes is indistinguishable from that code to a
/// scanner (CLAUDE.md, "Source-scanning guards read comments too").
@Suite("Empty container list")
struct EmptyContainerListTests {
    /// The four locales the app ships in; `en` is the source text.
    private static let locales = ["en", "de", "fr", "pl"]

    private static func bucketList(at path: String = "/") -> BrowserScope {
        BrowserScope(rootIsContainerList: true, currentPath: path)
    }

    // MARK: - When it is shown

    @MainActor @Test func anAccountWithNoBucketsGetsTheNotice() {
        #expect(
            EmptyContainerListView.isShown(
                scope: Self.bucketList(), state: .loaded, listedItemCount: 0))
    }

    /// The negatives, each with the positive above as its control. A listing
    /// that holds buckets, a listing still arriving, a listing that failed, a
    /// connection whose root is not a list of containers, and a pane standing
    /// INSIDE a bucket -- where an empty listing means an empty bucket, and
    /// the action this notice offers is not even available
    /// (`ConnectionActionRoute.createBucket`).
    @MainActor @Test func nothingElseGetsIt() {
        #expect(
            EmptyContainerListView.isShown(
                scope: Self.bucketList(), state: .loaded, listedItemCount: 1) == false)
        #expect(
            EmptyContainerListView.isShown(
                scope: Self.bucketList(), state: .loading, listedItemCount: 0) == false)
        #expect(
            EmptyContainerListView.isShown(
                scope: Self.bucketList(), state: .failed(message: "no"), listedItemCount: 0)
                == false)
        #expect(
            EmptyContainerListView.isShown(
                scope: .ordinary, state: .loaded, listedItemCount: 0) == false)
        #expect(
            EmptyContainerListView.isShown(
                scope: Self.bucketList(at: "/macscp-seed"), state: .loaded, listedItemCount: 0)
                == false)
    }

    /// The notice appears exactly where the action it offers is available.
    /// Both read `BrowserScope.isContainerListRoot`'s question rather than
    /// each deciding it, so a notice over a pane with no Create Bucket row is
    /// not a state either of them can reach.
    @MainActor @Test func itAppearsOnlyWhereTheActionItOffersIsAvailable() {
        for path in ["/", "/macscp-seed", "/macscp-seed/reports"] {
            let scope = Self.bucketList(at: path)
            let shown = EmptyContainerListView.isShown(
                scope: scope, state: .loaded, listedItemCount: 0)
            let offered = CreateBucketModel.isOffered(
                rootIsContainerList: scope.rootIsContainerList,
                paneBucket: path == "/" ? nil : "macscp-seed")
            #expect(shown == offered, "\(path)")
        }
    }

    // MARK: - The catalogue

    @MainActor @Test func everyLineResolvesInAllFourLocales() {
        let sentinel = "ZZ-UNRESOLVED-ZZ"
        let lines = EmptyContainerListView.allLines
        for line in lines {
            for locale in Self.locales {
                let resolved = L10n.$localeOverride.withValue(locale) {
                    L10n.string(line.key, sentinel)
                }
                #expect(resolved != sentinel, "\(line.key) in \(locale)")
                #expect(!resolved.isEmpty)
            }
        }
        #expect(lines.count == 2)
    }

    @MainActor @Test func theEnglishCatalogueSaysTheDefault() {
        for line in EmptyContainerListView.allLines {
            let english = L10n.$localeOverride.withValue("en") {
                L10n.string(line.key, "ZZ-UNRESOLVED-ZZ")
            }
            #expect(english == line.english, "\(line.key)")
        }
    }

    /// The title and the sentence under it are two different things to read,
    /// in every language: a heading repeated as its own body says nothing
    /// twice.
    @MainActor @Test func theTitleAndTheSentenceDoNotSayTheSameThing() {
        for locale in Self.locales {
            let (title, body) = L10n.$localeOverride.withValue(locale) {
                (EmptyContainerListView.titleLine.text, EmptyContainerListView.bodyLine.text)
            }
            #expect(title != body, "\(locale)")
            #expect(!title.isEmpty)
            #expect(!body.isEmpty)
        }
    }

    /// Every key this view names is one the catalogue checks above cover, so
    /// a key added to the view and not to `allLines` is red rather than
    /// unmeasured. Read from comment-free source, so the list in the doc
    /// comment cannot stand in for the code.
    @MainActor @Test func everyKeyTheViewUsesIsOneTheCatalogueChecksCover() throws {
        let source = try SourceCorpus.commentFree(
            of: SourceCorpus.url(of: .sources)
                .appendingPathComponent("MacSCPAppKit/EmptyContainerListView.swift"))
        let used = Set(
            source.matches(of: #/"(browser\.pane\.[^"]+)"/#).map { String($0.output.1) })
        #expect(used.count > 0)
        let covered = Set(EmptyContainerListView.allLines.map(\.key))
        #expect(used.subtracting(covered).sorted() == [])
    }

    // MARK: - Wiring

    private static func commentFree(_ relativePath: String) throws -> String {
        try SourceCorpus.commentFree(
            of: SourceCorpus.url(of: .sources).appendingPathComponent(relativePath))
    }

    /// **The red this fix was measured against.** The pane drew an overlay
    /// for `.loading` and for `.failed` and had no arm for a loaded container
    /// list with nothing in it, so a zero-bucket account looked at an empty
    /// table. This asserts the arm exists and asks the rule rather than
    /// re-deciding it.
    @Test func thePaneDrawsTheNoticeAndAsksTheRuleForIt() throws {
        let pane = try Self.commentFree("MacSCPAppKit/BrowserPane.swift")
        #expect(pane.contains("EmptyContainerListView.isShown("))
        #expect(pane.contains("EmptyContainerListView("))
        // The count is the unfiltered listing's, not the searched one's: a
        // search matching no bucket is not an account without any.
        #expect(pane.contains("listedItemCount: viewModel.listedItems.count"))
        // The positive control for all three: the scan is reading the pane's
        // source and not an empty string.
        #expect(pane.contains("struct BrowserPane"))
    }

    /// The button goes through the menu's own route. Not a second place that
    /// builds the sheet: the contribution is looked up in the backend's
    /// descriptor and handed to `handleConnectionAction`, which re-asks
    /// availability and constructs the sheet, so the rule and the sheet are
    /// each spelled once.
    @Test func theButtonIsRoutedThroughTheConnectionAction() throws {
        let actions = try Self.commentFree("MacSCPAppKit/ContentView+MenuActions.swift")
        #expect(actions.contains("func openCreateContainerSheet("))
        #expect(actions.contains("handleConnectionAction("))
        #expect(actions.contains("ConnectionActionRoute(action: $0) == .createBucket"))
        let detail = try Self.commentFree("MacSCPAppKit/ContentView+Detail.swift")
        #expect(detail.contains("onCreateContainer:"))
        #expect(detail.contains("openCreateContainerSheet("))
        // The positive control: the scans are reading the right files.
        #expect(actions.contains("func handleConnectionAction("))
        #expect(detail.contains("BrowserPane("))
    }

    /// The LOCAL pane routes nothing here, so its notice could never offer a
    /// button -- and `LocalFileSystem` takes `rootIsContainerList == false`,
    /// so it never shows the notice at all. Both halves, because either one
    /// alone would be a reason that could expire.
    @Test func theLocalPaneIsNotOfferedTheAction() throws {
        let detail = try Self.commentFree("MacSCPAppKit/ContentView+Detail.swift")
        let remote = try #require(detail.range(of: "viewModel: session.remote"))
        let local = try #require(detail.range(of: "viewModel: session.local"))
        #expect(local.lowerBound < remote.lowerBound, "the panes are built local first")
        let localBlock = String(detail[local.lowerBound..<remote.lowerBound])
        #expect(localBlock.contains("onCreateContainer:") == false)
        // The positive control: the remote half DOES carry it, so the
        // negative check above is not reading a file that lost the name.
        let remoteBlock = String(detail[remote.lowerBound...])
        #expect(remoteBlock.contains("onCreateContainer:"))
    }
}
