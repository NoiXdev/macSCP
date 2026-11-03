import Foundation
import MacSCPTestSupport
import Testing
import macSCPCore

@testable import MacSCPAppKit

/// The browser's "show deleted files" switch and the row action that undoes a
/// delete (S3 version history, Task 10): what the switch changes about what is
/// FETCHED, where it has nothing to do, and what a restore sends.
///
/// Every request count here is read off `ListingCounters`, the one stub that
/// counts a plain listing, a deleted-key listing and a marker removal alike.
/// A zero is asserted only beside a count of the same stub that is not zero.
@Suite("Show deleted files", .timeLimit(.minutes(5)))
@MainActor
struct ShowDeletedFilesTests {
    // MARK: Fixtures

    nonisolated private static let day = Date(timeIntervalSince1970: 1_700_000_000)

    nonisolated private static let versionedTree: [String: [RemoteFileItem]] = [
        "/": [RemoteFileItem(name: "bucket", path: "/bucket", kind: .directory, isBucket: true)],
        "/bucket": [RemoteFileItem(name: "docs", path: "/bucket/docs", kind: .directory)],
        "/bucket/docs": [
            RemoteFileItem(name: "kept.txt", path: "/bucket/docs/kept.txt", kind: .file, size: 3)
        ],
    ]

    nonisolated private static func deletedEntry() -> DeletedEntry {
        DeletedEntry(key: "docs/gone.txt", markerVersionId: "m-1", modifiedAt: day)
    }

    /// One pane over a history-keeping file system, with the real source in
    /// front of a versioning cache whose bucket state is `versioning`.
    @MainActor
    private struct Pane {
        let counters = ListingCounters()
        let settings: FakeBucketSettings
        let cache: BucketVersioningCache
        let fs: HistoryListingFS
        let source: S3DeletedFileSource
        let vm: RemoteBrowserViewModel

        init(
            versioning: BucketVersioning = .enabled, readError: (any Error)? = nil,
            rootIsContainerList: Bool = true, configuredBucket: String = "", at path: String = "/bucket/docs"
        ) {
            settings = FakeBucketSettings(versioning: versioning, readError: readError)
            cache = BucketVersioningCache(settings: settings)
            fs = HistoryListingFS(
                counters: counters, tree: ShowDeletedFilesTests.versionedTree,
                rootIsContainerList: rootIsContainerList)
            counters.setDeleted([ShowDeletedFilesTests.deletedEntry()], underPrefix: "docs/")
            source = S3DeletedFileSource(
                provider: fs, rootIsContainerList: rootIsContainerList,
                configuredBucket: { configuredBucket }, versioning: cache)
            vm = RemoteBrowserViewModel(fs: fs, startPath: path)
            vm.deletedFileSource = source
        }
    }

    // MARK: The row

    @Test func aDeletedKeyBecomesARowCarryingItsMarkerVersionId() async {
        let pane = Pane()
        pane.vm.showDeletedFiles = true
        await pane.vm.load()
        let row = pane.vm.items.first { $0.isDeleted }
        #expect(row?.name == "gone.txt")
        #expect(row?.path == "/bucket/docs/gone.txt")
        #expect(row?.deleteMarkerVersionID == "m-1")
        #expect(row?.modifiedAt == Self.day)
        #expect(pane.vm.items.map(\.name).contains("kept.txt"))
        #expect(pane.vm.items.first { $0.name == "kept.txt" }?.isDeleted == false)
        // The request that produced it named the bucket and the folder's key.
        #expect(pane.counters.deleted == [ListingCounters.DeletedListing(bucket: "bucket", prefix: "docs/")])
    }

    // MARK: What the switch changes

    @Test func theSwitchChangesWhatIsFetchedAndNotOnlyWhatIsShown() async {
        let off = Pane()
        await off.vm.load()
        // Off: ONE request, the plain listing, and no deleted row anywhere.
        #expect(off.counters.plain == ["/bucket/docs"])
        #expect(off.counters.deleted.isEmpty)
        #expect(off.vm.items.contains { $0.isDeleted } == false)

        let on = Pane()
        on.vm.showDeletedFiles = true
        await on.vm.load()
        // On: a SECOND request, for the deleted keys, beside the same plain one.
        #expect(on.counters.plain == ["/bucket/docs"])
        #expect(on.counters.deleted.count == 1)
        #expect(on.vm.items.contains { $0.isDeleted })

        // `showHiddenFiles` is the other kind of switch: it changes what is
        // shown and nothing about what is asked of the store.
        let hidden = Pane()
        hidden.vm.showHiddenFiles = true
        await hidden.vm.load()
        #expect(hidden.counters.deleted.isEmpty)
    }

