import Foundation

/// Formats RemoteFileItem fields for the file list. Pure, so it's testable.
/// Directories show "-" instead of their inode size (like WinSCP).
public enum FileListFormatter {
    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    public static func sizeString(for item: RemoteFileItem) -> String {
        guard !item.isDirectory, let size = item.size else { return "-" }
        return byteFormatter.string(fromByteCount: Int64(size))
    }

    public static func dateString(for item: RemoteFileItem) -> String {
        guard let date = item.modifiedAt else { return "-" }
        return dateFormatter.string(from: date)
    }

    public static func displayName(for item: RemoteFileItem) -> String {
        item.isDirectory ? item.name + "/" : item.name
    }
}
