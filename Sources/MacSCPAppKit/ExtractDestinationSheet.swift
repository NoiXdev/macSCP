import SwiftUI
import macSCPCore

/// The extract dialog: where an archive unpacks, and what that will touch.
///
/// A small modal choice in the shape `ImportConflictSheet` and
/// `PresignedURLSheet` already use — the same padding and spacing, buttons
/// in a trailing row with Cancel first and the default action last, and
/// `.interactiveDismissDisabled(true)`, so that only a button resolves it
/// and whatever presents this sheet can rely on `onCancel` or `onExtract`
/// being called exactly once.
///
/// The sheet decides nothing about the archive. Everything it shows comes
/// from `ExtractPreview` (Core), which was built from a LISTING: the
/// collision count cannot be read from the run itself, because both
/// skip-existing flags are silent about what they skipped.
///
/// Presented by nobody yet: the menu entry's handler is Task 8's wiring.
struct ExtractDestinationSheet: View {
    let archiveName: String
    let preview: ExtractPreview
    let onExtract: (ExtractDestination) -> Void
    let onCancel: () -> Void

    private enum Choice: Hashable {
        case thisFolder, subfolder
    }

    @State private var choice: Choice = .thisFolder
    @State private var subfolderName: String

    init(
        archiveName: String, preview: ExtractPreview,
        onExtract: @escaping (ExtractDestination) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.archiveName = archiveName
        self.preview = preview
        self.onExtract = onExtract
        self.onCancel = onCancel
        _subfolderName = State(initialValue: preview.proposedSubfolder)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.string("archive.extract.title", "Extract Archive")).font(.headline)
            Text(archiveName)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)

            if preview.allowsSubfolder {
                Picker("", selection: $choice) {
                    Text(L10n.string("archive.extract.here", "Into this folder"))
                        .tag(Choice.thisFolder)
                    Text(L10n.string("archive.extract.subfolder", "Into a new folder:"))
                        .tag(Choice.subfolder)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()

                TextField(
                    L10n.string("archive.extract.subfolderName", "Folder name"),
                    text: $subfolderName)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .disabled(choice != .subfolder)
            } else {
                // A compressed file is unpacked beside itself and cannot be
                // sent anywhere else, so there is no choice to offer.
                Text(L10n.string("archive.extract.here", "Into this folder"))
                Text(L10n.string(
                    "archive.extract.gzHereOnly",
                    "A compressed file is always extracted into this folder."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(String(
                format: L10n.string(
                    "archive.extract.entries %lld", "%lld entries in this archive."),
                preview.entryCount))
                .font(.caption)
                .foregroundStyle(.secondary)

            // Only for "this folder": a new subfolder starts empty, so
            // nothing there can collide.
            if preview.collidingHere > 0, choice == .thisFolder {
                Text(String(
                    format: L10n.string(
                        "archive.extract.collisions %lld",
                        "%lld names from this archive already exist here. Existing files are not overwritten."),
                    preview.collidingHere))
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button(L10n.string("common.cancel", "Cancel"), role: .cancel) { onCancel() }
                    .buttonStyle(.polished)
                    .keyboardShortcut(.cancelAction)
                Button(L10n.string("archive.extract.confirm", "Extract")) { onExtract(destination) }
                    .buttonStyle(.polishedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canExtract)
            }
        }
        .padding(20)
        .frame(width: 420)
        .interactiveDismissDisabled(true)
    }

    /// What the buttons hand back. A `.gz` never reaches the subfolder case:
    /// the picker that could select it is not shown, and `ArchivePlan.extract`
    /// refuses the combination below this anyway.
    private var destination: ExtractDestination {
        guard preview.allowsSubfolder, choice == .subfolder else { return .thisFolder }
        return .subfolder(subfolderName.trimmingCharacters(in: .whitespaces))
    }

    private var canExtract: Bool {
        guard preview.allowsSubfolder, choice == .subfolder else { return true }
        return ExtractPreview.isUsableSubfolderName(subfolderName)
    }
}
