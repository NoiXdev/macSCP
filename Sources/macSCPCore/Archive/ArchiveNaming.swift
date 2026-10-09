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

    /// A name as the file system compares it. APFS ignores case and
    /// normalization form, and so do most desktop file systems; a remote
    /// server may not. Folding both sides over-reports there, which is the
    /// safe direction for every question asked of it: a collision warned
    /// about but not real costs the user a different name, where the
    /// opposite error leaves an entry silently skipped (`unzip -n` and
    /// `tar --keep-old-files` both skip `a.txt` beside an existing
    /// `A.txt`, measured by the reviewer 2026-10-09; the sentence named that
    /// one tar flag when a tar extraction could only be given it, and a
    /// remote one is now given `--skip-old-files` instead when the far side
    /// takes it -- see `TarSkipExisting`) or an existing archive
    /// opened by `zip` / truncated by `tar -czf`.
    ///
    /// This lives here, not at a caller: only the code holding both sets can
    /// fold them, and a caller cannot know whether a remote file system is
    /// case-sensitive.
    static func folded(_ name: String) -> String {
        name.lowercased().precomposedStringWithCanonicalMapping
    }

    /// Whether `name` is one of `names` the way the file system compares.
    static func isTaken(_ name: String, among names: Set<String>) -> Bool {
        let key = folded(name)
        return names.contains { folded($0) == key }
    }

    /// `free(_:takenNames:)` under the folded comparison, without changing
    /// `free`'s own contract. Handing `free` a folded set would not work: it
    /// compares its own candidates, `Backup`, `Backup 2`, as written, and a
    /// folded set holds `backup`. So `free` is asked repeatedly instead:
    /// every candidate the folded comparison rejects is added to the taken
    /// set, and `free` then proposes the next counter. The proposal's own
    /// casing survives in the result.
    static func freeFolded(_ proposed: String, takenNames: Set<String>) -> String {
        let takenFolded = Set(takenNames.map(folded(_:)))
        var taken = takenNames
        var candidate = free(proposed, takenNames: taken)
        while takenFolded.contains(folded(candidate)) {
            taken.insert(candidate)
            candidate = free(proposed, takenNames: taken)
        }
        return candidate
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
