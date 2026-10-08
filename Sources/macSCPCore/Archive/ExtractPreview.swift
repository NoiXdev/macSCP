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
    /// creates here.
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
        let tops = Set(entries.compactMap(Self.topComponent(of:)))
        return ExtractPreview(
            entryCount: entries.count,
            collidingHere: tops.intersection(namesInFolder).count,
            proposedSubfolder: ArchiveNaming.free(stem, takenNames: namesInFolder),
            allowsSubfolder: format != .gz)
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
            // Never used: `ExtractPreview.make` is given `nil` entries for
            // this format and derives the one name itself. Returning a plan
            // that lists the archive's own name keeps the function total
            // rather than trapping.
            return ArchivePlan(
                operation: .extract(format), workingDirectory: workingDirectory,
                tool: "gzip", words: [.flag("-l"), .flag("--"), source], stdin: nil)
        }
    }
}
