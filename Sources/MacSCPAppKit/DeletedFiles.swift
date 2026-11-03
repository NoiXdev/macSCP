import SwiftUI
import macSCPCore

/// Every sentence the deleted-files rows add to the browser, as data, so the
/// tests can hold each one to all four languages.
///
/// A notice that reuses a sentence the version sheet already has (a refusal
/// for a missing permission, a store that does not support the request) points
/// at that sentence instead of carrying a second copy of it.
enum DeletedFilesLines {
    static let versioningNotConfirmed = CatalogueLine(
        key: "browser.deleted.notice.versioningNotConfirmed",
        english: "Deleted files are not shown: macSCP could not confirm whether this bucket keeps versions.")
    static let listingFailed = CatalogueLine(
        key: "browser.deleted.notice.listingFailed",
        english: "The deleted files could not be listed. The files that are there are shown.")
    static let restoreNotConfirmed = CatalogueLine(
        key: "browser.deleted.notice.restoreNotConfirmed",
        english: "The restore could not be confirmed. The listing was read again: check whether the file is back before trying again.")
    static let notRefreshed = CatalogueLine(
        key: "browser.deleted.notice.notRefreshed",
        english: "The deleted files shown could not be refreshed, so they may be out of date. Refresh to try again.")
    static let restoreGone = CatalogueLine(
        key: "browser.deleted.notice.restoreGone",
        english: "This file is not deleted any more. The listing was read again.")

    /// Every line this family owns, for the tests that hold each to all four
    /// catalogues. The notices that reuse the version sheet's sentences are
    /// covered by that sheet's own family.
    static let all: [CatalogueLine] = [
        versioningNotConfirmed, listingFailed, restoreNotConfirmed, restoreGone, notRefreshed,
    ]
}

extension DeletedFilesNotice {
    /// The sentence for this notice. No `default:`: a new notice is a compile
    /// error here instead of a pane that says nothing about it.
    var line: CatalogueLine {
        switch self {
        case .versioningNotConfirmed: DeletedFilesLines.versioningNotConfirmed
        case .listingFailed: DeletedFilesLines.listingFailed
        case .restoreNotConfirmed: DeletedFilesLines.restoreNotConfirmed
        case .restoreGone: DeletedFilesLines.restoreGone
        case .restoreDenied: ObjectVersionsLines.outcomeDenied
        case .restoreUnsupported: ObjectVersionsLines.outcomeUnsupported
        case .restoreUnavailable: ObjectVersionsLines.refusalUnavailable
        }
    }
}

/// Where the deleted keys of a directory come from on an S3 connection: the
/// version capability, asked for the bucket and the folder a pane path names,
/// once the bucket is known to keep versions.
///
/// **The bucket's state is read through the session's cache, and what it could
/// not read is said so.** `BucketVersioningCache.versioning(_:)` is the same
/// read the history row and the Versioning sheet share, so a bucket already
/// asked about costs nothing here. A read that threw is `.notConfirmed`, never
/// `.notApplicable`: "this bucket has never kept versions" is a thing the store
/// said, and a failure to ask is not. `.never` alone is "nothing to show".
@MainActor
final class S3DeletedFileSource: DeletedFileSource {
    private let provider: any ObjectVersionProvider
    private let rootIsContainerList: Bool
    private let configuredBucket: @MainActor () -> String
    private let cache: BucketVersioningCache?

    init(
        provider: any ObjectVersionProvider, rootIsContainerList: Bool,
        configuredBucket: @escaping @MainActor () -> String, versioning cache: BucketVersioningCache?
    ) {
        self.provider = provider
        self.rootIsContainerList = rootIsContainerList
        self.configuredBucket = configuredBucket
        self.cache = cache
    }

    /// The source for a connection over `fileSystem`, or `nil` when it keeps
    /// no history (the local file system, SFTP, WebDAV): such a pane takes the
    /// switch and has nothing to do with it. Queried with `as?` like every
    /// optional capability.
    static func make(
        for fileSystem: any RemoteFileSystem, versioning cache: BucketVersioningCache?,
        configuredBucket: @escaping @MainActor () -> String
    ) -> S3DeletedFileSource? {
        guard let provider = fileSystem as? any ObjectVersionProvider else { return nil }
        return S3DeletedFileSource(
            provider: provider, rootIsContainerList: fileSystem.rootIsContainerList,
            configuredBucket: configuredBucket, versioning: cache)
    }

    /// A bucket and the key prefix of one folder in it.
    struct Location: Equatable {
        let bucket: String
        /// `""` at the bucket's root, otherwise the folder's key with its
        /// trailing `/`: the form `deletedEntries(inBucket:prefix:)` takes.
        let keyPrefix: String
    }

