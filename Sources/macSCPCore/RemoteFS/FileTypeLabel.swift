import Foundation

/// The "Type" column's cell text and sort key for one row (Browser Type
/// Column plan, 2026-09-04). Precedence, highest first:
///
/// 1. `item.isBucket` — "Bucket", regardless of `kind` (an S3 bucket row's
///    `kind` is `.directory`, since a bucket IS a kind of directory; this
///    check runs first so a bucket never falls through to "Folder").
/// 2. `.directory` — "Folder".
/// 3. `.symlink` — "Link".
/// 4. Otherwise, the name's LAST extension, uppercased — `archive.tar.gz`
///    labels "GZ", not "TAR.GZ". A name with no extension (`README`), or a
///    dotfile whose only dot is the leading one (`.bashrc`), has no
///    extension to show and labels "File".
///
/// `Kind` itself is never extended for this: the label is derived from
/// `RemoteFileItem.name` and `.isBucket`/`.kind` only, through the four
/// `core.fileType.*` catalog keys.
public enum FileTypeLabel {
    public static func label(for item: RemoteFileItem) -> String {
        if item.isBucket {
            return CoreL10n.string("core.fileType.bucket")
        }
        switch item.kind {
        case .directory:
            return CoreL10n.string("core.fileType.folder")
        case .symlink:
            return CoreL10n.string("core.fileType.link")
        case .file, .other:
            return extensionLabel(for: item.name)
        }
    }

    /// The comparator's key for `FileSortKey.type`. Identical to
    /// `label(for:)` today — kept as its own entry point so the sort key
    /// and the display text have somewhere to diverge later without every
    /// call site having to change which one it means.
    public static func sortKey(for item: RemoteFileItem) -> String {
        label(for: item)
    }

    private static func extensionLabel(for name: String) -> String {
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty else {
            return CoreL10n.string("core.fileType.file")
        }
        return ext.uppercased()
    }
}
