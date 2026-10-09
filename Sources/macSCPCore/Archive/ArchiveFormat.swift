import Foundation

/// A format macSCP can CREATE. Deliberately smaller than what it can
/// extract: `.tar` is extractable and is not offered for compression,
/// because an uncompressed tarball is not what anyone picks from a menu
/// called "Compress".
public enum ArchiveFormat: String, Sendable, CaseIterable, Equatable {
    case zip, tarGz, gz

    /// The extension an archive of this format carries, without the dot.
    public var fileExtension: String {
        switch self {
        case .zip: "zip"
        case .tarGz: "tar.gz"
        case .gz: "gz"
        }
    }
}

/// A format macSCP can EXTRACT, read off a name's extension.
public enum ArchiveExtractFormat: Sendable, CaseIterable, Equatable {
    case zip, tar, tarGz, gz

    /// The format `name` claims by its extension, or `nil`.
    ///
    /// The order matters and is pinned by `tarGzIsNotReadAsGz`: `.tar.gz`
    /// and `.tgz` are tested BEFORE `.gz`, because every `.tar.gz` also
    /// ends in `.gz` and reading it as a single gzipped file would extract
    /// a tarball nobody asked for.
    ///
    /// Lower-cased for the comparison only: a server may hold `BACKUP.ZIP`,
    /// and the name itself is never rewritten.
    public static func detected(inName name: String) -> ArchiveExtractFormat? {
        let lower = name.lowercased()
        if lower.hasSuffix(".tar.gz") || lower.hasSuffix(".tgz") { return .tarGz }
        if lower.hasSuffix(".zip") { return .zip }
        if lower.hasSuffix(".tar") { return .tar }
        if lower.hasSuffix(".gz") { return .gz }
        return nil
    }
}

/// Which operation a plan carries out.
public enum ArchiveOperation: Sendable, Equatable {
    case compress(ArchiveFormat)
    case extract(ArchiveExtractFormat)
}

/// Where an extraction puts what it unpacks. The maintainer's decision of
/// 2026-10-08: the user is asked, so this is a value the dialog produces
/// and never a default a plan picks for itself.
public enum ExtractDestination: Sendable, Equatable {
    /// The directory the archive sits in.
    case thisFolder
    /// A new subfolder of it, by this name. The name is already free —
    /// `ArchiveNaming.free(_:takenNames:)` chose it.
    case subfolder(String)
}

/// Why a plan could not be made. Every case names what the user would have
/// to change, because each one is shown to them.
///
/// There is deliberately no "unknown archive format" case (removed 2026-10-09
/// by the final whole-branch review, after it had stood here with a sentence
/// in four languages and no throw site): `ArchivePlan.extract` takes an
/// `ArchiveExtractFormat`, so an unknown format cannot reach it, and the one
/// place that reads a name, `ArchiveExtractFormat.detected(inName:)`, answers
/// `nil` to the context menu, which then offers no extract entry at all.
public enum ArchiveRefusal: Error, Equatable, Sendable {
    case emptySelection
    case gzTakesExactlyOneFile(count: Int)
    case gzTakesAFileNotAFolder(name: String)
    /// `zip -@` reads ONE PATH PER LINE from stdin (`zip -h2`, measured
    /// 2026-10-08) and Info-ZIP offers no NUL-separated alternative, so a
    /// name holding a newline cannot be handed to it safely. `.tar.gz` and
    /// `.gz` are unaffected — `tar --null -T -` is NUL-separated.
    case newlineInNameUnsupportedByZip(name: String)
    /// `gunzip` writes its one file beside the archive and cannot be told a
    /// destination directory without a shell redirection this design does
    /// not build, so that format extracts into the archive's own folder or
    /// not at all. Enforced here as well as in the sheet, because a rule
    /// that lives only in a dialog is a rule the next caller skips.
    case gzExtractsIntoThisFolderOnly
    /// `gzip -k` refuses an existing target itself and leaves it untouched
    /// (measured 2026-10-08: `gzip: f.gz already exists -- skipping`, exit
    /// 1, target unchanged). macSCP says so before running rather than
    /// surfacing that line.
    case gzTargetExists(name: String)
    /// The mirror of the case above, on the way back: `gunzip -k` writes
    /// its one file beside the archive, takes no say in the name, and
    /// refuses an existing one -- measured 2026-10-09, local
    /// `/usr/bin/gunzip -k -- ./x.gz` with `x` present printed
    /// `gunzip: ./x already exists -- skipping`, exit 1, `x` unchanged, and
    /// the rig's BusyBox `gunzip` printed `can't open './x': File exists`,
    /// also exit 1, also unchanged. Nothing is lost either way; it is a
    /// protective outcome, and macSCP says so before running instead of
    /// showing a status. The `.gz` format has no subfolder option, so there
    /// is no second destination to offer instead.
    case gzExtractTargetExists(name: String)
}
