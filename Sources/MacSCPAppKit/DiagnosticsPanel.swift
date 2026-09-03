import SwiftUI
import macSCPCore

/// The one diagnostics surface, behind three doors (design §1/§4) — the
/// tab's (two surfaces: the toolbar while connected, and the failed-connect
/// surface), the session menu's, and the error dialog's.
///
/// A sheet on the window: the connection it is pointed at, then the steps as
/// rows — title, outcome badge, duration, one line of detail, and a grid where
/// the step measured one (the trace's hops) — and four controls: run (or
/// cancel, while one is in flight), the menu that says what a run measures,
/// copy, close.
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

    /// The floor the footer's four controls need at the default font, in the
    /// widest of the four catalogs' footer strings.
    ///
    /// Measured 2026-09-03 with `NSAttributedString.size(withAttributes:)` —
    /// the real AppKit metric, not a per-character guess — over each
    /// catalog's `diagnostics.run`, the widest `diagnostics.scope.*` choice
    /// ("Protocol probes"/"Protokollproben"/"Sondes de protocole"/"Sondy
    /// protokołu"), `diagnostics.copy` and `common.close`, at
    /// `NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .regular))`
    /// except Run's own text, measured at 12.5pt
    /// (`PolishedButtonStyle`'s font). The plan that opened this task
    /// expected German to be the widest catalog; measuring the actual
    /// strings found French wider (the four sums, narrowest to widest: en
    /// 264pt, pl 356pt, de 346pt, fr 393pt of text alone). Adding an
    /// estimated 30pt of chrome for the Run button's own padding
    /// (`PolishedButtonStyle`: 14pt each side), ~22pt of system
    /// bordered-button chrome for Close, ~36pt each for the Picker and the
    /// Copy menu (the same chrome plus a ~14pt disclosure chevron), the
    /// `HStack`'s three 8pt gaps and the panel's own 20pt padding on both
    /// sides puts French at roughly 581pt — the widest of the four. Rounded
    /// up to 600 for the chrome estimate's own uncertainty.
    static let minimumWidth: CGFloat = 600

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
        .frame(minWidth: Self.minimumWidth, minHeight: 420)
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
            // From the model, not from the report: the endpoint is known
            // before the first probe runs, and it is the one fact a reader
            // wants beside the rows they can now watch arrive. Gating it on
            // `report` hid it for the whole walk.
            if let endpoint = model.endpoint {
                Text(endpoint.text)
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
            // The trace's hops, as the cells Core measured. Every other step
            // carries no table and keeps the line above alone; the trace keeps
            // it too, for the marker that says the walk stopped looking —
            // which is a sentence about the check, not a hop.
            if let measured = step.table {
                grid(measured)
            }
        }
    }

    /// A step's table under its row.
    ///
    /// `Grid` and not `Table`: `Table` is a scrollable, selectable,
    /// column-resizing list that owns its own height, and this is three or
    /// four rows sitting inside a row of another list.
    ///
    /// The identities are POSITIONS, not the values: a cell is a `String`, two
    /// silent hops are the same three strings, and `id: \.self` would collapse
    /// them into one row — the panel would then show one hop where the walk
    /// measured two, which is the reading error this whole grid exists to
    /// remove.
    ///
    /// A row is expected to carry a cell per column, and `DiagnosticTable`
    /// asks for that in prose without enforcing it. The `zip` below therefore
    /// TRUNCATES a row that disagrees, in either direction: a short row loses
    /// no cell it has, a long one loses the cells past the last column, and
    /// nothing crashes in front of a user. The assertion says so out loud in a
    /// debug build, where the producer is the thing to fix; the released panel
    /// draws what it was given, and the pasted report — which pads to the
    /// widest cell rather than zipping — may then print a column this grid
    /// does not show.
    private func grid(_ measured: DiagnosticTable) -> some View {
        assert(
            measured.rows.allSatisfy { $0.count == measured.columns.count },
            """
            a table's rows must carry one cell per column; this one has \
            \(measured.columns.count) columns and rows of \
            \(Set(measured.rows.map(\.count)).sorted())
            """)
        return Grid(
            alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 2
        ) {
            GridRow {
                ForEach(Array(measured.columns.enumerated()), id: \.offset) { _, key in
                    Text(DiagnosticsPresentation.columnTitle(key))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(Array(measured.rows.enumerated()), id: \.offset) { _, cells in
                GridRow {
                    // Each cell with the key of the column it sits in, so the
                    // renderer decides what to translate by NAME rather than
                    // by position.
                    ForEach(Array(zip(measured.columns, cells).enumerated()), id: \.offset) {
                        _, cell in
                        Text(DiagnosticsPresentation.cell(cell.1, column: cell.0))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(DesignTokens.inkTertiary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .padding(.top, 2)
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

    /// Above `Self.minimumWidth`, one row (`wideControls`); below it,
    /// `ViewThatFits` falls through to two (`narrowControls`) rather than
    /// truncating a button or wrapping its title letter by letter — which is
    /// what the maintainer's screenshot of this footer showed happening to
    /// Run, at the width the panel used to allow (design ruling, 2026-09-03).
    ///
    /// Both rows draw the SAME four control views — `primaryAction`,
    /// `scopeSelector`, `copyControl`, and the Close button are each written
    /// once below and referenced from both layouts, so a modifier that must
    /// appear exactly once in this file (`.keyboardShortcut(.defaultAction)`,
    /// the one `Picker`, the one `Menu`) still does, no matter which row
    /// `ViewThatFits` chooses to draw.
    ///
    /// **None of the three shared properties below spells `Button`,
    /// `Picker` or `Menu` as a plain suffix of its own name.** The doors
    /// guard's source scan finds an invocation by the RAW SUBSTRING of the
    /// keyword it is hunting — `bodies(after: "Menu", …)` and
    /// `invocationRanges(of: "Picker", …)` do not require a word boundary —
    /// so a property declared `private var somethingPicker: some View {`
    /// reads to that scanner exactly like a `Picker(` call: the "Picker"
    /// substring lands right before `: some View {`, and the scan opens on
    /// that brace and swallows the WHOLE property as if it were the
    /// invocation's own trailing closure. Measured while writing this
    /// task: naming these `runOrCancelButton`/`scopePicker`/`copyMenu` made
    /// `theRunButtonIsTheDefaultAction` misidentify the shortcut as sitting
    /// INSIDE a Button's own span and fail — not because the shortcut moved,
    /// but because the scanner's "Button" match had silently become the
    /// whole `runOrCancelButton` property rather than the real `Button(…)`
    /// call inside it.
    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            wideControls
            narrowControls
        }
    }

    /// A bare `HStack {`, like every other sheet footer in this target —
    /// `SheetOverflowMenuWiringGuardTests` locates a footer by exactly that
    /// line above the Close button, and a sheet whose footer it cannot parse
    /// drops out of that suite's population by throwing rather than by going
    /// quiet.
    private var wideControls: some View {
        HStack {
            primaryAction
            scopeSelector
            copyControl
            Spacer(minLength: 0)
            Button(L10n.string("common.close", "Close"), action: onClose)
                .keyboardShortcut(.cancelAction)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    /// The fallback row: the scope and Run on top, Copy and Close beneath —
    /// the split the design ruling asked for (row 1 picker + Run, row 2 copy
    /// + close), so the control someone is most likely mid-choice on (what
    /// to run) sits directly above the button that acts on it.
    private var narrowControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                scopeSelector
                Spacer(minLength: 0)
                primaryAction
            }
            HStack {
                copyControl
                Spacer(minLength: 0)
                Button(L10n.string("common.close", "Close"), action: onClose)
                    .keyboardShortcut(.cancelAction)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    /// Run, or Cancel while a diagnosis is in flight. Defined once so
    /// `.keyboardShortcut(.defaultAction)` appears exactly once in this file
    /// no matter which of `wideControls`/`narrowControls` is on screen —
    /// `DiagnosticsDoorsGuardTests.theRunButtonIsTheDefaultAction` reads that
    /// single occurrence, positionally, to confirm it is Run's.
    @ViewBuilder
    private var primaryAction: some View {
        if model.isRunning {
            Button(L10n.string("common.cancel", "Cancel")) { model.cancel() }
                .fixedSize(horizontal: true, vertical: false)
        } else {
            Button(
                model.report == nil
                    ? L10n.string("diagnostics.run", "Run check")
                    : L10n.string("diagnostics.runAgain", "Run again")
            ) {
                model.run()
            }
            .buttonStyle(.polished)
            // Return presses Run, and no other control in this panel
            // claims the default action. The connection-tools design's
            // §4 has said since 2026-09-03 that the error dialog's door
            // opens the panel with Run as its default button — a claim
            // about this file that nothing in it backed until the
            // modifier below was added. Close takes the cancel action at
            // the end of the row, so Esc and Return land on the two ends
            // of it. Which button carries this is pinned by the doors
            // guard rather than left to a reader to notice.
            .keyboardShortcut(.defaultAction)
            // Keeps the title on one line rather than wrapping it letter by
            // letter when the footer is narrower than its natural width —
            // exactly what the maintainer's screenshot showed happening
            // here, the widest button in the row, before this task.
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    /// What the button above will measure. Choosing writes the model's
    /// state and does nothing else — no run starts here, which is the
    /// same decision the rest of this file is written under and the one
    /// the doors guard reads this control for. The binding is spelled
    /// out in place rather than bound to a local, so that the control's
    /// only effect is visible in the control.
    ///
    /// Defined once so the `Picker` appears exactly once in this file
    /// (`DiagnosticsDoorsGuardTests.scopeControl`), reused by whichever row
    /// `ViewThatFits` draws.
    ///
    /// Its own visible label is hidden — "What to run"/"Was geprüft
    /// wird"/"Ce qui est vérifié"/"Co sprawdzić" is what ate the footer's
    /// width before this task — with the SAME key kept as an accessibility
    /// label, so VoiceOver still announces what the control does; only the
    /// on-screen column disappears.
    private var scopeSelector: some View {
        Picker(
            L10n.string("diagnostics.scope", "What to run"),
            selection: Binding(get: { model.scope }, set: { model.scope = $0 })
        ) {
            // Every case the type declares, in its own order. A list
            // written out here would be a second copy of an enum in Core,
            // and it is the copy that stops growing.
            ForEach(DiagnosticScope.allCases, id: \.self) { choice in
                Text(DiagnosticsPresentation.scopeName(choice)).tag(choice)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .accessibilityLabel(L10n.string("diagnostics.scope", "What to run"))
        .fixedSize()
    }

    /// Enabled as soon as there is a row to copy, running or not.
    /// The rows are on screen from the first second while the trace can
    /// spend twenty more; disabling copy for those twenty made the way
    /// to copy what you could already read "press Cancel", which is
    /// pressing stop in order to copy. A partial report says so under
    /// its header — see `DiagnosticsViewModel.copyableReport`.
    ///
    /// Defined once so the `Menu` appears exactly once in this file
    /// (`DiagnosticsDoorsGuardTests.copyReportIsAMenuWithTwoEntries`),
    /// reused by whichever row `ViewThatFits` draws.
    private var copyControl: some View {
        Menu(L10n.string("diagnostics.copy", "Copy report")) {
            Button(L10n.string("diagnostics.copy.plainText", "As plain text")) {
                model.copyPlainText()
            }
            Button(L10n.string("diagnostics.copy.markdown", "As Markdown")) {
                model.copyMarkdown()
            }
        }
        .disabled(model.copyableReport == nil)
        .fixedSize(horizontal: true, vertical: false)
    }
}
