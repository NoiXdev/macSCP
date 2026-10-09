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
    /// Both tools are given their SKIP-EXISTING flag, `unzip -n` and
    /// `tar --keep-old-files`, so nothing is overwritten even when the
    /// directory changed between the dialog and the run. The count the
    /// dialog shows comes from a listing, because neither tool reports what
    /// it skipped.
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
    /// Consequence, so it is not misdiagnosed: on the remote path a tar
    /// extraction onto a colliding name is reported as
    /// `ArchiveFailure.exited(status: 2)` today although the data is fine and
    /// every other entry was extracted. That is a known open row in
    /// `docs/BACKLOG.md` ("Remote tar extraction onto an existing name
    /// fails, because the skip-existing flag is the GNU one that errors"),
    /// not a regression of this code, and this function deliberately does
    /// not branch on the flavour.
    ///
    /// The archive's own name is the one user-controlled word on an
    /// extraction, and it is prefixed `./` rather than terminated with
    /// `--`: a name beginning with a dash is then not an option to any of
    /// these tools. `--` is measured for `gzip` and `gunzip` (both
    /// 2026-10-08), not for `unzip` or `tar`, which is why those two get
    /// the prefix.
    public static func extract(
        _ archive: RemoteFileItem, format: ArchiveExtractFormat,
        workingDirectory: String, into destination: ExtractDestination
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
            words = [.flag("--keep-old-files"), read, source]
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
}
