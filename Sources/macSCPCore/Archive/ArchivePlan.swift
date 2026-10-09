import Foundation

/// One word of an archive command, carrying whether it is OURS or the
/// user's.
///
/// This is the feature's safety boundary, expressed as a type rather than as
/// a rule. A `.flag` is this project's own fixed vocabulary, written in this
/// file and nowhere else. An `.operand` is user-controlled. The local
/// rendering passes both as argv elements — `Process` takes an array, so no
/// shell parses either — and the remote rendering quotes every `.operand`
/// and no `.flag`. Neither renderer decides which is which; the value
/// already says.
public enum ArchiveWord: Sendable, Equatable {
    case flag(String)
    case operand(String)
}

/// How a `tar` is told not to overwrite a file that is already there.
///
/// **There is no flag both tars accept that is silent at exit 0**, which is
/// why this is a value a caller has to carry rather than a constant in a
/// plan. Measured 2026-10-09, three times independently and again here:
/// - bsdtar 3.5.3 (`/usr/bin/tar` on macOS, the LOCAL side) takes
///   `--keep-old-files`: keeps the old file, extracts the rest, silent,
///   exit 0. It REJECTS the other one — `tar: Option --skip-old-files is
///   not supported`, exit 1.
/// - GNU tar 1.35 (the rig, i.e. a typical remote) takes both, but
///   `--keep-old-files` prints `tar: a: Cannot open: File exists` and exits
///   **2** over a collision, where `--skip-old-files` is silent at exit 0
///   over the same input and leaves the same data.
///
/// So `.keepOldFiles` is the answer that is always SAFE (neither flavour
/// overwrites) and `.skipOldFiles` is the answer that is also QUIET, and the
/// difference is only visible once something collides.
/// `ArchivePreparation.tarSkipExisting(in:runner:)` measures which one the
/// far side takes.
public enum TarSkipExisting: Sendable, Equatable, CaseIterable {
    /// GNU tar's flag: silent, exit 0. bsdtar rejects it.
    case skipOldFiles
    /// The flag BOTH flavours accept, and neither overwrites under. On GNU
    /// tar it is the one that exits 2 over a collision.
    case keepOldFiles

    /// The flag as it is written on a command line.
    public var flag: String {
        switch self {
        case .skipOldFiles: "--skip-old-files"
        case .keepOldFiles: "--keep-old-files"
        }
    }
}

/// What one archive operation will run, as a value: no channel, no process,
/// no connection.
///
/// `stdin` carries the SELECTION for the formats whose tool reads names from
/// standard input, so an arbitrary file name never becomes a word of a
/// command. `zip -@` is newline-separated and `tar --null -T -` is
/// NUL-separated, both measured 2026-10-08; the difference is why
/// `ArchiveRefusal.newlineInNameUnsupportedByZip` exists.
public struct ArchivePlan: Sendable, Equatable {
    public let operation: ArchiveOperation
    public let workingDirectory: String
    public let tool: String
    public let words: [ArchiveWord]
    public let stdin: Data?

    /// What a local run needs: an executable, argv, a directory, and bytes.
    public struct LocalInvocation: Sendable, Equatable {
        public let executable: URL
        public let arguments: [String]
        public let currentDirectory: URL
        public let stdin: Data?
    }

    /// This plan as a local invocation. No quoting happens here and none is
    /// needed: `SubprocessRunner.run` takes `arguments: [String]` straight
    /// to `Process`, which passes them to `execve` as separate elements.
    /// There is no shell on this path at all.
    public func localInvocation(
        resolvingToolWith resolve: (String) -> String
    ) throws -> LocalInvocation {
        LocalInvocation(
            executable: URL(fileURLWithPath: resolve(tool)),
            arguments: words.map { word in
                switch word {
                case .flag(let value), .operand(let value): value
                }
            },
            currentDirectory: URL(fileURLWithPath: workingDirectory),
            stdin: stdin)
    }

