import AppKit
import Foundation
import Observation
import macSCPCore

/// What a door hands the panel: which connection the diagnosis is pointed at,
/// and where its credential may be resolved from.
///
/// A value, taken at the moment the user asked for it. The three doors reach
/// the panel from surfaces whose own state moves underneath them — a tab that
/// reconnects, a sidebar row that is renamed, a form the user keeps typing in
/// — and a panel that read those live would change what it is diagnosing while
/// the diagnosis was running. Same reasoning, and the same shape, as
/// `AlreadyOpenSessionRequest` carrying its `StoredSession`.
///
/// `values` carries whatever the form or the stored record holds, INCLUDING
/// the secret fields where those were filled — but the dial does not read them
/// from here: it resolves through `sessionID` and the secret source, which is
/// the resolver the connect itself uses (design §3). A session that was never
/// saved therefore diagnoses everything except the authenticated dial, and the
/// dial row says why rather than pretending.
struct DiagnosticsTarget: Identifiable {
    /// Fresh per request, so asking a second time re-presents the sheet even
    /// when the same session is named twice.
    let id = UUID()
    /// What the panel calls this connection in its header — the session's
    /// name, or the tab's.
    let name: String
    let kind: ConnectionKind
    let values: FieldValues
    /// The slot the secret source answers under: a session's own id, or the
    /// login set's where one owns the credential. `nil` for a connection that
    /// was never saved, and the dial step reports that as `skipped`.
    let sessionID: UUID?
}

/// The panel's half of the diagnosis: it starts one, cancels one, holds the
/// report, and copies it in the two shapes the maintainer asked for.
///
/// **A run starts only when `run()` is called**, and `run()` is called only
/// from the panel's button (decision of 2026-09-02; `DiagnosticsDoorsGuardTests`
/// holds the panel, every door and the entry that opens it to that). Nothing in
/// this type reacts to a view appearing, and a freshly built one has measured
/// nothing.
///
/// Built by `ContentView.showDiagnostics(for:)` and held by that window's
/// `DiagnosticsPresenter`; the panel receives it. Window scope, never a
/// singleton (CLAUDE.md, "Architecture invariants") — two windows diagnosing
/// two connections hold two of these. The window owns it rather than the sheet
/// because stopping a run has to be possible from paths the panel is not on:
/// the tab's teardown, and a panel replaced rather than dismissed.
///
/// The runner is injected rather than built in place, so the suite can drive
/// run/cancel/report over a fake and never open a socket. Production passes the
/// closure the convenience initializer below builds around
/// `ConnectionDiagnostics`.
@MainActor
@Observable
final class DiagnosticsViewModel: Identifiable {
    /// Identity for the sheet that presents this panel. Fresh per model, and
    /// stable for its life, so asking a second time re-presents the sheet
    /// while an observable change inside a live one does not.
    nonisolated let id = UUID()

    /// One diagnosis, start to finish, told about each step as it finishes.
    ///
    /// The observer is the argument rather than a property because a fake in a
    /// test has to be able to emit rows and then park — which is what pins
    /// "the rows are on screen while the walk is still walking".
    /// Cancellation reaches the runner through the task that runs it, and
    /// `ConnectionDiagnostics` answers a cancelled task with the steps it had
    /// already measured.
    typealias Runner = @Sendable (@escaping DiagnosticStepObserver) async -> DiagnosticReport

    /// What the header calls this connection.
    let name: String

    /// Every step measured by the run in flight, or by the last one — in the
    /// order they finished, appended as each one arrives.
    ///
    /// This is what the panel draws. It exists beside `report` rather than
    /// inside it because a report carries an endpoint and a build line that
    /// only the finished run can supply, while a row is complete the moment it
    /// is measured; the alternative was inventing an endpoint for a report
    /// that is not one yet, in a value whose whole job is to be pasted into a
    /// bug report.
    ///
    /// Cleared when a new run starts, never by a cancellation: the partial
    /// measurement IS the measurement.
    private(set) var steps: [DiagnosticStep] = []

