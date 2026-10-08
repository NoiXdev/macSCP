import Foundation

/// What the destination dialog needs to know before anything is extracted.
///
/// Pure. The two inputs are the archive's entry names — from a listing the
/// caller already ran, or `nil` for a `.gz`, whose single entry is its own
/// name — and the names the pane is already showing. Both are data the
/// caller has; this type runs nothing.
public struct ExtractPreview: Sendable, Equatable {
    /// How many entries the archive holds.
    public let entryCount: Int
    /// How many distinct names in this folder extraction would land on.
    /// Counted on the TOP path component, because that is what extraction
    /// creates here, and compared case- and normalization-insensitively.
    public let collidingHere: Int
    /// The free subfolder name to prefill.
    public let proposedSubfolder: String
    /// `false` for `.gz`: `gunzip` cannot be told a directory without a
    /// shell redirection this design does not build.
    public let allowsSubfolder: Bool

    public static func make(
        archiveName: String, format: ArchiveExtractFormat,
        archiveEntries: [String]?, namesInFolder: Set<String>
    ) -> ExtractPreview {
        let stem = Self.stem(of: archiveName, format: format)
        let entries = archiveEntries ?? [stem]
        let folded = Set(namesInFolder.map(Self.folded(_:)))
        let tops = Set(entries.compactMap(Self.topComponent(of:)).map(Self.folded(_:)))
        return ExtractPreview(
            entryCount: entries.count,
            collidingHere: tops.intersection(folded).count,
            proposedSubfolder: Self.freeName(stem, takenFolded: folded, taken: namesInFolder),
            allowsSubfolder: format != .gz)
    }

    /// A name as the file system compares it. APFS ignores case and
    /// normalization form, and so do most desktop file systems; a remote
    /// server may not. Folding both sides over-reports there, which is the
    /// safe direction: a collision warned about but not real costs the user
    /// a subfolder, where the opposite error leaves an entry silently
    /// skipped (`unzip -n` and `tar --keep-old-files` both skip `a.txt`
    /// beside an existing `A.txt`, measured by the reviewer 2026-10-09).
    ///
    /// This lives here, not at the caller: `make` is the one place that
    /// holds both sets, and a caller cannot know whether a remote file
    /// system is case-sensitive.
    private static func folded(_ name: String) -> String {
        name.lowercased().precomposedStringWithCanonicalMapping
    }

    /// `ArchiveNaming.free` under the folded comparison, without changing
    /// `free` (which compress naming shares). Handing `free` a folded set
    /// would not work: it compares its own candidates, `Backup`, `Backup 2`,
    /// as written, and a folded set holds `backup`. So `free` is asked
    /// repeatedly instead: every candidate the folded comparison rejects is
    /// added to the taken set, and `free` then proposes the next counter.
    /// The archive's own casing survives in the result.
    private static func freeName(
        _ stem: String, takenFolded: Set<String>, taken: Set<String>
    ) -> String {
        var taken = taken
        var candidate = ArchiveNaming.free(stem, takenNames: taken)
        while takenFolded.contains(folded(candidate)) {
            taken.insert(candidate)
            candidate = ArchiveNaming.free(stem, takenNames: taken)
        }
        return candidate
    }

    /// Whether `name` can be the new subfolder: ONE path component that is
    /// not blank. A separator would leave the folder the dialog is about,
    /// `.` and `..` name folders that already exist, and a newline or NUL
    /// is not a name any of the tools here is asked to take.
    public static func isUsableSubfolderName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != ".." else { return false }
        // Scalars, not Characters: "\r\n" is ONE Character and equals neither
        // "\r" nor "\n".
        return !name.unicodeScalars.contains { $0 == "/" || $0 == "\n" || $0 == "\r" || $0 == "\0" }
    }

    /// The first path component extraction creates in the target folder, or
    /// `nil` for an entry that names no such thing.
    ///
    /// Empty components and `.` are skipped, not taken as the top: `tar`
    /// lists an archive built from `.` as `./a` and `./`, and reading `.` as
    /// the top component would count nothing where real names are about to
    /// be hit — an under-report, the one direction this count must not be
    /// wrong in. A bare `./` entry has no component left and yields `nil`.
    private static func topComponent(of entry: String) -> String? {
        entry.split(separator: "/").first { $0 != "." }.map(String.init)
    }

    /// `archiveName` without the extension its format implies. `.tgz` is
    /// handled as well as `.tar.gz`, since both detect as `.tarGz`.
    private static func stem(of name: String, format: ArchiveExtractFormat) -> String {
        let candidates: [String]
        switch format {
        case .zip: candidates = [".zip"]
        case .tar: candidates = [".tar"]
        case .tarGz: candidates = [".tar.gz", ".tgz"]
        case .gz: candidates = [".gz"]
        }
        let lower = name.lowercased()
        for suffix in candidates where lower.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return name
    }
}

extension ArchivePlan {
    /// The plan that asks an archive what it holds, one entry per line.
    ///
    /// `unzip -Z1` and `tar -tzf` each print exactly that (measured
    /// 2026-10-08). This is the only archive plan whose STANDARD OUTPUT is
    /// read, which is why it is run through the runners' bounded `listing`
    /// and never through `run`.
    public static func listing(
        of archiveName: String, format: ArchiveExtractFormat, workingDirectory: String
    ) -> ArchivePlan {
        let source = ArchiveWord.operand("./" + archiveName)
        switch format {
        case .zip:
            return ArchivePlan(
                operation: .extract(format), workingDirectory: workingDirectory,
                tool: "unzip", words: [.flag("-Z1"), source], stdin: nil)
        case .tar, .tarGz:
            return ArchivePlan(
                operation: .extract(format), workingDirectory: workingDirectory,
                tool: "tar", words: [.flag(format == .tarGz ? "-tzf" : "-tf"), source],
                stdin: nil)
        case .gz:
            // This branch exists ONLY to keep the function total, and
            // nothing calls it: `ExtractPreview.make` is given `nil` entries
            // for this format and derives the one name itself. Its plan is
            // NOT a listing of names -- `gzip -l` prints sizes -- so a
            // caller that ran it and read the output as entries would be
            // wrong. Kept as a plan rather than made unreachable in the
            // type because `ArchiveExtractFormat` is shared with the
            // extract plan, which needs the `.gz` case.
            return ArchivePlan(
                operation: .extract(format), workingDirectory: workingDirectory,
                tool: "gzip", words: [.flag("-l"), .flag("--"), source], stdin: nil)
        }
    }
}
