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
    /// The pane-level half of the question, for the two callers that have no
    /// row to point at — the background context menu and the drop target.
    public var isContainerListRoot: Bool {
        rootIsContainerList && RemotePath.normalizedAbsolute(currentPath) == "/"
    }

    /// Whether this pane may accept local files dropped onto it at all.
    ///
    /// The drop target's own question, and the third caller of the same
    /// rule. A folder dropped on the bucket list makes `TransferEngine` call
    /// `createDirectory("/<name>")`, which `S3FileSystem` refuses — the
    /// queue then shows a written sentence (that arm exists since
    /// `539dc59`), but a refusal after the fact is not the same as not
    /// offering: "only show what is possible" means the drop is declined
    /// and never highlighted, so no transfer is ever queued.
    public var acceptsDroppedFiles: Bool { !isContainerListRoot }

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