    /// The plan that creates `archiveName` out of `selection`.
    ///
    /// `archiveName` is the caller's, from `ArchiveNaming` — it is not
    /// derived here, because the dialog shows it to the user before anything
    /// runs and the two must be the same string.
    ///
    /// The name is derived from the selected item's own name, so it can begin
    /// with a dash; in the `zip` and `tar` plans it goes in prefixed `./`
    /// (measured 2026-10-08: `zip` rejects a bare `-v2.zip` with exit 16,
    /// the `./` form works for both tools). The `gzip` plan terminates its
    /// options with `--` instead.
    public static func compress(
        _ format: ArchiveFormat, selection: [RemoteFileItem],
        workingDirectory: String, archiveName: String
    ) throws -> ArchivePlan {
        guard !selection.isEmpty else { throw ArchiveRefusal.emptySelection }
        switch format {
        case .zip:
            // One path per line, so a name holding a newline cannot be
            // passed at all — it would arrive as two names.
            for item in selection where item.name.contains("\n") {
                throw ArchiveRefusal.newlineInNameUnsupportedByZip(name: item.name)
            }
            return ArchivePlan(
                operation: .compress(format), workingDirectory: workingDirectory,
                tool: "zip",
                words: [.flag("-r"), .flag("-@"), .operand("./" + archiveName)],
                stdin: Data(selection.map(\.name).joined(separator: "\n").utf8) + Data([0x0A]))
        case .tarGz:
            var bytes = Data()
            for item in selection {
                bytes.append(Data(item.name.utf8))
                bytes.append(0x00)
            }
            return ArchivePlan(
                operation: .compress(format), workingDirectory: workingDirectory,
                tool: "tar",
                words: [
                    .flag("--null"), .flag("-T"), .flag("-"),
                    .flag("-czf"), .operand("./" + archiveName),
                ],
                stdin: bytes)
        case .gz:
            // Checked here AND in `ArchiveNaming.proposedName`, deliberately:
            // the dialog calls the naming to show a name before anything
            // runs, and a later caller could reach `compress` without having
            // gone through it. Two guards over one rule, not a leftover.
            guard selection.count == 1 else {
                throw ArchiveRefusal.gzTakesExactlyOneFile(count: selection.count)
            }
            let only = selection[0]
            guard only.kind == .file else {
                throw ArchiveRefusal.gzTakesAFileNotAFolder(name: only.name)
            }
            // `-k` keeps the input: maintainer decision 4, and the reason no
            // menu entry here destroys its source. `--` is measured against
            // gzip (2026-10-08) and is safe for a name beginning with a dash.
            return ArchivePlan(
                operation: .compress(format), workingDirectory: workingDirectory,
                tool: "gzip",
                words: [.flag("-k"), .flag("--"), .operand(only.name)],
                stdin: nil)
        }
    }

    /// The plan that compresses `selection` under a name that is free in the
    /// folder, and that refuses what a tool would refuse.
    ///
    /// `namesInFolder` must be the names the FILE SYSTEM returned, not the
    /// names a pane shows: a pane that hides dotfiles would otherwise offer
    /// `.env.zip` over a real `.env.zip`, which `zip` would open and add to
    /// and `tar -czf` would truncate. Free is judged the way the file system
    /// compares (`ArchiveNaming.freeFolded`), because `tar -czf` truncates a
    /// differently-cased `Backup.tar.gz` on a case-insensitive volume.
    ///
    /// A `.gz` is the exception to "pick a free name": `gzip -k` writes
    /// `<name>.gz` and takes no say in it, so a name that is not free cannot
    /// be counted up -- it is refused. `gzip` refuses itself (measured
    /// 2026-10-08: `gzip: f.gz already exists -- skipping`, exit 1, target
    /// untouched); macSCP says so before running instead of surfacing that
    /// line.
    public static func compress(
        _ format: ArchiveFormat, selection: [RemoteFileItem],
        workingDirectory: String, namesInFolder: Set<String>
    ) throws -> ArchivePlan {
        let proposed = try ArchiveNaming.proposedName(format: format, selection: selection)
        if format == .gz {
            guard !ArchiveNaming.isTaken(proposed, among: namesInFolder) else {
                throw ArchiveRefusal.gzTargetExists(name: proposed)
            }
            return try compress(
                format, selection: selection, workingDirectory: workingDirectory,
                archiveName: proposed)
        }
        return try compress(
            format, selection: selection, workingDirectory: workingDirectory,
            archiveName: ArchiveNaming.freeFolded(proposed, takenNames: namesInFolder))
    }

