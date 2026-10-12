import SwiftUI
import macSCPCore

/// The non-modal row a pane shows while a local file action runs, and the
/// one sentence it leaves behind when the action did not finish.
///
/// Not a sheet: the user keeps browsing, and the only control is Cancel.
/// Cancelling cancels the activity's task, which ends the child process. A
/// success or a cancel leaves no row; the pane reloads its listing when the
/// activity goes idle, and that is the report.
struct FileActionActivityRow: View {
    let activity: FileActionActivity

    var body: some View {
        if case .running(let title) = activity.state {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(FileActionPresentation.runningText(title: title))
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
        } else if let outcome = activity.lastOutcome,
            let message = FileActionPresentation.message(for: outcome)
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
                .help(L10n.string("fileAction.activity.dismiss", "Dismiss message"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            Rectangle().fill(DesignTokens.hairline).frame(height: 1)
        }
    }
}

/// The sentences of the row. The action's name is the user's own text, so it
/// is the only thing from outside that appears in them; a program's output
/// and an error's description never do.
enum FileActionPresentation {
    static func runningText(title: String) -> String {
        String(format: L10n.string("fileAction.activity.running", "Running “%@”"), title)
    }

    /// `nil` for an ending that needs no sentence: a success and a cancel are
    /// reported by the reloaded listing.
    static func message(for outcome: FileActionActivity.Outcome) -> String? {
        switch outcome.ending {
        case .finished, .cancelled, .notRunnableHere:
            return nil
        case .failed:
            return String(
                format: L10n.string("fileAction.activity.failed", "“%@” ended with an error."),
                outcome.title)
        case .timedOut:
            return String(
                format: L10n.string(
                    "fileAction.activity.timedOut", "“%@” took too long and was stopped."),
                outcome.title)
        case .couldNotRun:
            return String(
                format: L10n.string(
                    "fileAction.activity.couldNotRun", "“%@” could not be started."),
                outcome.title)
        }
    }
}
