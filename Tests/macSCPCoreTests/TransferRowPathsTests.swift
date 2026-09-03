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

    private func makeItem(
        fileName: String,
        direction: TransferDirection,
        sourcePath: String,
        destinationDirectory: String,
        crossRemote: Bool = false,
        crossBackendTarget: CrossBackendTarget? = nil
    ) -> VM.Item {
        VM.Item(
            id: UUID(), fileName: fileName, direction: direction, status: .queued,
            sourcePath: sourcePath, destinationTabID: nil, isEditUpload: false,
            destinationDirectory: destinationDirectory,
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

    /// A destination directory that already ends in a slash must not
    /// produce a doubled one — the same join the engine itself uses
    /// (`RemotePath.join`), so what the row shows is the path the transfer
    /// actually writes.
    @Test func theDestinationIsJoinedTheWayTheEngineJoinsIt() {
        let item = makeItem(
            fileName: "index.html", direction: .download,
            sourcePath: "/var/www/index.html",
            destinationDirectory: "/")
        let paths = TransferRowPaths(item: item, sessionName: nil)

        #expect(paths.destination == "/index.html")
    }

    // MARK: - What "Copy paths" puts on the pasteboard

    /// One path per line, source first — the same order the row's hint
    /// reads in, so what was copied matches what was seen. The session
    /// qualification is part of it by design: the row shows qualified
    /// paths, and a copy that silently differed from the display would be
    /// the more surprising of the two.
    @Test func clipboardTextIsTheTwoPathsOnePerLineSourceFirst() {
        let item = makeItem(
            fileName: "db.sql", direction: .upload,
            sourcePath: "/srv/app/db.sql",
            destinationDirectory: "/incoming",
            crossRemote: true,
            crossBackendTarget: CrossBackendTarget(name: "backup-host", kind: .ssh))
        let paths = TransferRowPaths(item: item, sessionName: "prod-web")

        #expect(paths.clipboardText == "\(paths.source)\n\(paths.destination)")
    }

    // MARK: - The item really carries the source

    /// The fold is only worth anything if the queue puts a real source path
    /// on the item. `enqueue` is given one; this pins that it survives onto
    /// the item rather than being dropped at the boundary.
    @Test func enqueueCarriesTheSourcePathOntoTheItem() throws {
        let queue = TransferQueueViewModel()
        let fileSystem = MockRemoteFileSystem()
        queue.enqueue(
            fileName: "db.sql", direction: .upload,
            source: fileSystem, sourcePath: "/srv/app/db.sql",
            destination: fileSystem, destinationDirectory: "/incoming",
            onCompleted: nil, crossRemote: true)

        let item = try #require(queue.items.first)
        #expect(item.sourcePath == "/srv/app/db.sql")
        #expect(item.crossRemote)
    }
}
