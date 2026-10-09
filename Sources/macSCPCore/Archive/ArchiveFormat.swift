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
    /// `unzip` reads the ARCHIVE NAME it is given as a PATTERN, so a
    /// user-controlled name stops being a name. Not a shell injection --
    /// the single-quoting in `remoteCommandLine()` holds -- but the same
    /// class, and worse in one way: it is silent.
    ///
    /// Measured 2026-10-09 against UnZip 6.00 (the host's and the rig's), with
    /// the operand quoted exactly as `remoteCommandLine()` renders it. In a
    /// folder holding both the pattern-bearing archive and a second one its
    /// pattern matches:
    /// - `*`: `unzip -n -q './b*.zip'` answered "2 archives were
    ///   successfully processed.", exit 0, and extracted from BOTH; the
    ///   matching `unzip -Z1` printed both archives' entries, a blank line
    ///   after each, and that summary line.
    /// - `?`: the same, two archives.
    /// - `[`: `./x[a]y.zip` opened `xay.zip` -- a DIFFERENT archive, the
    ///   only one it matched -- exit 0, no summary line, nothing to notice.
    ///
    /// Not metacharacters there, measured the same way and listed so the set
    /// above is not widened on a guess: a lone `]` and a `\` are both taken
    /// literally and open the archive that is named.
    ///
    /// `unzip` offers no way to turn this off: a backslash escape, which its
    /// manual describes for MEMBER patterns, is not stripped from the
    /// archive name -- `unzip -Z1 './b\*.zip'` answered `cannot find or
    /// open ./b\*.zip, ./b\*.zip.zip or ./b\*.zip.ZIP.`, exit 9. So the
    /// name is refused rather than neutralised, per format, as
    /// `newlineInNameUnsupportedByZip` is. Refusing also refuses a name
    /// whose pattern happens to match only itself, which extracts correctly
    /// today; that is the cost, and the alternative is a rule that holds
    /// only while the folder does not change.
    ///
    /// `tar` does not glob the archive name and `zip` does not glob its
    /// output name (both measured 2026-10-08/09), so this is `unzip`'s
    /// alone -- the extract plan and the listing plan.
    case wildcardInNameUnsupportedByUnzip(name: String)
    /// The far side's `tar` answered for neither skip-existing flag, so
    /// there is no way to extract without risking an overwrite -- and this
    /// feature never overwrites.
    ///
    /// Measured 2026-10-09 in the rig against BusyBox v1.37.0, which is what
    /// an Alpine, OpenWrt or NAS remote runs: `busybox tar
    /// --skip-old-files --version` and `busybox tar --keep-old-files
    /// --version` both printed `tar: unrecognized option: …` and exited 1,
    /// and `busybox tar --keep-old-files -xf t.tar` extracted NOTHING and
    /// exited 1. Its own spelling, `-k`, is not an equivalent: over one
    /// colliding entry `busybox tar -k -xf t.tar` printed `tar: can't open
    /// 'f': File exists`, exited 1 and stopped there, leaving the
    /// non-colliding entry unextracted. So this refusal is where that tar
    /// lands, deliberately, rather than a third flag whose outcome was
    /// measured to be a failed, partial extraction.
    ///
    /// Carries no name: it is about the far side's tool, not about anything
    /// the user picked.
    case tarHasNoSkipExistingFlag
}