    /// The plan that unpacks `archive` into `destination`.
    ///
    /// Both tools are given their SKIP-EXISTING flag, `unzip -n` and the
    /// `tar` flag `tarSkipExisting` names, so nothing is overwritten even
    /// when the directory changed between the dialog and the run. The count
    /// the dialog shows comes from a listing, because neither tool reports
    /// what it skipped.
    ///
    /// Corrected 2026-10-09 (final whole-branch review). This comment first
    /// read: "Measured 2026-10-08: both keep the old file, extract the rest,
    /// and exit 0 — and BOTH ARE SILENT about what they skipped". That is
    /// false for one of the three tools; what was measured, per tool:
    /// - `unzip -n`: keeps the old file, extracts the rest, names only what
    ///   it extracted (never what it skipped), exit 0.
    /// - bsdtar 3.5.3 (the LOCAL side), `--keep-old-files`: keeps the old
    ///   file, extracts the rest, silent, exit 0. It rejects
    ///   `--skip-old-files` outright (`Option --skip-old-files is not
    ///   supported`), so this flag is the only one both tars accept.
    /// - GNU tar 1.35 (the REMOTE side, the rig), `--keep-old-files`: keeps
    ///   the old file, extracts the rest, prints `tar: a: Cannot open: File
    ///   exists` and **exits 2**. `--skip-old-files` on the same input is
    ///   silent, exit 0, same data.
    ///
    /// Corrected again 2026-10-09, by the family fix that answered the three
    /// "a tool's own answer differs from what one flavour was measured to
    /// say" findings together. This comment used to end the paragraph above
    /// with: "Consequence, so it is not misdiagnosed: on the remote path a
    /// tar extraction onto a colliding name is reported as
    /// `ArchiveFailure.exited(status: 2)` today although the data is fine and
    /// every other entry was extracted. That is a known open row in
    /// `docs/BACKLOG.md` … not a regression of this code, and this function
    /// deliberately does not branch on the flavour." It does branch on it
    /// now: `tarSkipExisting` is measured by
    /// `ArchivePreparation.tarSkipExisting(in:runner:)` in the same round
    /// trip as the listing the dialog is built from, and `TarSkipExisting`
    /// carries the measurement. Nothing maps a status: exit 2 still means
    /// exit 2, and still fails.
    ///
    /// The archive's own name is the one user-controlled word on an
    /// extraction, and it is prefixed `./` rather than terminated with
    /// `--`: a name beginning with a dash is then not an option to any of
    /// these tools. `--` is measured for `gzip` and `gunzip` (both
    /// 2026-10-08), not for `unzip` or `tar`, which is why those two get
    /// the prefix.
    public static func extract(
        _ archive: RemoteFileItem, format: ArchiveExtractFormat,
        workingDirectory: String, into destination: ExtractDestination,
        tarSkipExisting: TarSkipExisting
    ) throws -> ArchivePlan {
        let source = ArchiveWord.operand("./" + archive.name)
        var words: [ArchiveWord]
        let tool: String
        switch format {
        case .zip:
            tool = "unzip"
            words = [.flag("-n"), .flag("-q"), source]
            if case .subfolder(let name) = destination {
                words += [.flag("-d"), .operand("./" + name)]
            }
        case .tar, .tarGz:
            tool = "tar"
            let read: ArchiveWord = format == .tarGz ? .flag("-xzf") : .flag("-xf")
            words = [.flag(tarSkipExisting.flag), read, source]
            if case .subfolder(let name) = destination {
                words += [.flag("-C"), .operand("./" + name)]
            }
        case .gz:
            // Withdrawn from this plan's first draft, which read: "a
            // subfolder destination is carried out by the runner creating
            // the folder and running there; the plan's working directory is
            // what the caller passes." That does not work -- run inside the
            // new subfolder, `gunzip` would not find the archive, which sits
            // in the parent. It cannot be given a destination at all
            // without a redirection, so the combination is refused.
            guard destination == .thisFolder else {
                throw ArchiveRefusal.gzExtractsIntoThisFolderOnly
            }
            tool = "gunzip"
            words = [.flag("-k"), .flag("--"), .operand("./" + archive.name)]
        }
        return ArchivePlan(
            operation: .extract(format), workingDirectory: workingDirectory,
            tool: tool, words: words, stdin: nil)
    }

