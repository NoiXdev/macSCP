import Foundation
import Testing
@testable import MacSCPAppKit
@testable import macSCPCore

/// What each door into the diff view DECIDED, as a value (fix round 1, F3).
///
/// Three of the four doors' routing decisions used to be pinned by source
/// scans that counted anchors independently of one another, so a defect that
/// permuted anchors rather than removing one was free: the reviewer planted
/// an inverted ternary (every row compared against itself) and a pair of
/// swapped switch arms (the local pane's roots assigned to the remote pane's
/// sides) and the guard suite stayed green at
/// `control: 10 test(s) ran, 0 pre-existing failures`. A request is a value,
/// so those two are ordinary expectations here instead.
@Suite("Comparison request")
struct ComparisonRequestTests {
    private func file(_ name: String, in directory: String) -> RemoteFileItem {
        RemoteFileItem(
            name: name, path: RemotePath.join(directory, name), kind: .file, size: 1)
    }
    private func folder(_ name: String, in directory: String) -> RemoteFileItem {
        RemoteFileItem(name: name, path: RemotePath.join(directory, name), kind: .directory)
    }

    private let localDirectory = "/Users/me/notes"
    private let remoteDirectory = "/srv/notes"

    private func forRow(
        _ selection: [RemoteFileItem], on side: BrowserPaneSide
    ) -> ComparisonRequest? {
        ComparisonRequest.forRow(
            selection, on: side,
            localDirectory: localDirectory, remoteDirectory: remoteDirectory)
    }

    // MARK: One row against its counterpart

