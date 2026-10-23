import Foundation

/// What a browser pane is looking at, for the one question every action
/// gate asks: is this row a CONTAINER — an S3 bucket — rather than
/// something inside one? (2026-09-02, the bucket-list design.)
///
/// **Why a path test and not a capability flag.** "May I rename this?" is
/// not a property of the S3 protocol; every S3 session can rename an object,
/// and the same session can do it one level below a row it must not touch.
/// `ProtocolCapabilities` describes a BACKEND ("does this protocol have
/// POSIX permissions"), and there is no answer it could carry that changes
/// between two rows of one connection. So the fact that varies per row —
/// the depth of the path — is where the question is answered, and the only
/// thing the backend has to contribute is whether its root lists containers
/// at all (`RemoteFileSystem.rootIsContainerList`).
///
/// **Why one value and not two parameters.** Two facts are needed: whether
/// this connection's root is a container list, and which directory the
/// menu was opened over (a background click has no row to point at). Passing
/// them separately makes it possible to thread one and forget the other;
/// carried together, a caller either has the scope or has `.ordinary`.
public struct BrowserScope: Equatable, Sendable {
    /// Whether this pane's ROOT lists containers rather than files — an S3
    /// session started at the bucket list. `false` for SSH, for WebDAV, and
    /// for an S3 session pointed at a single bucket.
    public let rootIsContainerList: Bool

    /// The directory whose listing the menu (or the drop) is over.
    public let currentPath: String

    public init(rootIsContainerList: Bool, currentPath: String) {
        self.rootIsContainerList = rootIsContainerList
        self.currentPath = currentPath
    }

    /// What every pane that is not an S3 bucket-list session answers — and
    /// the default of every gate below, so a call site that predates this
    /// keeps exactly the behaviour it had.
    public static let ordinary = BrowserScope(rootIsContainerList: false, currentPath: "/")

    /// This listing IS the container list: its rows are buckets, and there
    /// is nothing here to create, upload into or drop onto.
    ///
    /// The pane-level half of the question, for the callers whose subject is
    /// a LISTING rather than a row: the background context menu, which has no
    /// row to point at; `.compareWithOtherPane`, which asks it of the OTHER
    /// pane, where the counterpart it would measure against has to be an
    /// entry of a directory and not a bucket; `acceptsIncomingFiles` below;
    /// `ComparisonRequest.panesAreComparable(local:remote:)`, which asks
    /// it of BOTH panes before the menu bar's "Compare Both Panes" is
    /// enabled, and therefore spells it twice on one line; and
    /// `EmptyContainerListView.isShown(scope:state:listedItemCount:)`, which
    /// asks it of the pane it is about to draw a notice over. FIVE readers,
    /// six reads.
    ///
    /// **Corrected 2026-10-23 (M3 of the scoped re-review).** The enumeration
    /// above ended, verbatim: "and
    /// `ComparisonRequest.panesAreComparable(local:remote:)`, which asks it
    /// of BOTH panes before the menu bar's "Compare Both Panes" is enabled,
    /// and therefore spells it twice on one line. FOUR readers, five reads."
    /// `EmptyContainerListView.isShown` landed in `6d0c87c8` (F3 of the
    /// bucket-settings fix wave, the empty bucket list), which never touched
    /// this file -- which is exactly where CLAUDE.md's "Comments that
    /// describe other code" says the damage happens: the comment became
    /// wrong without appearing in any diff.
    ///
    /// **Corrected 2026-10-16, and this is what it replaces, verbatim:** "and
    /// `acceptsIncomingFiles` below. Three readers in `Sources`, counted
    /// 2026-10-15 with `grep -rno isContainerListRoot Sources/ | wc -l`,
    /// which prints 5: those three, this declaration, and the pattern of that
    /// command, which is written in this comment and so finds itself." Both
    /// halves were false by then. `panesAreComparable` is a fourth reader and
    /// landed in `3ba42629`; this comment landed in `528accf4`, which
    /// `git merge-base --is-ancestor 528accf4 3ba42629` confirms came first,
    /// and both are in this plan's own range of work. The figure went with
    /// it: `git grep -no isContainerListRoot 528accf4 -- Sources | wc -l`
    /// prints 5, and the same command at `693db7c0` — the plan's last commit
    /// before this fix wave — prints 7. A comment that was true when written
    /// and false two tasks later, in a number and in an enumeration of call
    /// sites, which is what `CLAUDE.md`'s rule about them is for.
    ///
    /// **The figure is counted by a command this comment cannot change.**
    /// A total over `Sources/` counts the pattern wherever this file spells
    /// it, including inside the quotations above, so the number moved whenever
    /// the prose did. Excluding the declaring file leaves what other files
    /// say, and
    /// `git grep -no isContainerListRoot -- Sources ':!*BrowserScope.swift' | wc -l`
    /// prints **6** on 2026-10-23. Classified per MATCH and not per line,
    /// because two of them share a line and one is not a read at all:
    /// `BrowserContextMenu.swift` twice (the background menu and
    /// `.compareWithOtherPane`), `ComparisonRequest.swift` twice on its one
    /// line, `EmptyContainerListView.swift` twice -- once in that view's own
    /// doc comment, which is prose and not a read, and once in `isShown`. So
    /// FIVE reads outside this file; the sixth is `acceptsIncomingFiles`,
    /// here, below. Re-run after this paragraph was written and unchanged by
    /// it, which is the property the exclusion buys.
    ///
    /// **Corrected 2026-10-23 (M3).** This paragraph said, verbatim: "prints
    /// 4 — `BrowserContextMenu.swift` twice (the background menu and
    /// `.compareWithOtherPane`) and `ComparisonRequest.swift` twice on its one
    /// line. The fifth read is `acceptsIncomingFiles`, in this file, below.
    /// Re-run after this paragraph was written, on 2026-10-16, and unchanged
    /// by it, which is the property the exclusion buys." Run unrepaired on
    /// 2026-10-23 that command prints 6, not 4. It also claimed the exclusion
    /// "leaves only reads", which the prose match in
    /// `EmptyContainerListView.swift` now falsifies: the exclusion keeps this
    /// file's own spellings out of the count, and nothing stops another file
    /// from naming the symbol in a comment.
    public var isContainerListRoot: Bool {
        rootIsContainerList && RemotePath.normalizedAbsolute(currentPath) == "/"
    }

