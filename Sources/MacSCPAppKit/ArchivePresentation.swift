import Foundation
import macSCPCore

/// What the pane says about an archive operation.
///
/// Every sentence is the App's own, looked up through the catalogue, and
/// **none is built from a tool's output**: `ArchiveFailure` carries none, and
/// the one function that takes an arbitrary `Error` maps anything it does not
/// recognise to the generic sentence instead of quoting it, because the
/// description of a file system or channel error is a far side's text. What
/// the sentences may contain is what is ours: a tool's name from this
/// feature's own fixed list, an exit status (a number), and the names the user
/// selected themselves.
enum ArchivePresentation {
    /// One sentence for how an operation ended, or `nil` for the endings
    /// that need none: a success shows the reloaded listing, and a cancel is
    /// something the user just did.
    static func message(for ending: ArchiveActivity.Ending) -> String? {
        switch ending {
        case .finished, .cancelled: nil
        case .failed(let failure): message(for: failure)
        case .refused(let refusal): message(for: refusal)
        case .couldNotRun: couldNotRun
        }
    }

    static func message(for failure: ArchiveFailure) -> String {
        switch failure {
        case .toolMissing(let tool):
            String(format: L10n.string(
                "archive.error.toolMissing", "The “%@” tool is not available here."), tool)
        case .exited(let status):
            String(format: L10n.string(
                "archive.error.exited",
                "The archive tool stopped with an error (status %lld)."), Int64(status))
        case .timedOut:
            L10n.string(
                "archive.error.timedOut", "The operation took too long and was stopped.")
        }
    }

    /// Why a plan was not made. Every case names what the user would have to
    /// change, because each one is shown to them.
    static func message(for refusal: ArchiveRefusal) -> String {
        switch refusal {
        case .emptySelection:
            L10n.string("archive.refusal.emptySelection", "Select at least one item first.")
        case .gzTakesExactlyOneFile:
            L10n.string(
                "archive.refusal.gzTakesExactlyOneFile",
                "A compressed file holds exactly one file. Select a single file.")
        case .gzTakesAFileNotAFolder(let name):
            String(format: L10n.string(
                "archive.refusal.gzTakesAFileNotAFolder",
                "“%@” is a folder. A compressed file holds a single file; use a ZIP archive or a compressed tarball for folders."),
                name)
        case .newlineInNameUnsupportedByZip(let name):
            String(format: L10n.string(
                "archive.refusal.newlineInName",
                "“%@” has a line break in its name, which a ZIP archive cannot carry. Use a compressed tarball instead."),
                name)
        case .gzExtractsIntoThisFolderOnly:
            // The sentence the sheet already shows beside the choice it
            // removes; one catalogue entry for one fact.
            L10n.string(
                "archive.extract.gzHereOnly",
                "A compressed file is always extracted into this folder.")
        case .gzTargetExists(let name):
            String(format: L10n.string(
                "archive.refusal.gzTargetExists",
                "“%@” already exists here. Rename or remove it, then compress again."), name)
        case .wildcardInNameUnsupportedByUnzip(let name):
            String(format: L10n.string(
                "archive.refusal.wildcardInName",
                "“%@” has a wildcard character in its name (*, ? or [). A ZIP archive with such a name cannot be told apart from the other names here, so it was not extracted. Rename it, then extract again."),
                name)
        case .gzExtractTargetExists(let name):
            String(format: L10n.string(
                "archive.refusal.gzExtractTargetExists",
                "“%@” already exists here, and a compressed file can only be unpacked beside itself. Rename or remove it, then extract again."),
                name)
        }
    }

    /// The funnel for anything thrown on the way to starting an operation.
    /// Unrecognised errors are NOT quoted -- see the type's comment.
    static func message(for error: any Error) -> String {
        switch error {
        case let refusal as ArchiveRefusal: message(for: refusal)
        case let failure as ArchiveFailure: message(for: failure)
        case is ArchiveListingTooLarge:
            L10n.string(
                "archive.error.tooLargeToPreview",
                "This archive holds too many entries to check against this folder first, so it was not extracted.")
        default: couldNotRun
        }
    }

    static var busy: String {
        L10n.string(
            "archive.error.busy",
            "Another archive operation is still running in this pane. Wait for it to finish, or cancel it.")
    }

    static var alertTitle: String { L10n.string("archive.alert.title", "Archive") }

    private static var couldNotRun: String {
        L10n.string("archive.error.couldNotRun", "The operation could not be carried out.")
    }

    /// The row's line while an operation runs: the verb, then the archive.
    static func runningText(operation: ArchiveOperation?, title: String) -> String {
        switch operation {
        case .extract:
            String(format: L10n.string("archive.activity.extracting", "Extracting %@…"), title)
        case .compress, nil:
            String(format: L10n.string("archive.activity.compressing", "Compressing %@…"), title)
        }
    }
}
