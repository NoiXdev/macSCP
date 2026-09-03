import SwiftUI
import macSCPCore

/// The one diagnostics surface, behind three doors (design §1/§4) — the
/// tab's (two surfaces: the toolbar while connected, and the failed-connect
/// surface), the session menu's, and the error dialog's.
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
    /// Held, not created: the window owns the model
    /// (`ContentView.diagnostics`), because stopping a run has to be possible
    /// from paths this view is not on — the tab's teardown, and a panel
    /// replaced rather than dismissed. Still window scope, never a singleton
    /// (CLAUDE.md, "Architecture invariants"): two windows diagnosing two
    /// connections hold two, and neither can see the other's report.
    let model: DiagnosticsViewModel
    private let onClose: () -> Void

    init(model: DiagnosticsViewModel, onClose: @escaping () -> Void) {
        self.model = model
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
        // The panel's half of the lifecycle: a diagnosis does not outlive the
        // sheet that asked for it. `run()` starts a free `Task`, which tearing
        // this view down does not touch — so without this line, closing the
        // sheet leaves the walk going and the SSH dial authenticating against
        // the user's server after the user has visibly withdrawn.
        //
        // The window cancels too (`ContentView.endDiagnostics()`), and the two
        // are not redundant: this one catches the dismissals SwiftUI performs
        // without routing through the sheet's binding, and `cancel()` on an
        // already-cancelled run does nothing.
        .onDisappear { model.cancel() }
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
        // Rows first, whether or not the run has finished: each one is drawn
        // the moment `ConnectionDiagnostics` hands it over
        // (`DiagnosticStepObserver`). Before this the report arrived as one
        // value at the end, and a host whose last hops are firewalled left the
        // panel showing nothing but a spinner for the trace's whole 20 s
        // budget — with four finished rows already measured.
        if !model.steps.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.steps) { step in
                        row(step)
                    }
                    // The step in flight has no row yet — a row exists once it
                    // has an outcome and a duration — so the indicator sits
                    // where its row is about to appear.
                    if model.isRunning { measuring }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if model.isRunning {
            // Nothing has finished yet: the first step is still going.
            measuring
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

    private var measuring: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            L10n.text("diagnostics.running", "Measuring…")
                .font(.callout)
                .foregroundStyle(.secondary)
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
            // Rendered through `DiagnosticsPresentation.detail(of:)`: the
            // measured half is copied through byte for byte — it is what gets
            // pasted into a bug report — and only the trace's "stopped by the
            // budget" marker, which is a statement about the CHECK rather than
            // about the network, is looked up in the reader's language.
            //
            // The renderer is named at the DRAWING site, not bound to a local
            // first: `thePanelRendersTheDetailThroughItsRenderer` reads every
            // `Text` that mentions a detail and requires the renderer in the
            // same invocation, which is what catches a `Text(step.detail)`
            // put back here. The emptiness test above it is free to read the
            // raw line — it is a length, not a rendering.
            if !step.detail.isEmpty {
                Text(DiagnosticsPresentation.detail(of: step))
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
            // Enabled the moment a run ENDS — including a cancel, which
            // publishes the rows it measured. Not during the walk: a report
            // carries an endpoint and a build line that only the finished run
            // supplies, and inventing them for a value whose whole job is to
            // be pasted into a bug report would be the wrong trade.
            .disabled(model.report == nil)
            .fixedSize()
            Spacer(minLength: 0)
            Button(L10n.string("common.close", "Close"), action: onClose)
                .keyboardShortcut(.cancelAction)
        }
    }
}
