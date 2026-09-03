import Foundation
import Testing
@testable import macSCPCore

/// The two full paths a transfer row can show on demand.
///
/// The row's own display is a file name and a direction arrow, which is
/// exactly as much as fits — and exactly too little to answer "which
/// `config.yml`, and going where?". `TransferRowPaths` is the fold from a
/// queue item to that answer, and it lives here rather than in the view
/// because the mapping it makes is not a layout decision: it decides which
/// SIDE of a transfer is on this machine, which is a fact about the queue's
/// own model.
///
/// Three of the shapes below come from the task brief (an SSH→local
/// download, a local→S3 upload, a cross-session transfer with both paths
/// named with their sessions); the rest exist because the mapping has
/// exactly two inputs that can disagree — `direction` and `crossRemote` —
/// and a test per case is what keeps a later reader from "simplifying"
/// `crossRemote` away.
@Suite("TransferRowPaths")
@MainActor
struct TransferRowPathsTests {
    private typealias VM = TransferQueueViewModel

    /// `destinationPath` defaults to the engine's own join of the two, which
    /// is what every non-terminal item carries — a case that needs them to
    /// DIFFER (a terminal row, whose `fileName` is a decorated label rather
    /// than a name) passes it explicitly.
    private func makeItem(
        fileName: String,
        direction: TransferDirection,
        sourcePath: String,
        destinationDirectory: String,
        destinationPath: String? = nil,
        crossRemote: Bool = false,
        crossBackendTarget: CrossBackendTarget? = nil
    ) -> VM.Item {
        VM.Item(
            id: UUID(), fileName: fileName, direction: direction, status: .queued,
            sourcePath: sourcePath, destinationTabID: nil, isEditUpload: false,
            destinationDirectory: destinationDirectory,
            destinationPath: destinationPath
                ?? RemotePath.join(destinationDirectory, fileName),
            destinationSupportsResume: true, crossRemote: crossRemote,
            crossBackendTarget: crossBackendTarget)
    }

    /// The qualifier the catalogue supplies, applied to a path — spelled
    /// once here, so a test asserts the SHAPE the code produces rather than
    /// a second copy of the English text. A hardcoded "(on prod-web)" would
    /// be a claim about the English catalogue, and it would fail the moment
    /// a translator moves the parenthesis.
    private func onSession(_ path: String, _ sessionName: String) -> String {
        String(format: CoreL10n.string("core.transfer.pathOnSession %1$@ %2$@"), path, sessionName)
    }

    // MARK: - The three shapes the brief names

    @Test func sshDownloadNamesTheRemoteSourceAndLeavesTheLocalDestinationPlain() {
        let item = makeItem(
            fileName: "index.html", direction: .download,
            sourcePath: "/var/www/index.html",
            destinationDirectory: "/Users/tester/Downloads")
        let paths = TransferRowPaths(item: item, sessionName: "prod-web")

        #expect(paths.source == onSession("/var/www/index.html", "prod-web"))
        #expect(paths.destination == "/Users/tester/Downloads/index.html")
    }

    /// `onSession` above renders the same catalogue key the code renders,
    /// so on its own it would keep agreeing with a format string that lost
    /// one of its two arguments — both sides would print the same hole.
    /// This is the check that says what the qualifier must ACHIEVE: the
    /// path survives it whole, the session name appears, and the result is
    /// not simply the path back again.
    @Test func qualifyingAPathKeepsThePathAndAddsTheSessionName() {
        let item = makeItem(
            fileName: "index.html", direction: .download,
            sourcePath: "/var/www/index.html",
            destinationDirectory: "/Users/tester/Downloads")
        let qualified = TransferRowPaths(item: item, sessionName: "prod-web").source

        #expect(qualified.contains("/var/www/index.html"))
        #expect(qualified.contains("prod-web"))
        #expect(qualified != "/var/www/index.html")
    }

    @Test func localToS3UploadNamesTheRemoteDestinationAndLeavesTheLocalSourcePlain() {
        let item = makeItem(
            fileName: "report.pdf", direction: .upload,
            sourcePath: "/Users/tester/report.pdf",
            destinationDirectory: "/backups/2026")
        let paths = TransferRowPaths(item: item, sessionName: "archive-s3")

        #expect(paths.source == "/Users/tester/report.pdf")
        #expect(paths.destination == onSession("/backups/2026/report.pdf", "archive-s3"))
    }

    /// The cross-session case, and the reason `crossRemote` had to be
    /// carried onto the item at all: a remote→remote transfer is enqueued
    /// with `direction == .upload`, so direction alone would call its
    /// source a local file. Both sides are remote here, and they belong to
    /// two DIFFERENT sessions — the queue is always the source tab's, and
    /// `crossBackendTarget` names the tab being written into.
    @Test func crossSessionTransferNamesBothPathsWithTheirOwnSessions() {
        let item = makeItem(
            fileName: "db.sql", direction: .upload,
            sourcePath: "/srv/app/db.sql",
            destinationDirectory: "/incoming",
            crossRemote: true,
            crossBackendTarget: CrossBackendTarget(name: "backup-host", kind: .ssh))
        let paths = TransferRowPaths(item: item, sessionName: "prod-web")

        #expect(paths.source == onSession("/srv/app/db.sql", "prod-web"))
        #expect(paths.destination == onSession("/incoming/db.sql", "backup-host"))
    }

    // MARK: - The seams between those three

