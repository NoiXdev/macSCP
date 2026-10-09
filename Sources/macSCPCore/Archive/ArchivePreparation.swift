import Foundation

/// What one pending extraction knows before anything runs: what the dialog
/// shows, and which skip-existing flag the far side's `tar` takes.
///
/// The two are made in one step because they are made in one round trip: the
/// dialog's listing is an `exec` on the far side, and the flavour probe is
/// one more cheap `exec` beside it. A second trip at extraction time would
/// be a round trip the user waits for after pressing Extract.
public struct ExtractPreparation: Sendable, Equatable {
    /// What the dialog shows.
    public let preview: ExtractPreview
    /// Which flag `ArchivePlan.extract` gives `tar`, measured on the far
    /// side for `.tar` and `.tar.gz`.
    ///
    /// For a `.zip` or a `.gz` no probe is run — their plans name no `tar`
    /// flag at all — and this is `.keepOldFiles`. Fix round 2 scoped what
    /// that is worth: this comment read "`.keepOldFiles`, the flag both
    /// flavours accept and neither overwrites under, so reading it cannot
    /// produce an unsafe plan", and the second half is withdrawn. It is the
    /// flag the two MEASURED flavours accept; BusyBox tar 1.37.0 rejects it
    /// (measured 2026-10-09, see
    /// `ArchiveRefusal.tarHasNoSkipExistingFlag`). What is still true, and
    /// is the only claim this field needs, is that no plan for those two
    /// formats reads it.
    public let tarSkipExisting: TarSkipExisting
}

/// What happens between the menu entry and `ArchiveActivity.start`: the
/// folder is read as the FILE SYSTEM has it, a plan is made against that,
/// and the directory an extraction needs is created.
///
/// Free functions over a file system rather than methods on a view model,
/// so they can be proved against a real directory without a window.
public enum ArchivePreparation {
    /// The names in `directory` exactly as the file system returns them.
    ///
    /// **Not the names a pane is showing.** A pane filters dotfiles out of
    /// its table when `showHiddenFiles` is off, and a collision count built
    /// from that table under-reports an `.env`-style name -- the one
    /// direction this feature is not allowed to be wrong in.
    static func namesInFolder(
        _ directory: String, fileSystem: any RemoteFileSystem
    ) async throws -> Set<String> {
        Set(try await fileSystem.list(path: directory).map(\.name))
    }

    /// The plan that compresses `selection` in `directory`, named free
    /// against the folder's real contents.
    public static func compress(
        _ format: ArchiveFormat, selection: [RemoteFileItem], in directory: String,
        fileSystem: any RemoteFileSystem
    ) async throws -> ArchivePlan {
        try ArchivePlan.compress(
            format, selection: selection, workingDirectory: directory,
            namesInFolder: try await namesInFolder(directory, fileSystem: fileSystem))
    }

    /// What the extract dialog shows about `archive`, and what the run it
    /// starts needs: how many entries the archive holds, how many names it
    /// would land on in `directory`, and which skip-existing flag this far
    /// side's `tar` takes.
    ///
    /// The archive is listed through `runner` (bounded in bytes; a listing
    /// past the bound throws `ArchiveListingTooLarge` and no preview is
    /// offered -- a truncated list would under-report), except a `.gz`,
    /// whose one entry is its own name.
    ///
    /// The flavour probe runs only for the two formats whose tool IS `tar`,
    /// so a `.gz` still asks the runner nothing at all
    /// (`aGzPreviewNeverAsksTheRunnerForAListing` pins that) and a `.zip`
    /// pays for one `exec`, not two.
    public static func extractPreview(
        archive: RemoteFileItem, format: ArchiveExtractFormat, in directory: String,
        fileSystem: any RemoteFileSystem, runner: any ArchiveRunner
    ) async throws -> ExtractPreparation {
        let names = try await namesInFolder(directory, fileSystem: fileSystem)
        let entries: [String]? = format == .gz
            ? nil
            : try await runner.listing(
                try ArchivePlan.listing(
                    of: archive.name, format: format, workingDirectory: directory),
                limit: ArchiveBudget.listingBytes)
        let skip: TarSkipExisting
        switch format {
        case .tar, .tarGz: skip = try await tarSkipExisting(in: directory, runner: runner)
        case .zip, .gz: skip = .keepOldFiles
        }
        return ExtractPreparation(
            preview: ExtractPreview.make(
                archiveName: archive.name, format: format, archiveEntries: entries,
                namesInFolder: names),
            tarSkipExisting: skip)
    }

