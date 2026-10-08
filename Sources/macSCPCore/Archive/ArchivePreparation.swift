import Foundation

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

    /// What the extract dialog shows about `archive`: how many entries it
    /// holds and how many names it would land on in `directory`.
    ///
    /// The archive is listed through `runner` (bounded in bytes; a listing
    /// past the bound throws `ArchiveListingTooLarge` and no preview is
    /// offered -- a truncated list would under-report), except a `.gz`,
    /// whose one entry is its own name.
    public static func extractPreview(
        archive: RemoteFileItem, format: ArchiveExtractFormat, in directory: String,
        fileSystem: any RemoteFileSystem, runner: any ArchiveRunner
    ) async throws -> ExtractPreview {
        let names = try await namesInFolder(directory, fileSystem: fileSystem)
        let entries: [String]? = format == .gz
            ? nil
            : try await runner.listing(
                ArchivePlan.listing(
                    of: archive.name, format: format, workingDirectory: directory),
                limit: ArchiveBudget.listingBytes)
        return ExtractPreview.make(
            archiveName: archive.name, format: format, archiveEntries: entries,
            namesInFolder: names)
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
