import SwiftUI
import macSCPCore

/// The non-modal row a pane shows while it has an archive operation running,
/// and the one sentence it leaves behind when that operation failed.
///
/// Not a sheet and not a queue item: the user keeps browsing, and the only
/// control is the one that matters, Cancel. Cancelling cancels the task, and
/// the task is what closes the exec channel or ends the child process.
///
/// A refusal is not shown here: the pane turns it into an alert
/// (`BrowserPane`), because it asks the user to change something.
///
/// Reads `ArchiveActivity` and nothing else, so what it shows is decided
/// there and in `ArchivePresentation`. A success or a cancel leaves no row:
/// the pane reloads its listing when the activity goes idle, and that is
/// the report.
struct ArchiveActivityRow: View {
    let activity: ArchiveActivity

    var body: some View {
        if case .running(let title) = activity.state {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(ArchivePresentation.runningText(
                    operation: activity.operation, title: title))
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button(L10n.string("common.cancel", "Cancel")) { activity.cancel() }
                    .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            Rectangle().fill(DesignTokens.hairline).frame(height: 1)
        } else if let ending = activity.lastOutcome, !ending.isRefusal,
            let message = ArchivePresentation.message(for: ending)
        {
            HStack(spacing: 8) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                Spacer()
                Button {
                    activity.dismissOutcome()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(L10n.string("archive.activity.dismiss", "Dismiss message"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            Rectangle().fill(DesignTokens.hairline).frame(height: 1)
        }
    }
}

private extension ArchiveActivity.Ending {
    var isRefusal: Bool {
        if case .refused = self { true } else { false }
    }
}