    /// From the LOCAL pane: the row itself is the left root, and the right
    /// root is the same NAME under the REMOTE pane's directory. Local is
    /// always the left side.
    @Test func aLocalRowIsMeasuredAgainstTheSameNameInTheRemoteDirectory() throws {
        let request = try #require(forRow([file("a.txt", in: localDirectory)], on: .local))
        #expect(request == ComparisonRequest(
            left: .local, leftRoot: "/Users/me/notes/a.txt",
            right: .remote, rightRoot: "/srv/notes/a.txt",
            kind: .filePair))
    }

    /// From the REMOTE pane: the row is the RIGHT root and the counterpart is
    /// the left one. The two roots swap with the side; the two SIDES do not.
    ///
    /// This is the expectation that kills the reviewer's plant C — the
    /// `.local` arm given the `.remote` arm's roots, which compared local
    /// `/srv/notes/a.txt` against remote `/Users/me/notes/a.txt`.
    @Test func aRemoteRowIsMeasuredAgainstTheSameNameInTheLocalDirectory() throws {
        let request = try #require(forRow([file("a.txt", in: remoteDirectory)], on: .remote))
        #expect(request == ComparisonRequest(
            left: .local, leftRoot: "/Users/me/notes/a.txt",
            right: .remote, rightRoot: "/srv/notes/a.txt",
            kind: .filePair))
    }

    /// The counterpart comes from the OTHER pane's directory, never from this
    /// one's. The reviewer's plant B inverted exactly this ternary, and every
    /// comparison then had both roots equal — a window that always says the
    /// two files are identical.
    @Test func noDoorEverComparesARowAgainstItself() throws {
        for (selection, side) in [
            ([file("a.txt", in: localDirectory)], BrowserPaneSide.local),
            ([file("a.txt", in: remoteDirectory)], BrowserPaneSide.remote),
        ] {
            let request = try #require(forRow(selection, on: side))
            #expect(request.leftRoot != request.rightRoot)
        }
        // And the row that was selected really is one of the two roots, so
        // the inequality above cannot be satisfied by two unrelated paths.
        let fromLocal = try #require(forRow([file("a.txt", in: localDirectory)], on: .local))
        #expect(fromLocal.leftRoot == "/Users/me/notes/a.txt")
        let fromRemote = try #require(forRow([file("a.txt", in: remoteDirectory)], on: .remote))
        #expect(fromRemote.rightRoot == "/srv/notes/a.txt")
    }

    /// A directory row is a folder comparison, anything else a file pair.
    @Test func theRowsKindDecidesTheShapeOfTheComparison() throws {
        let asFolder = try #require(forRow([folder("sub", in: localDirectory)], on: .local))
        #expect(asFolder.kind == .folders)
        let asFile = try #require(forRow([file("a.txt", in: localDirectory)], on: .local))
        #expect(asFile.kind == .filePair)
    }

    /// Not one row, no request. The menu model is what decides WHETHER the
    /// entry is offered; this is the door refusing to invent a decision for a
    /// selection the entry was never offered for.
    @Test func onlyASingleRowMakesAOneRowRequest() {
        #expect(forRow([], on: .local) == nil)
        #expect(forRow(
            [file("a", in: localDirectory), file("b", in: localDirectory)], on: .local) == nil)
        #expect(forRow(
            [file("a", in: localDirectory), file("b", in: localDirectory),
             file("c", in: localDirectory)], on: .local) == nil)
        // Positive beside the three: one row does make one.
        #expect(forRow([file("a", in: localDirectory)], on: .local) != nil)
    }

    // MARK: Two selected files

    /// Both sides are the pane's own, and the roots are the two rows in
    /// selection order.
    @Test func twoSelectedFilesAreComparedWithEachOtherOnOneSide() throws {
        let selection = [file("a.txt", in: remoteDirectory), file("b.txt", in: remoteDirectory)]
        let request = try #require(ComparisonRequest.forTwoSelected(selection, on: .remote))
        #expect(request == ComparisonRequest(
            left: .remote, leftRoot: "/srv/notes/a.txt",
            right: .remote, rightRoot: "/srv/notes/b.txt",
            kind: .filePair))

        let local = [file("a.txt", in: localDirectory), file("b.txt", in: localDirectory)]
        let fromLocal = try #require(ComparisonRequest.forTwoSelected(local, on: .local))
        #expect(fromLocal.left == .local)
        #expect(fromLocal.right == .local)
    }

    @Test func onlyTwoRowsMakeAPairRequest() {
        let rows = (0..<3).map { file("f\($0)", in: localDirectory) }
        #expect(ComparisonRequest.forTwoSelected([], on: .local) == nil)
        #expect(ComparisonRequest.forTwoSelected(Array(rows.prefix(1)), on: .local) == nil)
        #expect(ComparisonRequest.forTwoSelected(rows, on: .local) == nil)
        // Positive beside the three.
        #expect(ComparisonRequest.forTwoSelected(Array(rows.prefix(2)), on: .local) != nil)
    }

    // MARK: Both panes

    @Test func theMenuBarComparesTheTwoPanesCurrentDirectoriesAsFolders() {
        #expect(
            ComparisonRequest.forBothPanes(
                localDirectory: localDirectory, remoteDirectory: remoteDirectory)
            == ComparisonRequest(
                left: .local, leftRoot: localDirectory,
                right: .remote, rightRoot: remoteDirectory,
                kind: .folders))
    }

    /// Fix round 1, F2. One click on the menu bar's entry used to open a
    /// folder comparison against an S3 pane's BUCKET LIST: every bucket whose
    /// name matched a local subdirectory classified `.bothDirectories`, and
    /// `FolderComparison.walk` descended into it — a recursive walk of a whole
    /// bucket, one checksum per object, from a menu item gated on nothing but
    /// "connected".
    @Test func thePanesAreNotComparableWhileEitherSitsAtAContainerList() {
        let listRoot = BrowserScope(rootIsContainerList: true, currentPath: "/")
        let insideABucket = BrowserScope(rootIsContainerList: true, currentPath: "/macscp-seed")
        #expect(ComparisonRequest.panesAreComparable(local: .ordinary, remote: listRoot) == false)
        #expect(ComparisonRequest.panesAreComparable(local: listRoot, remote: .ordinary) == false)
        // The positives: an ordinary pair, and the same S3 session one level
        // in, where the rows are objects and a walk is what the user asked
        // for.
        #expect(ComparisonRequest.panesAreComparable(local: .ordinary, remote: .ordinary))
        #expect(ComparisonRequest.panesAreComparable(local: .ordinary, remote: insideABucket))
    }
}