    /// The last diagnosis as a copyable artifact — set when a run ENDS,
    /// whether it ended by finishing or by being cancelled. `nil` until then,
    /// which is what leaves the copy menu disabled over a run that has
    /// measured nothing.
    private(set) var report: DiagnosticReport?

    /// Whether a diagnosis is in flight. Drives the panel's progress row and
    /// swaps its Run button for Cancel; it is not a second copy of "is the
    /// task alive", it is what the user is told.
    private(set) var isRunning = false

    /// The running diagnosis, exposed so a caller can await it. The panel
    /// never does — SwiftUI reads `report`/`isRunning` — but a test must, and
    /// a test that polls a flag instead is a test that spins.
    @ObservationIgnored private(set) var runTask: Task<Void, Never>?

    /// Which run's answer is allowed to land. A superseded or abandoned run
    /// returns eventually — `ConnectionDiagnostics` hands back a partial
    /// report on cancellation — and without this its answer could overwrite
    /// the run that replaced it. Same shape, and the same reason, as
    /// `ConnectionViewModel.currentAttempt`.
    @ObservationIgnored private var attempt = UUID()

    @ObservationIgnored private let runner: Runner
    /// Where a copied report goes. A seam rather than a direct
    /// `NSPasteboard.general` call — the app has no pasteboard abstraction to
    /// reuse (every other copy site writes the general pasteboard inline), and
    /// a test cannot read the user's real clipboard without clobbering it.
    @ObservationIgnored private let copy: (String) -> Void

    init(
        name: String,
        runner: @escaping Runner,
        copy: @escaping (String) -> Void = DiagnosticsViewModel.writeToPasteboard
    ) {
        self.name = name
        self.runner = runner
        self.copy = copy
    }

    /// The production runner: the universal probes plus this backend's own,
    /// through the descriptor seam.
    ///
    /// `appVersion` is read here and not in Core — Core touches no bundle
    /// (`DiagnosticReport.appVersion`'s own doc comment) — the same way
    /// `SettingsView` and `UpdateCheckModel` read it.
    convenience init(target: DiagnosticsTarget, secrets: (any SecretSource)?) {
        let descriptor = BackendDescriptor.descriptor(for: target.kind)
        let diagnostics = ConnectionDiagnostics(
            descriptor: descriptor, values: target.values, secrets: secrets,
            sessionID: target.sessionID, appVersion: Self.appVersion)
        self.init(name: target.name, runner: { onStep in await diagnostics.run(onStep: onStep) })
    }

    /// Starts a diagnosis. The ONLY thing that does.
    ///
    /// Stops whatever was running through `cancel()` rather than reaching for
    /// `runTask` itself — one method owns the cancellation, which is what
    /// lets `DiagnosticsDoorsGuardTests` DERIVE that method's name instead of
    /// spelling it.
    func run() {
        cancel()
        let myAttempt = UUID()
        attempt = myAttempt
        isRunning = true
        steps = []
        report = nil
        let runner = self.runner
        runTask = Task { [weak self] in
            let produced = await runner { step in
                // Every row is checked against the attempt that produced it.
                // A superseded run keeps walking until its cancellation
                // reaches it, and its late rows would otherwise append to the
                // list the reader is looking at.
                await MainActor.run { self?.append(step, from: myAttempt) }
            }
            guard let self, self.attempt == myAttempt else { return }
            // A report with no steps is not a result. `ConnectionDiagnostics`
            // answers a task cancelled before the resolve step with exactly
            // that, and publishing it would swap the panel's idle explanation
            // for an empty rows area, offer "Run again" and enable the Copy
            // menu — three controls describing a measurement that never
            // happened. The run is over either way, so `isRunning` clears
            // regardless.
            if !produced.steps.isEmpty { self.report = produced }
            self.isRunning = false
        }
    }

    /// One finished row, from the run that is allowed to write.
    private func append(_ step: DiagnosticStep, from producer: UUID) {
        guard attempt == producer else { return }
        steps.append(step)
    }

