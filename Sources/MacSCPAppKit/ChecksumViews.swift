import SwiftUI
import macSCPCore

/// One checksum, as it is shown wherever one is shown.
///
/// Everything it renders comes out of `ChecksumDisplay`; it computes no
/// text of its own and never touches a `FileChecksum`. That is the point:
/// the digest and the sentence saying where the digest came from arrive in
/// the same value, so there is no expression in this file that produces the
/// one without the other. `ChecksumSurfaceGuardTests` holds this file to
/// reading every part of that value — the multipart-ETag case is a
/// well-formed MD5 that is not the file's hash, and dropping its
/// qualification would turn the display into a lie on exactly the large
/// files somebody bothered to check.
struct ChecksumResultView: View {
    let result: ChecksumRequestResult

    var body: some View {
        let display = ChecksumDisplay.of(result)
        VStack(alignment: .leading, spacing: 2) {
            Text(display.value)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(color(for: display.severity))
                .textSelection(.enabled)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            if !display.qualification.isEmpty {
                Text(display.qualification)
                    .font(.caption)
                    .foregroundStyle(
                        display.severity == .caution
                            ? DesignTokens.statusAmber : DesignTokens.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Only a failure is red. A `.caution` value is a REAL number that
    /// answers a different question than the one asked, so it is set like
    /// any other digest and the amber sits on the sentence beside it —
    /// `statusAmber`'s own documented distinction, attention without
    /// failure. Red on the digest would read as something the user could
    /// fix, and there is nothing here to fix.
    private func color(for severity: ChecksumDisplay.Severity) -> Color {
        switch severity {
        case .plain, .caution: DesignTokens.ink
        case .failure: DesignTokens.statusLost
        }
    }
}

/// The selection's run: one row per file, each filling in as its result
/// arrives, and a Cancel that leaves everything already computed standing.
///
/// Not a progress bar over one long wait — a list that grows. That is what
/// the design asks for and what the run underneath actually does; a modal
/// spinner over a checksum of 40 GB would be the window with no way out
/// this project has been removing elsewhere.
struct ChecksumBatchSheet: View {
    let batch: ChecksumBatch
    let compute: @MainActor (RemoteFileItem) async -> ChecksumRequestResult

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(L10n.string("checksum.batch.title", "Checksums")).font(.headline)
                Spacer()
                // A name and two plain numbers — nothing here is prose, so
                // nothing here needs a catalogue entry or a plural rule.
                Text(verbatim: "\(batch.algorithm.displayName)  ·  "
                    + "\(batch.finishedCount) / \(batch.rows.count)")
                    .font(.caption)
                    .foregroundStyle(DesignTokens.inkSecondary)
                    .monospacedDigit()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(batch.rows) { row in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.item.name)
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if let result = row.result {
                                ChecksumResultView(result: result)
                            } else {
                                Text(row.item.path)
                                    .font(.caption)
                                    .foregroundStyle(DesignTokens.inkTertiary)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.trailing, 4)
            }
            .frame(minHeight: 140, maxHeight: 320)

            if batch.wasCancelled {
                Text(L10n.string(
                    "checksum.batch.cancelled",
                    "Cancelled. The checksums already computed are kept."))
                    .font(.caption)
                    .foregroundStyle(DesignTokens.inkSecondary)
            }

            HStack {
                if batch.isRunning { ProgressView().controlSize(.small) }
                Spacer()
                if batch.isRunning {
                    Button(L10n.string("common.cancel", "Cancel")) { batch.cancel() }
                        .buttonStyle(.polished)
                } else {
                    Button(L10n.string("common.close", "Close"), role: .cancel) { dismiss() }
                        .buttonStyle(.polished)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 440)
        // Started here rather than at the call site, so nothing runs until
        // the sheet is actually on screen. The run is an UNSTRUCTURED task
        // inside `ChecksumBatch`, so `.task`'s own cancellation does not
        // reach it — closing the sheet therefore cancels explicitly below,
        // through the same cooperative stop the Cancel button uses.
        .task { await batch.start(compute).value }
        .onDisappear { batch.cancel() }
    }
}
