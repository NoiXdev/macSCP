import Foundation

/// A column the file list can display (M11m). `name` is the one fixed,
/// always-visible column; the rest are user-toggleable via
/// `SettingsStore.visibleColumns`. Order here is the table's fixed display
/// order (Task 2 builds columns in `FileColumn.allCases` order, filtered to
/// what's visible) — it is NOT user-reorderable (M11m design, §5).
public enum FileColumn: String, Sendable, CaseIterable {
    case name
    case size
    case modified
    case permissions
    case owner
    case group
    case type
    /// What the user asked this tab to compute, and nothing else
    /// (2026-09-02). Unlike every column above it, this one is not read off
    /// the listing: a listing carries no digest, and computing one is an
    /// action the user takes per file. The cell is therefore empty until
    /// that action has happened for exactly these bytes — see
    /// `ChecksumLedger`, which is the only thing this column reads.
    case checksum

    /// `name` can never be hidden — every other column can (M11m design).
    public var isToggleable: Bool { self != .name }

    /// Visibility for a fresh install, and the forward-compat fallback when
    /// `settings.json` predates this feature: `name`/`size`/`modified`
    /// preserve today's three fixed columns exactly; every other one starts
    /// OFF until the user opts in.
    public var defaultVisible: Bool {
        switch self {
        case .name, .size, .modified: return true
        case .permissions, .owner, .group, .type, .checksum: return false
        }
    }
}

/// Pure, testable per-column text formatters for the columns M11m adds.
/// `name`/`size`/`modified` already have their own established formatting
/// (`FileListFormatter`) and are untouched here. `type` is deliberately
/// NOT formatted to text in Core: a localized type label ("Folder"/"File"/
/// "Alias"/…) is a display word, and Core stays free of hardcoded
/// user-facing strings (see this project's language policy) — the App
/// layer switches on `RemoteFileItem.kind` directly and looks up its own
/// localized catalog entry.
public enum FileColumnFormatter {
    /// The rwx string via `PosixPermissions`, e.g. "rw-r--r--"; `nil` if
    /// the item carries no permission bits at all.
    public static func permissionsText(for item: RemoteFileItem) -> String? {
        guard let permissions = item.permissions else { return nil }
        return PosixPermissions(rawValue: permissions).rwxString
    }

    /// Raw owner text: a resolved name, the numeric uid/gid as a string, or
    /// `nil` — exactly what `RemoteFileItem.owner` already carries per the
    /// M11m data-source rules. The App layer substitutes its own localized
    /// placeholder ("—") for `nil`.
    public static func ownerText(for item: RemoteFileItem) -> String? { item.owner }

    /// Same idea as `ownerText`, for the group.
    public static func groupText(for item: RemoteFileItem) -> String? { item.group }

    /// The digest the user already asked for, under `algorithm`, as the hex
    /// it was recorded as — or `nil`, which the cell renders as nothing at
    /// all (2026-09-02).
    ///
    /// This is a pure lookup. Nothing here computes, requests, or schedules
    /// a checksum, and there is no parameter through which it could: it is
    /// handed a `ChecksumLedger` by value, and a ledger only ever holds what
    /// a request already produced. So drawing this column — or scrolling it,
    /// or switching it on — cannot cause any work on the far side.
    ///
    /// The kind is asked here rather than left to the ledger. A directory
    /// has no digest, and a column that would show one for a directory if
    /// the ledger ever held one is a column whose emptiness depends on
    /// another type's discipline instead of on its own.
    public static func checksumText(
        for item: RemoteFileItem,
        in ledger: ChecksumLedger,
        algorithm: ChecksumAlgorithm
    ) -> String? {
        guard item.kind == .file else { return nil }
        return ledger.value(for: item, algorithm: algorithm)?.hex
    }
}
