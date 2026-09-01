import Foundation
import Synchronization

/// Formats RemoteFileItem fields for the file list. Pure, so it's testable.
/// Directories show "-" instead of their inode size (like WinSCP).
///
/// Both formatters are shared rather than built per call, and both are
/// wrapped in a `Mutex` rather than merely declared safe. Sharing is the
/// point: `sizeString` and `dateString` are reached from
/// `RemoteFileTableView`'s view-based data-source callback, which runs once
/// per visible row AND column, on every `reloadData` and continuously while
/// scrolling — so the call count for a single directory listing is bounded
/// by scrolling, not by the number of files. A Foundation formatter is
/// expensive to construct and cheap to reuse — that is why both of these
/// have always been stored; rebuilding one per cell would be a change in
/// timing behaviour dressed up as a concurrency fix.
///
/// `Mutex` rather than a suppression: neither class is thread-safe for
/// concurrent use, and `withLock` is the only way to reach the instance
/// inside, so the safety is one the compiler checks instead of one this
/// comment asserts. `Mutex<Value>` is `Sendable` regardless of `Value`.
///
/// `dateFormatter` is a `DateFormatter`, which THIS SDK already declares
/// `Sendable` — it is wrapped anyway so the file does not depend on which
/// toolchain builds it (the CI toolchain is older, and the two have already
/// disagreed on concurrency inference once; see
/// docs/superpowers/specs/2026-08-26-backlog-toolchain-deviation.md).
public enum FileListFormatter {
    private static let byteFormatter = Mutex<ByteCountFormatter>({
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }())

    private static let dateFormatter = Mutex<DateFormatter>({
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }())

    public static func sizeString(for item: RemoteFileItem) -> String {
        guard !item.isDirectory, let size = item.size else { return "-" }
        return byteFormatter.withLock { $0.string(fromByteCount: Int64(size)) }
    }

    public static func dateString(for item: RemoteFileItem) -> String {
        guard let date = item.modifiedAt else { return "-" }
        return dateFormatter.withLock { $0.string(from: date) }
    }

    public static func displayName(for item: RemoteFileItem) -> String {
        item.isDirectory ? item.name + "/" : item.name
    }
}