    /// Local → ANOTHER tab's remote: cross-session, but the source really
    /// is a file on this machine. The destination is named with the target
    /// session, never with the queue's own.
    @Test func localToAnotherSessionNamesOnlyTheDestination() {
        let item = makeItem(
            fileName: "notes.md", direction: .upload,
            sourcePath: "/Users/tester/notes.md",
            destinationDirectory: "/home/deploy",
            crossBackendTarget: CrossBackendTarget(name: "backup-host", kind: .ssh))
        let paths = TransferRowPaths(item: item, sessionName: "prod-web")

        #expect(paths.source == "/Users/tester/notes.md")
        #expect(paths.destination == onSession("/home/deploy/notes.md", "backup-host"))
    }

    /// A tab that has no name yet (never connected, or an ad-hoc connect
    /// before the title lands) must not invent one: the paths stay plain
    /// rather than gaining an empty or placeholder qualifier.
    @Test func withoutASessionNameBothPathsStayPlain() {
        let item = makeItem(
            fileName: "index.html", direction: .download,
            sourcePath: "/var/www/index.html",
            destinationDirectory: "/Users/tester/Downloads")
        let paths = TransferRowPaths(item: item, sessionName: nil)

        #expect(paths.source == "/var/www/index.html")
        #expect(paths.destination == "/Users/tester/Downloads/index.html")
    }

    /// An empty title is the same statement as no title, and it arrives by
    /// a different route (a stored session saved with a blank name) — so it
    /// must not produce "…( on )".
    @Test func anEmptySessionNameIsTreatedAsNoName() {
        let item = makeItem(
            fileName: "index.html", direction: .download,
            sourcePath: "/var/www/index.html",
            destinationDirectory: "/Users/tester/Downloads")
        let paths = TransferRowPaths(item: item, sessionName: "")

        #expect(paths.source == "/var/www/index.html")
    }

    /// The destination the row shows is the item's own `destinationPath` —
    /// the path the engine writes — and never a path this fold rebuilt from
    /// a display name. A terminal row is where the two part company: a
    /// skipped symlink's `fileName` is `link →`, so a rebuilt path would
    /// put an arrow glyph in the hint and, worse, on the pasteboard.
    @Test func aDecoratedDisplayNameNeverReachesTheDestinationPath() {
        let item = makeItem(
            fileName: "link →", direction: .download,
            sourcePath: "/dir/link",
            destinationDirectory: "/ziel/dir",
            destinationPath: "/ziel/dir/link")
        let paths = TransferRowPaths(item: item, sessionName: nil)

        #expect(paths.destination == "/ziel/dir/link")
        #expect(paths.clipboardText == "/dir/link\n/ziel/dir/link")
    }

    // MARK: - What "Copy paths" puts on the pasteboard

    /// One RAW path per line, source first. Every other copy affordance in
    /// the tree hands over a path that can be pasted into a shell —
    /// `copyPaths(of:)` in `ContentView+Transfers` and the path bar's own
    /// click both copy `\.path` verbatim — and a "Copy paths" that pasted
    /// `/var/www/index.html (on prod-web)` would be the one place a copied
    /// path is not a path. The qualification belongs to the DISPLAY, which
    /// the next test holds separately.
    @Test func clipboardTextIsTheTwoRawPathsOnePerLineSourceFirst() {
        let item = makeItem(
            fileName: "db.sql", direction: .upload,
            sourcePath: "/srv/app/db.sql",
            destinationDirectory: "/incoming",
            crossRemote: true,
            crossBackendTarget: CrossBackendTarget(name: "backup-host", kind: .ssh))
        let paths = TransferRowPaths(item: item, sessionName: "prod-web")

        #expect(paths.clipboardText == "/srv/app/db.sql\n/incoming/db.sql")
    }

    /// The two halves of the ruling in one place: the same fold's display
    /// strings ARE qualified and its clipboard text is not. Stated as one
    /// test because the risk is that a later change collapses them back
    /// into one string — whichever way it collapses, this goes red.
    ///
    /// The session names are checked for ABSENCE from the clipboard rather
    /// than for a particular rendering, so the assertion survives a
    /// translator moving the qualifier's punctuation.
    @Test func theDisplayStringsAreQualifiedWhileTheClipboardIsNot() {
        let item = makeItem(
            fileName: "db.sql", direction: .upload,
            sourcePath: "/srv/app/db.sql",
            destinationDirectory: "/incoming",
            crossRemote: true,
            crossBackendTarget: CrossBackendTarget(name: "backup-host", kind: .ssh))
        let paths = TransferRowPaths(item: item, sessionName: "prod-web")

        #expect(paths.source.contains("prod-web"))
        #expect(paths.destination.contains("backup-host"))
        let clipboardNamesASession =
            paths.clipboardText.contains("prod-web") || paths.clipboardText.contains("backup-host")
        #expect(clipboardNamesASession == false, """
            a copied path must be a path -- the session qualifier belongs to the \
            hint the row shows, not to what is pasted into a shell
            """)
    }

    // MARK: - The item really carries both paths

    /// The fold is only worth anything if the queue puts real paths on the
    /// item. `enqueue` is given a source path and builds the destination
    /// one; this pins that both survive onto the item rather than being
    /// dropped at the boundary.
    ///
    /// A directory that already ends in a slash is the case that says the
    /// queue uses `RemotePath.join` — the engine's own join — rather than
    /// concatenating, so what the row shows is the path the transfer writes
    /// and not a doubled slash.
    @Test func enqueueCarriesBothPathsOntoTheItem() throws {
        let queue = TransferQueueViewModel()
        let fileSystem = MockRemoteFileSystem()
        queue.enqueue(
            fileName: "db.sql", direction: .upload,
            source: fileSystem, sourcePath: "/srv/app/db.sql",
            destination: fileSystem, destinationDirectory: "/",
            onCompleted: nil, crossRemote: true)

        let item = try #require(queue.items.first)
        #expect(item.sourcePath == "/srv/app/db.sql")
        #expect(item.destinationPath == "/db.sql")
        #expect(item.crossRemote)
    }
}