    /// The plan that unpacks `archive` into `destination`, refusing what the
    /// tool would refuse.
    ///
    /// The mirror of `compress(_:selection:workingDirectory:namesInFolder:)`,
    /// and deliberately the same shape: the overload that is given what the
    /// FOLDER holds is the one that can refuse, and the plainer one above
    /// stays for a caller that has already decided. `preview` is where the
    /// folder's answer lives, counted over the names the file system
    /// returned.
    ///
    /// One refusal today, and it is the `.gz` one: `gunzip` writes its one
    /// file beside the archive, cannot be told another name, and exits 1
    /// over an existing one. Every other format's tool skips a collision at
    /// exit 0, so there is nothing to refuse there -- the dialog's note that
    /// existing files are not overwritten is the whole answer.
    public static func extract(
        _ archive: RemoteFileItem, format: ArchiveExtractFormat,
        workingDirectory: String, into destination: ExtractDestination,
        tarSkipExisting: TarSkipExisting, preview: ExtractPreview
    ) throws -> ArchivePlan {
        if let taken = preview.takenGzOutput {
            throw ArchiveRefusal.gzExtractTargetExists(name: taken)
        }
        return try extract(
            archive, format: format, workingDirectory: workingDirectory,
            into: destination, tarSkipExisting: tarSkipExisting)
    }

    /// The plan that asks the far side's `tar` whether it takes
    /// `--skip-old-files`, by its EXIT STATUS and nothing else.
    ///
    /// **Why a capability question and not `tar --version`.** The version
    /// line distinguishes the two flavours by brand — `bsdtar 3.5.3 -
    /// libarchive …` against `tar (GNU tar) 1.35`, measured 2026-10-09 on
    /// the host and in the rig — and then needs a third answer for every
    /// text that is neither, which is a guess about a tar nobody measured.
    /// This plan asks the thing the plan actually needs to know, and the two
    /// answers are the two cases of `TarSkipExisting`. Measured 2026-10-09:
    /// `/usr/bin/tar --skip-old-files --version` on bsdtar 3.5.3 printed
    /// `tar: Option --skip-old-files is not supported` and exited **1**; the
    /// same line on GNU tar 1.35 in the rig printed its version banner and
    /// exited **0**. A tar that does not understand `--version` either
    /// exits non-zero and gets the flag both flavours accept, which is the
    /// safe answer rather than a wrong one.
    ///
    /// `operation` is `.extract(.tar)` because `ArchiveOperation` has no
    /// third kind and this plan is never started as an activity — nothing
    /// shows its title. It is run through a runner's `listing`, whose
    /// standard output is discarded here; see
    /// `ArchivePreparation.tarSkipExisting(in:runner:)`.
    public static func tarSkipExistingProbe(workingDirectory: String) -> ArchivePlan {
        ArchivePlan(
            operation: .extract(.tar), workingDirectory: workingDirectory,
            tool: "tar",
            words: [.flag("--skip-old-files"), .flag("--version")], stdin: nil)
    }
}
