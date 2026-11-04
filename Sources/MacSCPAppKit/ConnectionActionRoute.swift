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
            // be chosen. The rule itself is the model's (`isOffered`): the root
            // is a list of buckets and the pane is standing at that list, not
            // inside one of its buckets. This arm only supplies the facts.
            context.settings != nil
                && CreateBucketModel.isOffered(
                    rootIsContainerList: context.rootIsContainerList, paneBucket: context.bucket)
        }
    }

    /// The contribution `route` has in the backend `kind` speaks, or `nil`
    /// when that backend contributes none.
    ///
    /// **The one place a route is looked up by backend.** The id is the key
    /// and the descriptor is the author: nothing here asks which kind it is.
    /// `ContentView.openCreateContainerSheet(in:session:)` and `isOffered
    /// (onStored:)` below both read it, so "does this backend have such an
    /// action" has one spelling.
    static func contribution(
        of route: ConnectionActionRoute, for kind: ConnectionKind
    ) -> ConnectionActionContribution? {
        BackendDescriptor.descriptor(for: kind).connectionActions.first {
            ConnectionActionRoute(action: $0) == route
        }
    }

    /// Whether the connection manager offers this action on a STORED
    /// connection, which has no tab, no session and no listing to ask.
    ///
    /// **This is not `isAvailable(in:)` and does not repeat it.** That one
    /// answers a question about a live connection, from a context that needs
    /// a session. This one can only read what a stored record says, so it
    /// supplies those facts to the same rule: the backend contributes the
    /// action (the descriptor, by id), and the model's `isOffered` is asked.
    ///
    /// **Only one half of that rule varies here.** `CreateBucketModel
    /// .isOffered` is a conjunction of the root being a list of buckets and the
    /// pane standing inside none. A freshly opened connection stands at the
    /// root, so the second half is `paneBucket: nil` BY CONSTRUCTION -- a
    /// literal passed in, not something read from the record and not something
    /// this function asks of anything -- and the verdict varies with
    /// `rootIsContainerList` alone, which is the record's `startsAtBucketList`.
    /// The call is still made, so a later change to the model's rule is seen
    /// here; what it cannot see is a change to WHICH half is constant.
    ///
    /// A `switch` with no `default`, so a route added later has to say
    /// whether it belongs on this surface. The three bucket-level actions do
    /// not: they need a bucket, and a stored connection stands in none.
    func isOffered(onStored session: StoredSession) -> Bool {
        switch self {
        case .versioning, .cors, .objectLock:
            false
        case .createBucket:
            Self.contribution(of: self, for: session.kind) != nil
                && CreateBucketModel.isOffered(
                    rootIsContainerList: session.s3?.startsAtBucketList ?? false,
                    paneBucket: nil)
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
