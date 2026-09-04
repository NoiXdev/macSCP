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
    /// preserve today's three fixed columns exactly; `permissions`/`owner`/
    /// `group`/`checksum` start OFF until the user opts in (M11m's rule for
    /// a new column). `type` is a deliberate exception to that rule (Browser
    /// Type Column plan, 2026-09-04, Global Constraint: "defaults to
    /// visible") — ships pre-decided ON rather than opt-in, per the plan's
    /// own maintainer feedback that a bucket/kind glimpse belongs in the
    /// listing by default.
    ///
    /// Only a FRESH install (`SettingsStore.visibleColumns` with no stored
    /// `visibleColumns` key at all) sees this. An install that has ever
    /// written that key — even once, for an unrelated column — keeps its own
    /// stored set exactly as persisted; this flip does not retroactively add
    /// `.type` to it. See `SettingsStore.visibleColumns`'s doc comment for
    /// the fallback rule this feeds.
    public var defaultVisible: Bool {
        switch self {
        case .name, .size, .modified, .type: return true
        case .permissions, .owner, .group, .checksum: return false
        }
    }
}

/// Pure, testable per-column text formatters for the columns M11m adds.
/// `name`/`size`/`modified` already have their own established formatting
/// (`FileListFormatter`) and are untouched here. `type` is NOT formatted
/// here: a localized type label ("Folder"/"Bucket"/"PDF"/…) is a display
/// word, but that does not mean Core stays free of it — `FileTypeLabel`
/// (Browser Type Column, 2026-09-04), in `RemoteFS/FileTypeLabel.swift`,
/// derives it from `RemoteFileItem.isBucket`/`.kind`/`.name` through
/// `CoreL10n`'s own catalog, and the App layer reads that function's
/// result directly rather than switching on `kind` itself, which is what
/// this enum's own formatters below still do.
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