    /// Which skip-existing flag the `tar` in `directory`'s host takes, asked
    /// as a capability question PER FLAG:
    /// `ArchivePlan.tarSkipExistingProbe`'s exit status is the whole answer.
    ///
    /// **Both cases are measured; neither is a fallback.** The quiet flag is
    /// asked for first because GNU tar is the common remote and answers it,
    /// so that host pays for one `exec`; bsdtar answers the second. A tar
    /// that answers for neither is REFUSED
    /// (`ArchiveRefusal.tarHasNoSkipExistingFlag`) rather than handed a flag
    /// measured to fail on it — fix round 2's correction, after this
    /// function returned `.keepOldFiles` for anything it could not identify
    /// and BusyBox tar 1.37.0 turned out to reject that flag outright. The
    /// sentence it replaces read: "so it is caught and turned into
    /// `.keepOldFiles`, the flag both flavours accept".
    ///
    /// A NON-ZERO status is an answer here and not a failure — it means
    /// "this tar does not take that flag". `.toolMissing` and
    /// `.timedOut` are NOT answers and are rethrown: a far side with no
    /// `tar` should say so while the dialog is being built, not after the
    /// user has pressed Extract. So is everything that is not an
    /// `ArchiveFailure` at all, a dropped connection among it.
    ///
    /// The probe's standard output is discarded; `ArchiveBudget.probeBytes`
    /// only has to be wide enough for a version banner (313 bytes from GNU
    /// tar 1.35, 72 from bsdtar 3.5.3, both measured 2026-10-09).
    static func tarSkipExisting(
        in directory: String, runner: any ArchiveRunner
    ) async throws -> TarSkipExisting {
        for flavour in [TarSkipExisting.skipOldFiles, .keepOldFiles] {
            if try await tarTakes(flavour, in: directory, runner: runner) { return flavour }
        }
        throw ArchiveRefusal.tarHasNoSkipExistingFlag
    }

    /// Whether the far side's `tar` accepts `flavour`'s flag.
    private static func tarTakes(
        _ flavour: TarSkipExisting, in directory: String, runner: any ArchiveRunner
    ) async throws -> Bool {
        do {
            _ = try await runner.listing(
                ArchivePlan.tarSkipExistingProbe(for: flavour, workingDirectory: directory),
                limit: ArchiveBudget.probeBytes)
            return true
        } catch let failure as ArchiveFailure {
            guard case .exited = failure else { throw failure }
            return false
        }
    }

    /// Creates the directory `destination` names, through the file system.
    ///
    /// **Why this exists.** `unzip -d ./nope` creates the directory and
    /// `tar … -C ./nope` does NOT: it prints `tar: could not chdir to
    /// './nope'` and extracts nothing (measured 2026-10-09). The directory
    /// is made here, through `createDirectory(at:)`, and never by adding a
    /// shell `mkdir` to the command line: keeping names off that line is the
    /// whole design. Done for BOTH formats rather than only for tar, because
    /// a directory that already exists costs `unzip` nothing, and one code
    /// path is easier to hold than a per-tool exception.
    ///
    /// Idempotent by the file system's own contract. `.thisFolder` creates
    /// nothing.
    public static func makeDestination(
        _ destination: ExtractDestination, in directory: String,
        fileSystem: any RemoteFileSystem
    ) async throws {
        guard case .subfolder(let name) = destination else { return }
        try await fileSystem.createDirectory(at: RemotePath.join(directory, name))
    }
}