    /// **The DESTINATION-side question: may files move INTO this pane, at
    /// the directory it is showing?**
    ///
    /// The bucket list is not a directory anything can be put in. Enqueuing
    /// into it makes `TransferEngine` call `createDirectory("/<name>")` or
    /// `write("/<name>")`, which `S3FileSystem` refuses
    /// (`RemoteFSError.bucketLevelRefused`, since `539dc59`) and the queue
    /// explains — correct, and still not what the design asks: a refusal
    /// after the fact is not the same as not offering.
    ///
    /// **Every way a transfer can be aimed at a pane asks THIS function.**
    /// Three places READ it, counted in the tree on 2026-09-02 — reads, not
    /// mentions: a grep for the name also finds this declaration and the
    /// comments that point here, which is a larger number and the reason
    /// this sentence quotes no command. The date is part of the claim: a
    /// count in the present tense is an assertion about a tree that keeps
    /// moving, and this one has moved under a comment before.
    ///
    /// 1. `BrowserContextMenu.entries(…, destination:)` — which gates
    ///    `.transferToOtherPane`, and through it the toolbar's Upload and
    ///    Download buttons and the Space key, since all three ask `entries`
    ///    rather than re-deciding.
    /// 2. `BrowserPane.acceptsDrop` — the Finder drop, at both of its doors
    ///    (the `.onDrop` guard and the highlight).
    /// 3. `CrossSessionTargets.targets(excluding:in:)` — another tab is not
    ///    offered as a destination while its remote pane sits at a bucket
    ///    list.
    ///
    /// It was `acceptsDroppedFiles` and asked by the drop alone. Review
    /// C-1 found the other three doors ungated: a selected bucket row
    /// enabled the toolbar's Download and one click enqueued a whole-bucket
    /// tree. The rename is deliberate — the question was never about drops.
    public var acceptsIncomingFiles: Bool { !isContainerListRoot }

    /// `path` names a container itself: the root lists containers, and this
    /// is one path component below it.
    ///
    /// The per-ROW half. Deliberately derived from the path rather than from
    /// `currentPath`, even though every row of one listing shares a depth:
    /// a gate that reads the pane cannot be checked against a row, and this
    /// one is checked against four (`BrowserScopeTests`).
    ///
    /// `normalizedAbsolute` first, because these paths reach the browser
    /// from the path bar as well as from a listing — a trailing slash must
    /// not turn a bucket into two components.
    public func isContainerRow(path: String) -> Bool {
        guard rootIsContainerList else { return false }
        let normalized = RemotePath.normalizedAbsolute(path)
        guard normalized != "/" else { return false }
        return !normalized.dropFirst().contains("/")
    }
}