    @Test func turningTheSwitchOnInAVersionedBucketListsTheDeletedKeysAndOffNeedsNoRequest() async {
        let pane = Pane()
        await pane.vm.load()
        #expect(pane.counters.deleted.isEmpty)
        await pane.vm.setShowDeletedFiles(true)
        #expect(pane.vm.items.contains { $0.isDeleted })
        #expect(pane.counters.plain.count == 2)
        #expect(pane.counters.deleted.count == 1)
        await pane.vm.setShowDeletedFiles(false)
        #expect(pane.vm.items.contains { $0.isDeleted } == false)
        #expect(pane.counters.plain.count == 2)
        #expect(pane.counters.deleted.count == 1)
    }

    @Test func aSuspendedBucketStillHasDeletedFilesToShow() async {
        let pane = Pane(versioning: .suspended)
        pane.vm.showDeletedFiles = true
        await pane.vm.load()
        #expect(pane.vm.items.contains { $0.isDeleted })
    }

    // MARK: Where the switch cannot apply

    /// The four places the switch has nothing to do. Each is a pane over the
    /// counting stub, toggled, and each ends by listing once more on the same
    /// stub, so the zero in the middle is a count of a stub that counts.
    enum CannotApply: CaseIterable, Sendable, CustomTestStringConvertible {
        case localPane, nonS3Backend, bucketListRoot, versioningOff
        var testDescription: String {
            switch self {
            case .localPane: "local pane"
            case .nonS3Backend: "non-S3 backend"
            case .bucketListRoot: "bucket-list root"
            case .versioningOff: "versioning off"
            }
        }
    }

    @Test(arguments: CannotApply.allCases)
    func togglingWhereItCannotApplyNeitherReListsNorErrors(place: CannotApply) async throws {
        let counters = ListingCounters()
        // EVERY case holds a settings stub and a versioning cache over it, so
        // that the versioning-read assertion below compares two real lists
        // and not `nil == nil`, and ends with a read the stub counts.
        let seeded: BucketVersioning = place == .versioningOff ? .never : .enabled
        let settings = FakeBucketSettings(versioning: seeded)
        let cache = BucketVersioningCache(settings: settings)
        let vm: RemoteBrowserViewModel
        switch place {
        case .localPane:
            // The real local file system has no history, so no source is made.
            #expect(
                S3DeletedFileSource.make(
                    for: LocalFileSystem(), versioning: cache, configuredBucket: { "" }) == nil)
            vm = RemoteBrowserViewModel(
                fs: PlainListingFS(counters: counters, tree: Self.versionedTree), startPath: "/bucket/docs")
        case .nonS3Backend:
            let fs = PlainListingFS(counters: counters, tree: Self.versionedTree)
            let source = S3DeletedFileSource.make(for: fs, versioning: cache, configuredBucket: { "" })
            #expect(source == nil)
            vm = RemoteBrowserViewModel(fs: fs, startPath: "/bucket/docs")
            vm.deletedFileSource = source
        case .bucketListRoot:
            let fs = HistoryListingFS(
                counters: counters, tree: Self.versionedTree, rootIsContainerList: true)
            let made = S3DeletedFileSource.make(for: fs, versioning: cache, configuredBucket: { "" })
            let source = try #require(made)
            vm = RemoteBrowserViewModel(fs: fs, startPath: "/")
            vm.deletedFileSource = source
        case .versioningOff:
            // Read earlier in the session, as the menu or a sheet would have.
            #expect(try await cache.versioning("bucket") == .never)
            let fs = HistoryListingFS(
                counters: counters, tree: Self.versionedTree, rootIsContainerList: true)
            let made = S3DeletedFileSource.make(for: fs, versioning: cache, configuredBucket: { "" })
            let source = try #require(made)
            vm = RemoteBrowserViewModel(fs: fs, startPath: "/bucket/docs")
            vm.deletedFileSource = source
        }
        counters.setDeleted([Self.deletedEntry()], underPrefix: "docs/")
        await vm.load()
        let itemsBefore = vm.items
        let plainBefore = counters.plain.count
        let readsBefore = settings.reads
        // Only the versioning-off case read before the toggle (the seed).
        #expect(readsBefore == (place == .versioningOff ? ["bucket"] : []))

