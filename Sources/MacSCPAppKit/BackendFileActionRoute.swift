import Foundation
import macSCPCore

/// What the context menu does with one backend-contributed file action: offer
/// it, or draw it disabled, and the sentence that says why when there is one.
struct FileActionVerdict: Equatable {
    let isAvailable: Bool
    /// Shown as the disabled row's tooltip. `nil` for an offered row, and for
    /// a declined one that has no sentence of its own (an id this window has
    /// no arm for).
    let reason: CatalogueLine?

    static let available = FileActionVerdict(isAvailable: true, reason: nil)
    static let unrouted = FileActionVerdict(isAvailable: false, reason: nil)
}

/// The backend file actions the window can carry out, by the `id` the
/// backend's descriptor gives them.
///
/// **This is the dispatch table, and it is keyed by id, never by
/// `ConnectionKind`.** It is `ConnectionActionRoute`'s shape for the file
/// context menu: a case exists exactly when `ContentView.handleBrowserMenuEntry`
/// has an arm for that id (the `switch` over this enum there has no `default`,
/// so a case without an arm does not compile), and `verdict(for:...)` answers
/// "declined, no reason" for an id that has no case. A contribution a
/// descriptor declares and this table lacks is therefore drawn DISABLED
/// instead of enabled and inert -- which is what `s3.versions` was before this
/// type existed: the handler was an `if`-chain with no `else`, so the row
/// matched nothing and did nothing on every S3 file.
///
/// The raw value is the contribution's `id`: a second spelling of a string
/// `BackendDescriptor` already holds, which is why
/// `BackendFileActionRouteTests` reads the descriptors in both directions.
enum BackendFileActionRoute: String, CaseIterable {
    case presignedURL = "s3.presignedURL"
    case retention = "s3.retention"
    case legalHold = "s3.legalHold"
    case versions = "s3.versions"

    init?(action: FileActionContribution) {
        self.init(rawValue: action.id)
    }

    /// Whether this route's row is offered, given what the session already
    /// knows about the bucket the pane is in.
    ///
    /// `bucketVersioning` is `nil` when that has not been read yet
    /// (`BucketVersioningCache.knownVersioning(_:)`), and **a row whose
    /// condition is unknown is offered**: the menu builds synchronously, nothing
    /// triggers the read, so a row disabled while unknown could never become
    /// enabled by waiting, and the sheet it opens says what there is (or is
    /// not) to show. The cost is stated rather than designed around: the
    /// declined row and its reason are reachable only for a bucket whose
    /// versioning was read earlier in the session, and the fix (a read when
    /// the pane enters a bucket, one `GET ?versioning` per navigation) is
    /// Task 11 of the version-history plan's backlog row, not this code.
    ///
    /// Only the history row has a condition. The `switch` has no `default`.
    func verdict(bucketVersioning: BucketVersioning?) -> FileActionVerdict {
        switch self {
        case .presignedURL, .retention, .legalHold:
            return .available
        case .versions:
            guard let bucketVersioning else { return .available }
            let availability = VersionsRowAvailability(versioning: bucketVersioning)
            return FileActionVerdict(
                isAvailable: availability.isAvailable, reason: availability.reason)
        }
    }

    /// The one question the menu asks of a row: declined, with no reason, for
    /// an id this table has no case for.
    static func verdict(
        for action: FileActionContribution, bucketVersioning: BucketVersioning?
    ) -> FileActionVerdict {
        guard let route = BackendFileActionRoute(action: action) else { return .unrouted }
        return route.verdict(bucketVersioning: bucketVersioning)
    }

    /// `verdict(for:bucketVersioning:)` for the bucket the pane is in, asked of
    /// the session's cache: it reads only what the cache already holds
    /// (`knownVersioning(_:)`), so a bucket nobody has asked about, no bucket
    /// at all (the pane is at the bucket list) and no cache (a backend without
    /// bucket settings) all give `nil`, and the row is offered.
    @MainActor
    static func verdict(
        for action: FileActionContribution, bucket: String?, cache: BucketVersioningCache?
    ) -> FileActionVerdict {
        let known = bucket.flatMap { cache?.knownVersioning($0) }
        return verdict(for: action, bucketVersioning: known)
    }
}