    /// The bucket and prefix of the directory `path`, or `nil` where there is
    /// no bucket to ask: the bucket list itself, or a connection with no
    /// bucket configured. Worked out from the same two facts
    /// `ObjectLockTarget.resolve` uses, so a deleted row and a live file in
    /// one folder name the same bucket.
    static func location(
        ofDirectory path: String, rootIsContainerList: Bool, configuredBucket: String
    ) -> Location? {
        let components = RemotePath.normalizedAbsolute(path).split(separator: "/").map(String.init)
        let bucket: String
        let folder: ArraySlice<String>
        if rootIsContainerList {
            guard let first = components.first else { return nil }
            bucket = first
            folder = components.dropFirst()
        } else {
            let configured = configuredBucket.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !configured.isEmpty else { return nil }
            bucket = configured
            folder = components[...]
        }
        return Location(bucket: bucket, keyPrefix: folder.isEmpty ? "" : folder.joined(separator: "/") + "/")
    }

    private enum Resolution {
        case notApplicable
        case ready(Location)
        case notConfirmed
    }

    private func resolve(_ path: String) async -> Resolution {
        guard let location = Self.location(
            ofDirectory: path, rootIsContainerList: rootIsContainerList,
            configuredBucket: configuredBucket())
        else { return .notApplicable }
        guard let cache else { return .notConfirmed }
        do {
            switch try await cache.versioning(location.bucket) {
            case .never: return .notApplicable
            case .enabled, .suspended: return .ready(location)
            }
        } catch {
            return .notConfirmed
        }
    }

    func availability(inDirectory path: String) async -> DeletedFilesAvailability {
        switch await resolve(path) {
        case .notApplicable: .notApplicable
        case .ready: .available
        case .notConfirmed: .notConfirmed
        }
    }

    func deletedFiles(inDirectory path: String) async throws -> DeletedFilesAnswer {
        switch await resolve(path) {
        case .notApplicable:
            return .notApplicable
        case .notConfirmed:
            return .notConfirmed
        case .ready(let location):
            let entries = try await provider.deletedEntries(
                inBucket: location.bucket, prefix: location.keyPrefix)
            return .rows(
                RemoteFileItem.deletedRows(
                    from: entries, inDirectory: path, keyPrefix: location.keyPrefix))
        }
    }
}

/// Brings deleted files back from the browser's rows, by removing the delete
/// marker each row carries.
///
/// **A restore sends one request per row and no read of its own.** The marker
/// id travelled on the row from the listing that made it, so nothing is listed
/// again to find it (the store's own call reads the history around the delete
/// to confirm it, which is Core's business). **A row that cannot be sent sends
/// nothing and says so**: not a deleted row, or no bucket to name.
///
/// Every request that is sent leaves one line in the session's trail, done or
/// not. Its failure text is the notice's own catalogue sentence and never the
/// error's: a `reason` can carry an endpoint of the form
/// `scheme://KEY:SECRET@host`.
@MainActor
struct DeletedFileRestorer {
    let provider: any ObjectVersionProvider
    let recorder: AuditRecorder?

    /// Lifts the marker of every row in `rows`, one after another, and answers
    /// the first thing that did not end plainly, or `nil` when every row did.
    /// A row's failure does not stop the others: they are independent keys.
    func restore(_ rows: [RemoteFileItem], in context: ConnectionActionContext) async -> DeletedFilesNotice? {
        var first: DeletedFilesNotice?
        for row in rows {
            guard let markerID = row.deleteMarkerVersionID,
                let target = ObjectLockTarget.resolve(path: row.path, in: context)
            else {
                first = first ?? .restoreUnavailable
                continue
            }
            let notice: DeletedFilesNotice?
            do {
                try await provider.liftDeleteMarker(
                    ofKey: target.key, inBucket: target.bucket, markerVersionId: markerID)
                notice = nil
            } catch {
                notice = Self.notice(of: error)
            }
            recorder?.recordDeleteMarkerLifted(
                key: target.key, bucket: target.bucket, markerVersionId: markerID,
                failure: notice?.line.text)
            first = first ?? notice
            if Task.isCancelled { break }
        }
        return first
    }

    /// What an error from the lift means for the person. **Certain refusals say
    /// the store answered; everything else says the outcome could not be
    /// confirmed**: a lost connection, a cancelled request or Core's own "the
    /// history still lists it" leave the marker possibly gone, and "failed"
    /// would be a claim nobody checked. The same sort as
    /// `ObjectVersionsModel.outcome(of:for:)`.
    static func notice(of error: any Error) -> DeletedFilesNotice {
        switch error {
        case RemoteFSError.notFound:
            return .restoreGone
        case RemoteFSError.permissionDenied, RemoteFSError.authenticationFailed:
            return .restoreDenied
        case RemoteFSError.finding(.operationNotSupported):
            return .restoreUnsupported
        default:
            return .restoreNotConfirmed
        }
    }
}

/// The line under a pane's header that says what the pane could not do about
/// deleted files, how a restore ended, or (`DeletedFilesLines.notRefreshed`,
/// from `deletedRowsAreStale`) that the deleted rows may be out of date.
struct DeletedFilesNoticeRow: View {
    let line: CatalogueLine

    var body: some View {
        VStack(spacing: 0) {
            Text(line.text)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
            Rectangle()
                .fill(DesignTokens.hairline)
                .frame(height: 1)
        }
    }
}
