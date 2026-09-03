import SwiftUI
import macSCPCore

/// The one diagnostics surface, behind three doors (design §1/§4).
///
/// A sheet on the window: the connection it is pointed at, then the steps as
/// rows — title, outcome badge, duration, one line of detail — and three
/// controls: run (or cancel, while one is in flight), copy, close.
///
/// **It runs nothing on its own.** There is no `.onAppear` and no `.task` here
/// that starts a diagnosis, and that is a decision rather than an oversight
/// (maintainer, 2026-09-02): a diagnosis dials the user's server, and the SSH
/// dial authenticates while doing it. Opening a panel is not consent to that;
/// pressing the button is. `DiagnosticsDoorsGuardTests` holds this file and
/// all three doors to it, with the planted violation being exactly an
/// `.onAppear { … run() }`.
///
/// The copy control is a `Menu` with two entries, plain text and Markdown —
/// the second half of the same decision. Both copy the report's own
/// renderings, unchanged and in English: the report is what gets pasted into a
/// bug report, and a row that arrives translated is a row its reader cannot
/// search for (`DiagnosticReport`'s own doc comment).
struct DiagnosticsPanel: View {
    @State private var model: DiagnosticsViewModel
    private let onClose: () -> Void

    /// The view model is created HERE, from the value a door handed over, and
    /// lives as long as the sheet does — window scope, never a singleton
    /// (CLAUDE.md, "Architecture invariants"). Two windows diagnosing two
    /// connections hold two of these, and neither can see the other's report.
    init(target: DiagnosticsTarget, secrets: (any SecretSource)?, onClose: @escaping () -> Void) {
        _model = State(initialValue: DiagnosticsViewModel(target: target, secrets: secrets))
        self.onClose = onClose
    }

    /// The injecting initializer, for a caller that already holds a model.
    init(model: DiagnosticsViewModel, onClose: @escaping () -> Void) {
        _model = State(initialValue: model)
        self.onClose = onClose
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            content
            Divider()
            controls
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 420)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            L10n.text("diagnostics.title", "Connection diagnostics")
                .font(.title2.bold())
            Text(model.name)
                .font(.callout)
                .foregroundStyle(.secondary)
            if let report = model.report {
                Text(report.endpoint.text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(DesignTokens.inkTertiary)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let report = model.report {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(report.steps) { step in
                        row(step)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if model.isRunning {
            // The very first run has no rows yet. A partial report is not
            // published mid-run — `ConnectionDiagnostics` returns one value at
            // the end — so what there is to say here is that it is working.
            VStack(alignment: .leading, spacing: 8) {
                ProgressView()
                L10n.text("diagnostics.running", "Measuring…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                L10n.text(
                    "diagnostics.idle",
                    """
                    Nothing has been measured yet. The check resolves the host, tries a \
                    connection, sends a ping, dials the way this connection would, and \
                    traces the route.
                    """)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func row(_ step: DiagnosticStep) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(DiagnosticsPresentation.title(of: step))
                    .font(.callout.weight(.medium))
                Text(DiagnosticsPresentation.badge(for: step.outcome))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(badgeColour(step.outcome))
                Spacer(minLength: 8)
                Text(DiagnosticsPresentation.duration(of: step))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(DesignTokens.inkTertiary)
            }
            let reason = DiagnosticsPresentation.reason(of: step.outcome)
            if !reason.isEmpty {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !step.detail.isEmpty {
                Text(step.detail)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(DesignTokens.inkTertiary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// `unavailable` and `skipped` are deliberately NOT the failure colour:
    /// they are statements about this build and this session, and colouring
    /// them red would tell the user their server is broken when nothing was
    /// measured at all.
    private func badgeColour(_ outcome: DiagnosticOutcome) -> Color {
        switch outcome {
        case .ok: return DesignTokens.statusPhosphor
        case .failed, .timedOut: return DesignTokens.statusLost
        case .unavailable, .skipped: return DesignTokens.inkTertiary
        }
    }

    /// A bare `HStack {`, like every other sheet footer in this target —
    /// `SheetOverflowMenuWiringGuardTests` locates a footer by exactly that
    /// line above the Close button, and a sheet whose footer it cannot parse
    /// drops out of that suite's population by throwing rather than by going
    /// quiet.
    private var controls: some View {
        HStack {
            if model.isRunning {
                Button(L10n.string("common.cancel", "Cancel")) { model.cancel() }
            } else {
                Button(
                    model.report == nil
                        ? L10n.string("diagnostics.run", "Run check")
                        : L10n.string("diagnostics.runAgain", "Run again")
                ) {
                    model.run()
                }
                .buttonStyle(.polished)
            }
            Menu(L10n.string("diagnostics.copy", "Copy report")) {
                Button(L10n.string("diagnostics.copy.plainText", "As plain text")) {
                    model.copyPlainText()
                }
                Button(L10n.string("diagnostics.copy.markdown", "As Markdown")) {
                    model.copyMarkdown()
                }
            }
            .disabled(model.report == nil)
            .fixedSize()
            Spacer(minLength: 0)
            Button(L10n.string("common.close", "Close"), action: onClose)
                .keyboardShortcut(.cancelAction)
        }
    }
}