    /// Stops the running diagnosis. What it measured before the stop stays:
    /// `steps` is not cleared, and the runner hands back the rows it finished,
    /// which are the answer to "where did it get stuck".
    ///
    /// Reached from `run()` (superseding whatever was in flight), the panel's
    /// Cancel button, `DiagnosticsPanel`'s `.onDisappear`,
    /// `DiagnosticsPresenter.end()` — which is where a dismissal arrives —
    /// and `DiagnosticsPresenter.stopRun(openedFor:)`, which is where a
    /// teardown of the diagnosed tab arrives. Named, not counted: the number
    /// is what goes stale.
    ///
    /// The last two exist because `runTask` is a free `Task`: tearing a view
    /// down does not touch it, and a diagnosis nobody can see is still an SSH
    /// dial authenticating against somebody's server.
    func cancel() {
        runTask?.cancel()
    }

    func copyPlainText() {
        guard let report else { return }
        copy(report.plainText())
    }

    func copyMarkdown() {
        guard let report else { return }
        copy(report.markdown())
    }

    /// The general pasteboard, written the way every other copy entry in this
    /// target writes it (`ContentView.copyPaths(of:)`, `PathBar`,
    /// `PresignedURLSheet`).
    /// `nonisolated` because it is a DEFAULT ARGUMENT, and a default argument
    /// is evaluated where the initializer is called rather than inside the
    /// actor it belongs to. `NSPasteboard` carries no main-actor requirement,
    /// and the call sites are all on the main actor anyway.
    nonisolated static func writeToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// The running build's short version string — the same read
    /// `SettingsView` and `UpdateCheckModel` make.
    private static var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "unknown"
    }
}

/// The window's open diagnostics panel, if any — and the one place a
/// diagnosis is stopped when it goes away.
///
/// A window-scoped object rather than a plain `@State` optional, for two
/// reasons that are really one. Dropping the panel has to CANCEL as well as
/// forget, and those two writes belong together or the next restructure keeps
/// one of them; and a reference the window holds is something the real
/// `ContentView` can be driven through in a test, which a `@State` value
/// written outside a render pass is not (`DiagnosticsLifecycleTests` runs both
/// paths for real).
///
/// Not a singleton: one per window, created with the window's own
/// `ContentView`. Two windows diagnosing two connections hold two, and neither
/// can see or stop the other's run — the architecture invariant this feature
/// inherited from the session scope.
@MainActor
@Observable
final class DiagnosticsPresenter {
    private(set) var open: DiagnosticsViewModel?

    /// The tab the open panel was opened FOR, or `nil` for one opened from
    /// the sidebar, which belongs to no tab.
    ///
    /// Recorded so that a teardown can tell "the connection this panel is
    /// about is over" from "some other connection in this window is over".
    /// Without it, closing an unrelated tab stopped a diagnosis of a different
    /// server — `performCloseOthers` and the reconnect-in-place branch both
    /// did.
    private(set) var openedFor: UUID?

    /// Shows a panel, stopping whatever the last one was doing.
    ///
    /// A panel replaced rather than dismissed has nothing on screen left to
    /// stop its run, so the replacement does it.
    func present(_ model: DiagnosticsViewModel, for tabID: UUID?) {
        end()
        open = model
        openedFor = tabID
    }

    /// Drops the panel and stops its diagnosis — the dismissal path, and the
    /// only one that discards anything. Cancel FIRST: the reference is the
    /// only way to reach the run, so forgetting it first would leave the walk
    /// going with nothing able to stop it.
    func end() {
        open?.cancel()
        open = nil
        openedFor = nil
    }

    /// Stops the run of a panel opened for `tabID`, and leaves the panel
    /// standing.
    ///
    /// The teardown path, and the split that fix round 2 exists for. Stopping
    /// is right — the walk is dialling a connection the window has finished
    /// with, and closing a tab does not dismiss the sheet by itself, so
    /// nothing else would stop it. DISMISSING is not: `teardown` runs for six
    /// callers and `handleLivenessGiveUp` is not a user action at all. The
    /// session dropping is precisely why the panel is open, and the rows are
    /// the only thing that can say whether the host stopped resolving, the
    /// port stopped accepting, or the auth started failing. They stay until
    /// the person closes the sheet.
    ///
    /// A panel that belongs to no tab (`openedFor == nil`, the sidebar door)
    /// is claimed by no teardown: `nil == nil` would have every teardown stop
    /// it, which is the bug in a different spelling.
    func stopRun(openedFor tabID: UUID) {
        guard openedFor == tabID else { return }
        open?.cancel()
    }
}

