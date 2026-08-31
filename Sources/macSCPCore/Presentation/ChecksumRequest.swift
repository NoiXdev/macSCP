import Foundation

/// What asking one file for its checksum came to, as a surface sees it.
///
/// Three cases, because the backends give three kinds of answer and
/// collapsing any two of them would make the display say something untrue:
///
/// - a value, which always carries its own algorithm and its own origin;
/// - "this connection cannot answer" — a statement about the connection,
///   which is why it is a case rather than a failure (see
///   `RemoteChecksumOutcome.unavailableOnThisConnection`);
/// - a failure about THIS file, which says nothing about the next one.
///
/// The message in `.failed` is already localized: it is produced by the
/// same `RemoteBrowserViewModel.message(for:path:)` every other browse
/// action's error goes through, so a checksum failure reads like a rename
/// failure instead of like a second dialect.
public enum ChecksumRequestResult: Sendable, Equatable {
    case checksum(FileChecksum)
    case unavailableOnThisConnection
    case failed(String)
}

/// Whether a backend can be OFFERED the checksum action at all.
///
/// This reads `ProtocolCapabilities.supportsRemoteChecksum` and nothing
/// else. It exists as a named function rather than as an expression at the
/// call site so that "the offer follows the capability" is a property a
/// test can hold, instead of a habit a view is trusted to keep.
///
/// Note what it must NOT be: a `switch` over `ConnectionKind`. Every
/// backend conforms to `RemoteChecksumProvider` — WebDAV included, and
/// deliberately, so that a caller which asks anyway gets a statement rather
/// than `nil` — so the `as?` cast cannot separate a backend that has an
/// answer from one that has none. The flag is the only thing that can, and
/// that is what it is for.
public enum ChecksumAvailability {
    public static func isOffered(for kind: ConnectionKind) -> Bool {
        BackendDescriptor.descriptor(for: kind).capabilities.supportsRemoteChecksum
    }

    /// The LOCAL pane's answer, which cannot be the one above: "local" is
    /// not a `ConnectionKind`, so there is no descriptor and no flag to
    /// read. What stands in its place is the conformance, and here — unlike
    /// for a remote backend — the conformance really is the question: a
    /// local file system that answers checksums does so for every file.
    ///
    /// The parameter is the existential rather than a concrete type on
    /// purpose. It is what makes this a question at the call site instead
    /// of a cast the compiler already knows the answer to.
    public static func isOffered(byLocalFileSystem fileSystem: any RemoteFileSystem) -> Bool {
        fileSystem is any RemoteChecksumProvider
    }
}
