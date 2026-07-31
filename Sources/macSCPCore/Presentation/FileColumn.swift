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

    /// `name` can never be hidden — every other column can (M11m design).
    public var isToggleable: Bool { self != .name }

    /// Visibility for a fresh install, and the forward-compat fallback when
    /// `settings.json` predates this feature: `name`/`size`/`modified`
    /// preserve today's three fixed columns exactly; the four new ones
    /// start OFF until the user opts in.
    public var defaultVisible: Bool {
        switch self {
        case .name, .size, .modified: return true
        case .permissions, .owner, .group, .type: return false
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
}
