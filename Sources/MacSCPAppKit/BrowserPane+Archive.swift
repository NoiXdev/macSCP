import SwiftUI
import macSCPCore

/// The extract dialog's request: everything the sheet shows and everything
/// the run needs, captured when the preview was made.
///
/// The `directory` is the one the preview was counted over, so the run goes
/// where the dialog said even if the pane has navigated since. The
/// `preparation` is `ArchivePreparation`'s own answer, carried whole rather
/// than unpacked: it holds what the sheet shows AND which skip-existing flag
/// this far side's `tar` takes, and the two were measured in one round trip.
struct ExtractRequest: Identifiable {
    let id = UUID()
    let archive: RemoteFileItem
    let format: ArchiveExtractFormat
    let directory: String
    let preparation: ExtractPreparation

    var preview: ExtractPreview { preparation.preview }
}

/// The pane's two archive entries, from the menu to `ArchiveActivity`.
///
/// Handled here and not forwarded to `ContentView`, like every other entry
/// whose sheet or alert is the pane's own (rename, delete, checksum): the
/// activity lives on the pane's view model, the runner is chosen from the
/// pane's `side` and the very file system it browses, and the row that shows
/// the run is the pane's. Everything with a decision in it is in Core
/// (`ArchivePreparation`, `ArchivePlan`), where it is proved against a real
/// directory.
extension BrowserPane {
    /// The runner for THIS pane's file system, or `nil` when the backend
    /// cannot run archive commands. The local pane archives with the system's
    /// own tools. The remote one asks the capability question inside Core
    /// (`RemoteArchiveRunner.init?(backend:)`), about the file system the
    /// pane browses and nothing else: the parameter is `any Sendable`, so a
    /// wrong argument would compile and answer `nil` forever
    /// (`ArchiveGateWiringGuardTests` holds the gate, and
    /// `ArchivePaneWiringGuardTests` this call).
    ///
    /// `nil` is unreachable from the menu, which is gated on the same
    /// question; it ends the action silently rather than crash.
    var archiveRunner: (any ArchiveRunner)? {
        switch side {
        case .local: LocalArchiveRunner()
        case .remote: RemoteArchiveRunner(backend: fileSystem)
        }
    }

    @MainActor
    func startCompress(_ format: ArchiveFormat, selection: [RemoteFileItem]) {
        guard let runner = archiveRunner else { return }
        let activity = viewModel.archiveActivity
        guard !activity.isRunning else {
            archiveAlertMessage = ArchivePresentation.busy
            return
        }
        let directory = viewModel.currentPath
        let fileSystem = fileSystem
        // The plan is made INSIDE the activity, so the one cancel a tab's
        // teardown calls reaches the folder read as well as the run; a task
        // started here would be owned by nothing. A refusal or a failure
        // ends the activity, and `.onChange` below turns it into the alert.
        let started = activity.start(
            operation: .compress(format),
            title: (try? ArchiveNaming.proposedName(format: format, selection: selection))
                ?? selection.first?.name ?? "",
            runner: runner,
            makePlan: {
                // Named against the folder as the file system lists it, not
                // against the table, which may be hiding dotfiles.
                try await ArchivePreparation.compress(
                    format, selection: selection, in: directory, fileSystem: fileSystem)
            })
        if !started { archiveAlertMessage = ArchivePresentation.busy }
    }

    /// Reads the folder and the archive, then opens the dialog. Nothing is
    /// extracted until the dialog's answer.
    @MainActor
    func beginExtract(_ format: ArchiveExtractFormat, selection: [RemoteFileItem]) {
        guard let runner = archiveRunner, selection.count == 1, let archive = selection.first
        else { return }
        guard !viewModel.archiveActivity.isRunning else {
            archiveAlertMessage = ArchivePresentation.busy
            return
        }
        let directory = viewModel.currentPath
        let fileSystem = fileSystem
        // Owned by the activity, like the compress plan: a tab closed while
        // the archive is being listed cancels the listing, and a cancelled
        // preview opens no dialog.
        viewModel.archiveActivity.preview({
            // A listing past the byte bound throws and no dialog opens:
            // a truncated list would under-report collisions.
            try await ArchivePreparation.extractPreview(
                archive: archive, format: format, in: directory,
                fileSystem: fileSystem, runner: runner)
        }) { result in
            switch result {
            case .success(let preparation):
                extractRequest = ExtractRequest(
                    archive: archive, format: format, directory: directory,
                    preparation: preparation)
            case .failure(let error):
                archiveAlertMessage = ArchivePresentation.message(for: error)
            }
        }
    }

    /// The dialog's answer. The subfolder, when there is one, is created
    /// INSIDE the activity, before the runner is asked (see
    /// `ArchivePreparation.makeDestination` for why `tar` needs it).
    @MainActor
    func startExtract(_ request: ExtractRequest, into destination: ExtractDestination) {
        guard let runner = archiveRunner else { return }
        let plan: ArchivePlan
        do {
            plan = try ArchivePlan.extract(
                request.archive, format: request.format,
                workingDirectory: request.directory, into: destination,
                // The flavour the preview measured, never a default: a
                // `tar` given the flag it does not take, or the one that
                // exits 2 over a collision, is exactly the defect this
                // parameter exists for.
                tarSkipExisting: request.preparation.tarSkipExisting,
                // And the folder the preview was counted over, which is what
                // lets the plan refuse a `.gz` whose one output file is
                // already there instead of surfacing `gunzip`'s status 1.
                preview: request.preparation.preview)
        } catch {
            archiveAlertMessage = ArchivePresentation.message(for: error)
            return
        }
        let directory = request.directory
        let fileSystem = fileSystem
        let started = viewModel.archiveActivity.start(
            plan, runner: runner,
            prepare: {
                try await ArchivePreparation.makeDestination(
                    destination, in: directory, fileSystem: fileSystem)
            })
        if !started { archiveAlertMessage = ArchivePresentation.busy }
    }
}