/// What one row of the report says, in the reader's language.
///
/// The REPORT stays English — it is pasted into bug reports, and
/// `DiagnosticReport`'s own doc comment states why. This is the other half:
/// the panel renders each step's `titleKey` and each outcome through the App's
/// catalogs, and falls back to what Core measured wherever there is no key.
enum DiagnosticsPresentation {
    /// The row's title. The default is the step's stable id, so a key Core
    /// starts emitting before a catalog carries it renders as `s3.accessLevel`
    /// rather than as an empty row.
    static func title(of step: DiagnosticStep) -> String {
        L10n.string(step.titleKey, step.id)
    }

    /// The outcome badge. Five words for five outcomes, and they must stay
    /// five: "not available" and "skipped" are about THIS build and this
    /// session, and a badge that read them as a failure would send the user
    /// after a problem they do not have (`DiagnosticOutcome`'s own doc
    /// comment).
    static func badge(for outcome: DiagnosticOutcome) -> String {
        switch outcome {
        case .ok:
            return L10n.string("diagnostics.outcome.ok", "OK")
        case .failed:
            return L10n.string("diagnostics.outcome.failed", "Failed")
        case .timedOut:
            return L10n.string("diagnostics.outcome.timedOut", "Timed out")
        case .unavailable:
            return L10n.string("diagnostics.outcome.unavailable", "Not available")
        case .skipped:
            return L10n.string("diagnostics.outcome.skipped", "Skipped")
        }
    }

    /// The sentence beside the badge, localized where Core composed it and
    /// verbatim where it measured it. `DiagnosticReason.key(for:)` is what
    /// tells the two apart — a `strerror`, an `NSError`'s text or a server's
    /// own message has no key and is shown exactly as it was measured.
    static func reason(of outcome: DiagnosticOutcome) -> String {
        switch outcome {
        case .ok, .timedOut:
            return ""
        case .failed(let reason), .unavailable(let reason), .skipped(let reason):
            guard let key = DiagnosticReason.key(for: reason) else { return reason }
            return L10n.string(key, reason)
        }
    }

    /// The row's detail line, with the one fixed sentence Core writes into a
    /// detail rendered in the reader's language.
    ///
    /// Everything else is copied through byte for byte, and that is the point:
    /// the detail is the addresses, ports, statuses and hop rows somebody
    /// pastes into a bug report, and translating those would make the report
    /// unsearchable by the person reading it (`DiagnosticReport`'s own doc
    /// comment). The trace's markers are the exception because they are not
    /// measurements — they say the walk STOPPED looking, whether at its
    /// budget or at its hop limit, which is the one thing in the line a
    /// reader has to understand rather than quote.
    ///
    /// Core finds the marker (`DiagnosticReason.marker(in:)`) and this
    /// substitutes it; the raw row is the fallback, so a catalog missing the
    /// key shows the English Core composed rather than nothing.
    static func detail(of step: DiagnosticStep) -> String {
        step.detail
            .components(separatedBy: rowSeparator)
            .map { row in
                guard let marker = DiagnosticReason.marker(in: row) else { return row }
                return String(format: L10n.string(marker.key, row), "\(marker.hop)")
            }
            .joined(separator: rowSeparator)
    }

    /// How `ConnectionDiagnostics` joins the rows of a detail line.
    private static let rowSeparator = "; "

    /// The row's duration, in the same fixed-point milliseconds the report
    /// prints. The NUMBER is formatted against `en_US_POSIX` for the reason
    /// Core's own formatter is: two people pasting the same run must produce
    /// the same text, and a decimal comma would split a Markdown cell in two.
    static func duration(of step: DiagnosticStep) -> String {
        let components = step.duration.components
        let milliseconds = Double(components.seconds) * 1000
            + Double(components.attoseconds) / 1_000_000_000_000_000
        let number = String(
            format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), milliseconds)
        return String(format: L10n.string("diagnostics.duration", "%@ ms"), number)
    }
}
