import Foundation
import macSCPCore

/// What the window knows about the connection when it decides whether a row
/// of the connection-actions menu can be carried out.
///
/// Built at the one place that sees both halves: the descriptor's list (the
/// menu) and the live session (`ContentView`). A row's availability is a
/// question about THIS connection, not about its backend, so the answer is
/// computed from a value that can be built in a test without a window.
struct ConnectionActionContext {
    /// The session's file system as the bucket-settings capability, or `nil`
    /// when it is not one. Queried with `as?` where the context is built, the
    /// way `PresignedURLProvider` is; nothing here assumes the backend has it.
    let settings: (any S3BucketSettings)?
    /// Whether the connection's root lists buckets rather than being one
    /// (`RemoteFileSystem.rootIsContainerList`).
    let rootIsContainerList: Bool
    /// Where the remote pane is now.
    let remotePath: String
    /// The bucket the connection was configured with. Meaningful only when
    /// the root is not the bucket list, where there is no single bucket.
    let configuredBucket: String

    /// The bucket a bucket-level action applies to, or `nil` when there is
    /// none to apply it to.
    ///
    /// A connection rooted in one bucket has exactly one: the configured one.
    /// A connection that starts at the bucket list has the bucket the remote
    /// pane is inside, i.e. the first component of its path, and has none at
    /// the list itself (`/`), where the row is therefore not available.
    var bucket: String? {
        if rootIsContainerList {
            return RemotePath.normalizedAbsolute(remotePath)
                .split(separator: "/").first.map(String.init)
        }
        let trimmed = configuredBucket.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// The connection actions the window can carry out, by the `id` the backend's
/// descriptor gives them.
///
/// **This is the dispatch table, and it is keyed by id, never by
/// `ConnectionKind`.** A case exists exactly when the window has an arm for
/// that id: `ContentView.handleConnectionAction` switches over this enum with
/// no `default`, so a case added here without an arm does not compile, and
/// `isAvailable(_:in:)` answers `false` for an id that has no case, so a row
/// with no arm is DISABLED rather than enabled and inert
/// (`ConnectionActionsMenu` reads that answer for every row).
///
/// The raw value is the contribution's `id`. It is a second spelling of a
/// string `BackendDescriptor` already holds, which is why
/// `ConnectionActionRouteTests.everyRouteIsAnIdSomeBackendContributes` reads
/// the descriptors: renaming an id on one side alone is red.
enum ConnectionActionRoute: String, CaseIterable {
    case versioning = "s3.versioning"
    case cors = "s3.cors"
    case objectLock = "s3.objectLock"
    case createBucket = "s3.createBucket"

    init?(action: ConnectionActionContribution) {
        self.init(rawValue: action.id)
    }

    /// Whether this connection can carry the action out now. A row is live
    /// only if its own condition holds; nothing here is shared between rows,
    /// so a later row's condition (a bucket-list-only gate) is an arm of its
    /// own.
    func isAvailable(in context: ConnectionActionContext) -> Bool {
        switch self {
        case .versioning:
            context.settings != nil && context.bucket != nil
        case .cors:
            context.settings != nil && context.bucket != nil
        case .objectLock:
            context.settings != nil && context.bucket != nil
        case .createBucket:
            // **The inverse of the three above.** Those are bucket-level
            // actions and are live where `bucket` is non-nil; this one makes a
            // bucket and is live only where there is none, at the list of
            // them. Copying a neighbour's condition gives a row that can never
            // be chosen. Two facts are needed and neither implies the other:
            // the root IS a list of buckets (`isOffered`, spec §6.1: a bucket
            // made in a connection rooted in one bucket would be invisible
            // afterwards), and the pane is standing at that list rather than
            // inside one of its buckets.
            context.settings != nil
                && CreateBucketModel.isOffered(rootIsContainerList: context.rootIsContainerList)
                && context.bucket == nil
        }
    }

    /// The one question the menu asks of a row: `false` for an id this table
    /// has no case for.
    static func isAvailable(
        _ action: ConnectionActionContribution, in context: ConnectionActionContext
    ) -> Bool {
        guard let route = ConnectionActionRoute(action: action) else { return false }
        return route.isAvailable(in: context)
    }
}
