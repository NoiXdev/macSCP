import Foundation

/// Whether the "show deleted files" switch has anything to do in a directory.
public enum DeletedFilesAvailability: Equatable, Sendable {
    /// Nothing: not an S3 connection, the bucket list, or a bucket that has
    /// never kept versions. A switch with nothing to do is not an error and
    /// costs no request.
    case notApplicable
    /// The directory is in a bucket that keeps (or kept) versions.
    case available
    /// Whether the bucket keeps versions could not be read. Not a state: it is
    /// said as what it is and never reported as "off".
    case notConfirmed
}

/// What a source answers for one directory.
public enum DeletedFilesAnswer: Equatable, Sendable {
    case notApplicable
    /// The rows for the deleted keys directly in the directory, possibly none.
    case rows([RemoteFileItem])
    case notConfirmed
}

/// What the pane says about the deleted files it was asked for and could not
/// show, and about a restore that did not end plainly. A closed set: each case
/// is a fixed catalogue sentence in the App, so no error's own text, which
/// can carry an endpoint of the form `scheme://KEY:SECRET@host`, reaches the
/// screen through here.
public enum DeletedFilesNotice: Equatable, Sendable {
    /// The versioning state of the bucket could not be read, so whether it has
    /// deleted files to show is not known.
    case versioningNotConfirmed
    /// The plain listing worked and the listing of deleted keys did not.
    case listingFailed
    /// The deleted rows on screen could not be refreshed by the silent
    /// refresh, so they are the ones the last good read left and may be out of
    /// date. Stays until a `load()` replaces it, which is also what lets the
    /// silent refresh ask again: the notice and the suspension end together.
    case deletedRowsNotRefreshed
    /// A restore was sent and the history does not confirm it.
    case restoreNotConfirmed
    /// The marker the row carried was no longer there.
    case restoreGone
    /// The store refused the restore for a missing permission.
    case restoreDenied
    /// The store does not support the request.
    case restoreUnsupported
    /// Nothing was sent: the row is not a deleted file, or the connection
    /// has no bucket to name, or no way to lift a marker at all.
    case restoreUnavailable
}

/// Where a pane gets the deleted keys of a directory, when it has any to get.
///
/// **A pane without a source (a local pane, a backend that keeps no history)
/// takes the switch and does nothing with it.** The source owns every
/// question that depends on the connection: which bucket a directory is in,
/// and whether that bucket keeps versions. `RemoteBrowserViewModel` asks and
/// merges; it does not know what a bucket is.
@MainActor
public protocol DeletedFileSource {
    /// Whether `deletedFiles(inDirectory:)` has anything to say for `path`.
    /// Answered from what the source already knows where it can, so asking it
    /// on a switch costs no listing.
    func availability(inDirectory path: String) async -> DeletedFilesAvailability

    /// The deleted keys directly in the directory at `path`, as rows. Throws
    /// when the store could not be listed.
    func deletedFiles(inDirectory path: String) async throws -> DeletedFilesAnswer
}
