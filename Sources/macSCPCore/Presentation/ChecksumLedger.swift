import Foundation

/// What the user has asked this tab to compute, remembered per file.
///
/// Nothing in this type computes a checksum. It only remembers the result of
/// a request that already happened (`ChecksumBatch`, driven by the
/// context-menu action and the info sheet) so a later column can show it
/// without asking again. A row that was never asked about reads as absent —
/// there is no default, no placeholder, and no background fill.
///
/// The key is `(path, size, modifiedAt)`, not `path` alone: a value recorded
/// for one set of bytes must not survive under the same path once the file
/// changed underneath it. `size` and `modifiedAt` are both optional on
/// `RemoteFileItem`, and two items that both carry `nil` in one of those
/// fields compare equal on it here — deliberately. A listing that carries
/// neither figure cannot tell two versions of a file apart either; the
/// ledger has exactly the same blindness as the data it is fed, not less.
public struct ChecksumLedger: Sendable, Equatable {
    private struct Identity: Sendable, Equatable, Hashable {
        let path: String
        let size: UInt64?
        let modifiedAt: Date?
    }

    private var entries: [Identity: [ChecksumAlgorithm: FileChecksum]] = [:]

    public init() {}

    /// Records `result` for `item`, unless it is not a checksum that
    /// describes the file's bytes.
    ///
    /// `.unavailableOnThisConnection` and `.failed` say nothing about any
    /// digest and are silently dropped. A `.checksum` whose provenance does
    /// not describe file content — a multipart object-storage ETag — is
    /// dropped the same way the info sheet already refuses to call it a
    /// checksum: the ledger stores only what the sheet itself would show as
    /// one.
    public mutating func record(_ result: ChecksumRequestResult, for item: RemoteFileItem) {
        guard case .checksum(let value) = result, value.describesFileContent else { return }
        let identity = Identity(path: item.path, size: item.size, modifiedAt: item.modifiedAt)
        entries[identity, default: [:]][value.algorithm] = value
    }

    /// The last value recorded for `item` under `algorithm`, or `nil` if
    /// none was recorded for exactly this file identity and this algorithm.
    public func value(for item: RemoteFileItem, algorithm: ChecksumAlgorithm) -> FileChecksum? {
        let identity = Identity(path: item.path, size: item.size, modifiedAt: item.modifiedAt)
        return entries[identity]?[algorithm]
    }

    /// Drops every recorded value for `path`, under every identity and every
    /// algorithm — used when the path itself is gone (deleted, renamed away)
    /// rather than merely changed.
    public mutating func forget(path: String) {
        entries = entries.filter { $0.key.path != path }
    }
}