        await vm.setShowDeletedFiles(true)

        // Zero extra requests of any kind, state unchanged, nothing said.
        #expect(counters.plain.count == plainBefore)
        #expect(counters.deleted.isEmpty)
        #expect(settings.reads == readsBefore)
        #expect(vm.items == itemsBefore)
        #expect(vm.state == .loaded)
        let keptNoError = vm.lastLoadError == nil
        #expect(keptNoError)
        #expect(vm.deletedFilesNotice == nil)

        // The positives beside the zeros: this stub counts a listing, and with
        // the switch on a listing here still shows no deleted row...
        await vm.load()
        #expect(counters.plain.count == plainBefore + 1)
        #expect(counters.deleted.isEmpty)
        #expect(vm.items.contains { $0.isDeleted } == false)
        // ...and this settings stub counts a versioning read: the cache asked
        // for a bucket nobody has read yet adds exactly one to the list.
        _ = try await cache.versioning("other-bucket")
        #expect(settings.reads == readsBefore + ["other-bucket"])
    }

    /// The positive control for the table above, on the same stub and the same
    /// source: with the bucket versioned, the very same toggle makes both
    /// requests. Without it the four zeros could be a stub nobody reached.
    @Test func theSameToggleInAVersionedBucketIsCounted() async {
        let pane = Pane()
        await pane.vm.load()
        let before = pane.counters.plain.count
        #expect(pane.settings.reads.isEmpty)
        await pane.vm.setShowDeletedFiles(true)
        #expect(pane.counters.plain.count == before + 1)
        #expect(pane.counters.deleted.count == 1)
        // And the toggle is what asked the store about versioning: once.
        #expect(pane.settings.reads == ["bucket"])
    }

    // MARK: A state that was not read is not a state that was

    @Test func versioningThatCannotBeReadIsSaidToBeUnconfirmedAndNotOff() async {
        let pane = Pane(readError: RemoteFSError.finding(.operationNotSupported))
        await pane.vm.load()
        let before = pane.counters.plain.count
        await pane.vm.setShowDeletedFiles(true)
        #expect(pane.vm.deletedFilesNotice == .versioningNotConfirmed)
        #expect(pane.counters.plain.count == before)
        #expect(pane.counters.deleted.isEmpty)
        // And a load with the switch on says it too, with the plain rows kept.
        await pane.vm.load()
        #expect(pane.vm.deletedFilesNotice == .versioningNotConfirmed)
        #expect(pane.vm.items.map(\.name) == ["kept.txt"])
        // The sentence is the unconfirmed one, and none of the "off" ones.
        let line = DeletedFilesNotice.versioningNotConfirmed.line
        #expect(line.english.contains("could not confirm"))
        #expect(line.english.contains("never") == false)
    }

    @Test func aConnectionWithNoVersioningCacheCannotConfirmEither() async {
        let counters = ListingCounters()
        let fs = HistoryListingFS(counters: counters, tree: Self.versionedTree, rootIsContainerList: true)
        let source = S3DeletedFileSource(
            provider: fs, rootIsContainerList: true, configuredBucket: { "" }, versioning: nil)
        #expect(await source.availability(inDirectory: "/bucket/docs") == .notConfirmed)
        #expect(counters.deleted.isEmpty)
    }

    // MARK: A failing request is not repeated by every silent refresh

    /// The auto-refresh calls `refreshQuietly()` every few seconds.
    /// `BucketVersioningCache` rightly keeps no failure, so before the pane
    /// stopped asking, a bucket whose `GET ?versioning` failed cost one failing
    /// request per tick for as long as the pane sat there.
    @Test func aFailingVersioningReadIsNotRetriedByEveryAutoRefresh() async {
        let pane = Pane(readError: RemoteFSError.finding(.operationNotSupported))
        pane.vm.showDeletedFiles = true
        await pane.vm.load()
        // Positive: the stub counts the one read the load made.
        #expect(pane.settings.reads == ["bucket"])
        for _ in 0..<5 { await pane.vm.refreshQuietly() }
        #expect(pane.settings.reads == ["bucket"])
        // The silent refresh still does its own job: it listed each time.
        #expect(pane.counters.plain.count == 6)
        // A manual refresh asks again, and the stub counts it.
        await pane.vm.refresh()
        #expect(pane.settings.reads == ["bucket", "bucket"])
    }

    @Test func aFailingDeletedListingIsNotRetriedByEveryAutoRefresh() async {
        let pane = Pane()
        pane.counters.setDeletedError(RemoteFSError.finding(.operationNotSupported))
        pane.vm.showDeletedFiles = true
        await pane.vm.load()
        #expect(pane.counters.deleted.count == 1)
        for _ in 0..<5 { await pane.vm.refreshQuietly() }
        #expect(pane.counters.deleted.count == 1)
        await pane.vm.refresh()
        #expect(pane.counters.deleted.count == 2)
    }

    /// The containment must not reach the healthy path: with nothing failing,
    /// every tick asks for the deleted keys, which is what keeps a row that
    /// someone else restored from lingering.
    @Test func aHealthyAutoRefreshStillAsksForTheDeletedKeysEveryTime() async {
        let pane = Pane()
        pane.vm.showDeletedFiles = true
        await pane.vm.load()
        for _ in 0..<3 { await pane.vm.refreshQuietly() }
        #expect(pane.counters.deleted.count == 4)
        #expect(pane.settings.reads == ["bucket"])
    }

    // MARK: Which bucket and which folder

    @Test(arguments: [
        // (directory, rootIsContainerList, configured bucket, bucket, prefix)
        ("/b", true, "", "b", ""),
        ("/b/docs", true, "", "b", "docs/"),
        ("/b/docs/2026//", true, "", "b", "docs/2026/"),
        ("/", false, "mine", "mine", ""),
        ("/docs", false, "mine", "mine", "docs/"),
        ("/docs/2026", false, " mine ", "mine", "docs/2026/"),
    ])
    func aDirectoryIsAFolderOfOneBucket(
        directory: String, container: Bool, configured: String, bucket: String, prefix: String
    ) {
        let location = S3DeletedFileSource.location(
            ofDirectory: directory, rootIsContainerList: container, configuredBucket: configured)
        #expect(location?.bucket == bucket)
        #expect(location?.keyPrefix == prefix)
    }

    @Test func thereIsNoBucketAtTheBucketListOrWithNoneConfigured() {
        #expect(
            S3DeletedFileSource.location(
                ofDirectory: "/", rootIsContainerList: true, configuredBucket: "") == nil)
        #expect(
            S3DeletedFileSource.location(
                ofDirectory: "/docs", rootIsContainerList: false, configuredBucket: "  ") == nil)
    }

    // MARK: A deleted listing that fails

    @Test func aFailedDeletedListingKeepsThePlainRowsAndSaysSoWithoutQuotingTheStore() async {
        let pane = Pane()
        let canary = "https://AKIACANARYKEY:SECRETCANARY@store.invalid"
        pane.counters.setDeletedError(RemoteFSError.protocolError(reason: canary))
        pane.vm.showDeletedFiles = true
        await pane.vm.load()
        #expect(pane.counters.deleted.count == 1)
        #expect(pane.vm.state == .loaded)
        #expect(pane.vm.items.map(\.name) == ["kept.txt"])
        #expect(pane.vm.deletedFilesNotice == .listingFailed)
        // Computed first: the error value this pane might have kept carries the canary.
        let keptNoError = pane.vm.lastLoadError == nil
        #expect(keptNoError)
        let shown = DeletedFilesNotice.listingFailed.line.text
        let leaked = shown.contains("SECRETCANARY") || shown.contains("AKIACANARYKEY")
        #expect(leaked == false)
    }

    // MARK: The restore

    private struct Trail {
        let recorder: AuditRecorder
        let directory: URL
        let store: AuditLogStore
        let sessionID = UUID()

        init() {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("ShowDeletedFilesTests-\(UUID().uuidString)", isDirectory: true)
            store = AuditLogStore(directory: directory)
            recorder = AuditRecorder(sessionID: sessionID, store: store)
        }

        var events: [AuditEvent] { store.events(for: sessionID) }
        func remove() { try? FileManager.default.removeItem(at: directory) }
    }

    private func context(
        container: Bool = true, bucket: String = ""
    ) -> ConnectionActionContext {
        ConnectionActionContext(
            settings: nil, rootIsContainerList: container, remotePath: "/bucket/docs",
            configuredBucket: bucket)
    }

    private func deletedRow(in pane: Pane) async throws -> RemoteFileItem {
        pane.vm.showDeletedFiles = true
        await pane.vm.load()
        return try #require(pane.vm.items.first { $0.isDeleted })
    }

    @Test func restoringFromTheBrowserRowUsesTheMarkerIdTheRowCarries() async throws {
        let pane = Pane()
        let row = try await deletedRow(in: pane)
        let plainBefore = pane.counters.plain.count
        let deletedBefore = pane.counters.deleted.count
        let trail = Trail()
        defer { trail.remove() }

        let notice = await DeletedFileRestorer(provider: pane.fs, recorder: trail.recorder)
            .restore([row], in: context())

        #expect(notice == nil)
        // One DELETE, with the id the row carried; no GET of any kind: no
        // second deleted listing, no plain listing, no per-key history read.
        #expect(
            pane.counters.lifts == [
                ListingCounters.Lift(key: "docs/gone.txt", bucket: "bucket", markerVersionId: "m-1")
            ])
        #expect(pane.counters.plain.count == plainBefore)
        #expect(pane.counters.deleted.count == deletedBefore)
        #expect(pane.counters.versionHistoryReads == 0)
        // And the trail has the third kind of version write, done.
        #expect(trail.events.map(\.kind) == [.deleteMarkerLifted])
        #expect(trail.events.first?.isError == false)
        #expect(trail.events.first?.detail.contains("m-1") == true)
    }

    /// What each way a lift can end says, and that the trail says the same
    /// fixed sentence and none of the store's words.
    @Test(arguments: [
        ("notFound", DeletedFilesNotice.restoreGone),
        ("denied", DeletedFilesNotice.restoreDenied),
        ("unsupported", DeletedFilesNotice.restoreUnsupported),
        ("other", DeletedFilesNotice.restoreNotConfirmed),
    ])
    func aLiftThatEndsBadlyIsSaidInAFixedSentenceAndTrailedWithTheSame(
        name: String, expected: DeletedFilesNotice
    ) async throws {
        let pane = Pane()
        let row = try await deletedRow(in: pane)
        let canary = "https://AKIACANARYKEY:SECRETCANARY@store.invalid"
        let error: any Error
        switch name {
        case "notFound": error = RemoteFSError.notFound(path: canary)
        case "denied": error = RemoteFSError.permissionDenied(path: canary)
        case "unsupported": error = RemoteFSError.finding(.operationNotSupported)
        default: error = RemoteFSError.protocolError(reason: canary)
        }
        pane.counters.setLiftError(error)
        let trail = Trail()
        defer { trail.remove() }

        let notice = await DeletedFileRestorer(provider: pane.fs, recorder: trail.recorder)
            .restore([row], in: context())

        #expect(notice == expected)
        #expect(pane.counters.lifts.count == 1)
        let event = try #require(trail.events.first)
        #expect(trail.events.count == 1)
        #expect(event.kind == .deleteMarkerLifted)
        #expect(event.isError)
        // The comparison is computed first: `#expect` prints the evaluated
        // subexpressions, so `event.errorMessage == expected.line.text` inside
        // it printed the error's own words (the endpoint canary, 12 times)
        // under exactly the regression this test is here to catch.
        let trailSaysTheFixedSentence = event.errorMessage == expected.line.text
        #expect(trailSaysTheFixedSentence)
        let recorded = "\(event.detail) \(event.errorMessage ?? "")"
        let leaked = recorded.contains("SECRETCANARY") || recorded.contains("AKIACANARYKEY")
        #expect(leaked == false)
        let shown = expected.line.text
        let shownLeaked = shown.contains("SECRETCANARY") || shown.contains("AKIACANARYKEY")
        #expect(shownLeaked == false)
    }

    @Test func aRowThatIsNotADeletedFileOrHasNoTargetSendsNothingAndSaysSo() async throws {
        let pane = Pane()
        let trail = Trail()
        defer { trail.remove() }
        let plain = RemoteFileItem(name: "kept.txt", path: "/bucket/docs/kept.txt", kind: .file)
        let row = try await deletedRow(in: pane)
        let restorer = DeletedFileRestorer(provider: pane.fs, recorder: trail.recorder)

        // A row that is not deleted carries no marker to lift.
        #expect(await restorer.restore([plain], in: context()) == .restoreUnavailable)
        // A deleted row at a connection with no bucket has no key to name.
        let noTarget = await restorer.restore([row], in: context(container: false, bucket: ""))
        #expect(noTarget == .restoreUnavailable)

        #expect(pane.counters.lifts.isEmpty)
        #expect(trail.events.isEmpty)
        // The positive beside the two refusals: the same restorer lifts a real row.
        #expect(await restorer.restore([row], in: context()) == nil)
        #expect(pane.counters.lifts.count == 1)
    }

    @Test func aRestoreWithNoRecorderStillRestores() async throws {
        let pane = Pane()
        let row = try await deletedRow(in: pane)
        let notice = await DeletedFileRestorer(provider: pane.fs, recorder: nil)
            .restore([row], in: context())
        #expect(notice == nil)
        #expect(pane.counters.lifts.count == 1)
    }

    @Test func eachSelectedRowIsLiftedWithItsOwnMarker() async throws {
        let pane = Pane()
        pane.counters.setDeleted(
            [
                DeletedEntry(key: "docs/a.txt", markerVersionId: "ma", modifiedAt: nil),
                DeletedEntry(key: "docs/b.txt", markerVersionId: "mb", modifiedAt: nil),
            ], underPrefix: "docs/")
        pane.vm.showDeletedFiles = true
        await pane.vm.load()
        let rows = pane.vm.items.filter(\.isDeleted)
        #expect(rows.count == 2)
        let notice = await DeletedFileRestorer(provider: pane.fs, recorder: nil)
            .restore(rows, in: context())
        #expect(notice == nil)
        #expect(
            Set(pane.counters.lifts.map { "\($0.key)=\($0.markerVersionId)" })
                == ["docs/a.txt=ma", "docs/b.txt=mb"])
    }

    // MARK: What a screen reader is told

    @Test func aDeletedRowsNameCellCarriesAnAccessibilityHelpAndNoOtherCellDoes() {
        let deleted = RemoteFileItem(
            name: "gone.txt", path: "/gone.txt", kind: .file, deleteMarkerVersionID: "m")
        let present = RemoteFileItem(name: "kept.txt", path: "/kept.txt", kind: .file)
        let help = RemoteFileTableView.cellAccessibilityHelp(for: .name, item: deleted)
        #expect(help == RemoteFileTableView.deletedDescription)
        #expect(help?.isEmpty == false)
        // The negatives, each beside the positive above: a present file, and
        // the deleted row's other columns.
        #expect(RemoteFileTableView.cellAccessibilityHelp(for: .name, item: present) == nil)
        for column in FileColumn.allCases where column != .name {
            #expect(RemoteFileTableView.cellAccessibilityHelp(for: column, item: deleted) == nil)
        }
        #expect(RemoteFileTableView.cellToolTip(for: .name, item: deleted, text: "gone.txt") == help)
    }

    // MARK: The sentences

    private static let locales = ["en", "de", "fr", "pl"]

    @Test(arguments: ["en", "de", "fr", "pl"])
    func everyLineResolvesInEveryLanguageAndTheEnglishIsTheSourceText(locale: String) {
        for line in DeletedFilesLines.all {
            let resolved = L10n.$localeOverride.withValue(locale) {
                L10n.string(line.key, "ZZ-UNRESOLVED-ZZ")
            }
            #expect(resolved != "ZZ-UNRESOLVED-ZZ", "\(line.key) in \(locale)")
            if locale == "en" {
                #expect(resolved == line.english, "\(line.key)")
            } else {
                #expect(resolved != line.english, "\(line.key) in \(locale)")
            }
        }
        #expect(DeletedFilesLines.all.count == Self.lineCount)
    }

    /// How many lines the family has, written down. The command that produces
    /// the figure, from the repository root:
    /// `grep -o '"browser\.deleted\.' Sources/MacSCPAppKit/Resources/en.lproj/Localizable.strings | wc -l`.
    static let lineCount = 4

    @Test func everyNoticeHasASentenceInTheCatalogue() {
        for notice in [
            DeletedFilesNotice.versioningNotConfirmed, .listingFailed, .restoreNotConfirmed,
            .restoreGone, .restoreDenied, .restoreUnsupported, .restoreUnavailable,
        ] {
            let resolved = L10n.$localeOverride.withValue("de") {
                L10n.string(notice.line.key, "ZZ-UNRESOLVED-ZZ")
            }
            #expect(resolved != "ZZ-UNRESOLVED-ZZ", "\(notice)")
            #expect(resolved != notice.line.english, "\(notice)")
        }
    }

    @Test func theGermanSentencesAddressTheReaderAsDu() {
        let german = L10n.$localeOverride.withValue("de") { DeletedFilesLines.all.map(\.text) }
        #expect(german.count == DeletedFilesLines.all.count)
        let polite = german.filter {
            $0.contains(" Ihr") || $0.hasPrefix("Ihr") || $0.contains("Ihnen")
                || $0.contains("Sie ") || $0.contains(" Sie")
        }
        #expect(polite.isEmpty, "\(polite)")
    }

    /// The marker refusal in the version sheet pointed nowhere because the
    /// place that lifts a marker did not exist. It does now, and the sentence
    /// says where, in all four languages.
    @Test(arguments: ["en", "de", "fr", "pl"])
    func theMarkerRefusalOfTheVersionSheetSaysWhereAMarkerIsLifted(locale: String) {
        let text = L10n.$localeOverride.withValue(locale) { ObjectVersionsLines.refusalMarker.text }
        let name = L10n.$localeOverride.withValue(locale) {
            L10n.string("settings.general.showDeleted", "")
        }
        #expect(name.isEmpty == false)
        #expect(text.contains(name), "\(locale): \(text)")
    }

    /// The five new keys that are not `CatalogueLine`s are bare
    /// `L10n.string(key, default)` calls, where a typo falls back to the English
    /// default in every language and the catalogues still agree with each other.
    /// So each is held twice: the source file that spells it spells exactly this
    /// key, and the key resolves to a translation in all four languages.
    nonisolated static let bareKeys: [(key: String, file: String)] = [
        ("settings.general.showDeleted", "SettingsView.swift"),
        ("settings.general.showDeletedHint", "SettingsView.swift"),
        ("menu.toggleDeleted", "MacSCPCommands.swift"),
        ("menu.restoreDeleted", "RemoteFileTableView.swift"),
        ("filetable.deletedTooltip", "RemoteFileTableView.swift"),
    ]

    @Test(arguments: bareKeys.map(\.key))
    func everyBareKeyResolvesInEveryLanguageAndIsSpelledWhereItIsUsed(key: String) throws {
        let file = try #require(Self.bareKeys.first { $0.key == key }?.file)
        let url = SourceCorpus.url(of: .sources).appendingPathComponent("MacSCPAppKit/\(file)")
        let source = try SourceCorpus.commentFree(of: url)
        #expect(source.contains("\"\(key)\""), "\(file) does not spell \(key)")
        let english = L10n.$localeOverride.withValue("en") { L10n.string(key, "ZZ-UNRESOLVED-ZZ") }
        #expect(english != "ZZ-UNRESOLVED-ZZ")
        for locale in ["de", "fr", "pl"] {
            let resolved = L10n.$localeOverride.withValue(locale) { L10n.string(key, "ZZ-UNRESOLVED-ZZ") }
            #expect(resolved != "ZZ-UNRESOLVED-ZZ", "\(key) in \(locale)")
            #expect(resolved != english, "\(key) in \(locale)")
        }
    }

    /// The keys the new source files spell are the keys the checks above walk.
    @Test func everyKeyTheDeletedFilesSourceSpellsIsOneTheCatalogueChecksCover() throws {
        let url = SourceCorpus.url(of: .sources)
            .appendingPathComponent("MacSCPAppKit/DeletedFiles.swift")
        let source = try SourceCorpus.commentFree(of: url)
        let used = Set(source.matches(of: #/"(browser\.deleted\.[^"]+)"/#).map { String($0.output.1) })
        let covered = Set(DeletedFilesLines.all.map(\.key))
        #expect(used.count == covered.count, "\(used.count) keys spelled, \(covered.count) covered")
        #expect(used.subtracting(covered).isEmpty, "\(used.subtracting(covered).sorted())")
        #expect(covered.subtracting(used).isEmpty, "\(covered.subtracting(used).sorted())")
    }
}
