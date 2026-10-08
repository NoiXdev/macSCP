import Foundation

/// Choosing the name an archive gets, and keeping it off an existing one.
///
/// Pure, and separate from `ArchivePlan` on purpose: the name is what the
/// dialog shows the user BEFORE anything runs, so it has to be computable
/// without a channel, a process, or a directory listing beyond the names
/// the pane already holds.
public enum ArchiveNaming {
    /// The name to propose for an archive of `format` over `selection`.
    ///
    /// One object lends its WHOLE name, extension included: compressing
    /// `notes.txt` gives `notes.txt.tar.gz`, not `notes.tar.gz`, because the
    /// second loses which file came back out.
    public static func proposedName(
        format: ArchiveFormat, selection: [RemoteFileItem]
    ) throws -> String {
        guard let first = selection.first else { throw ArchiveRefusal.emptySelection }
        if format == .gz {
            guard selection.count == 1 else {
                throw ArchiveRefusal.gzTakesExactlyOneFile(count: selection.count)
            }
            guard first.kind == .file else {
                throw ArchiveRefusal.gzTakesAFileNotAFolder(name: first.name)
            }
        }
        let stem = selection.count == 1
            ? first.name
            : CoreL10n.string("core.archive.defaultName")
        return stem + "." + format.fileExtension
    }

    /// `proposed`, or the first name beside it that `takenNames` does not
    /// hold.
    ///
    /// The counter goes before the WHOLE extension — `a 2.tar.gz`, never
    /// `a.tar 2.gz` — which is why this splits on the known archive
    /// extensions rather than on the last dot.
    public static func free(_ proposed: String, takenNames: Set<String>) -> String {
        guard takenNames.contains(proposed) else { return proposed }
        let (stem, ext) = split(proposed)
        var counter = 2
        while true {
            let candidate = "\(stem) \(counter)\(ext)"
            if !takenNames.contains(candidate) { return candidate }
            counter += 1
        }
    }

    /// `name` as (stem, extension-with-its-dot). The extension is one of the
    /// known archive extensions or empty; an unknown trailing component is
    /// left in the stem, so a folder called `report.2026` counts up as
    /// `report.2026 2`.
    private static func split(_ name: String) -> (String, String) {
        let known = ["tar.gz", "tgz", "tar", "zip", "gz"]
        let lower = name.lowercased()
        for ext in known where lower.hasSuffix("." + ext) {
            let cut = name.index(name.endIndex, offsetBy: -(ext.count + 1))
            return (String(name[name.startIndex..<cut]), String(name[cut...]))
        }
        return (name, "")
    }
}
