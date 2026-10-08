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
    /// Every name in the folder, folded for the file system's comparison.
    /// Kept so a name the user TYPES can be checked against the same
    /// folder the count was made over, without asking for it again.
    private let takenFolded: Set<String>

    /// Whether `name`, as the user typed it, names something that already
    /// exists in this folder -- compared the way the file system compares,
    /// after trimming the way the sheet does before it hands the name back.
    ///
    /// The sheet prefills a free name but the field is editable, and a name
    /// that exists would merge the archive into that folder (or, where it is
    /// a file, make extraction fail). "Into a new folder" promises a new one,
    /// and the collision note is shown only for "this folder" on exactly
    /// that promise, so the sheet refuses a taken name instead of merging.
    public func isSubfolderNameTaken(_ name: String) -> Bool {
        takenFolded.contains(
            ArchiveNaming.folded(name.trimmingCharacters(in: .whitespaces)))
    }

    public static func make(
        archiveName: String, format: ArchiveExtractFormat,
        archiveEntries: [String]?, namesInFolder: Set<String>
    ) -> ExtractPreview {
        let stem = Self.stem(of: archiveName, format: format)
        let entries = archiveEntries ?? [stem]
        let folded = Set(namesInFolder.map(ArchiveNaming.folded(_:)))
        let tops = Set(entries.compactMap(Self.topComponent(of:)).map(ArchiveNaming.folded(_:)))
        return ExtractPreview(
            entryCount: entries.count,
            collidingHere: tops.intersection(folded).count,
            proposedSubfolder: ArchiveNaming.freeFolded(stem, takenNames: namesInFolder),
            allowsSubfolder: format != .gz,
            takenFolded: folded)
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
