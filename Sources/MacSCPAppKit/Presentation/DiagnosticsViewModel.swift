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

    /// One diagnosis, start to finish, told about each step as it starts and
    /// again as it finishes.
    ///
    /// The observer is the argument rather than a property because a fake in a
    /// test has to be able to announce a step, emit rows and then park — which
    /// is what pins "the rows are on screen while the walk is still walking"
    /// and "the line names the step that is taking the time".
    /// Cancellation reaches the runner through the task that runs it, and
    /// `ConnectionDiagnostics` answers a cancelled task with the steps it had
    /// already measured.
    ///
    /// The scope is a PARAMETER rather than something the runner closes over,
    /// because the user picks it between runs: a closure built once at
    /// construction would carry whatever was chosen when the panel opened, and
    /// the menu would change nothing.
    typealias Runner = @Sendable (DiagnosticScope, DiagnosticRunObserver) async
        -> DiagnosticReport

    /// What the header calls this connection.
    let name: String

    /// Where this diagnosis is pointed, known before the first probe runs.
    ///
    /// Carried across the seam rather than waited for: it is
    /// `descriptor.endpoint(values)`, a `public let` the convenience
    /// initializer below already has a descriptor to ask, and having it here
    /// is what lets a run that is still walking be COPIED — its rows are on
    /// screen, and a header needs an endpoint. `nil` for a session that names
    /// no host, where there is nothing coherent to put in that line.
    let endpoint: Endpoint?

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
    ///
    /// Published exactly as the runner produced it, cancellation label
    /// included: the runner is the only thing that knows whether the walk
    /// reached its end, and re-deciding that here would be a second copy of
    /// the answer.
    private(set) var report: DiagnosticReport?

    /// What the next run will measure — everything, or one probe.
    ///
    /// Settable, and settable is the point: the panel's menu writes it, and
    /// writing it starts NOTHING (decision of 2026-09-02, and the reason the
    /// doors guard reads the control). `run()` takes what it finds here at the
    /// moment it is pressed, so a scope chosen while a walk is going changes
    /// the next walk rather than the one on screen.
    ///
    /// `.complete` by default: a panel nobody has touched runs the whole
    /// diagnosis, which is what every door promised before this menu existed.
    var scope: DiagnosticScope = .complete

    /// Whether a diagnosis is in flight. Drives the panel's progress row and
    /// swaps its Run button for Cancel; it is not a second copy of "is the
    /// task alive", it is what the user is told.
    private(set) var isRunning = false

    /// The catalogue key of the step being measured right now, or `nil` when
    /// no step is in flight — between two steps, before the first, and after
    /// the run has ended.
    ///
    /// A KEY and not a name: Core announces a step under the same
    /// `titleKey` its finished row will carry (`DiagnosticRunObserver`), the
    /// panel resolves it through the catalogs like any other row title, and
    /// nothing here decides what a step is called. Nothing about the endpoint
    /// reaches it either — the running line is a step name and never a host,
    /// a port or anything the user typed.
    ///
    /// Cleared the moment the step's own row lands, because a step that has
    /// produced a row is finished: naming it beside its own row would tell the
    /// reader two different things about one step.
    private(set) var runningStepTitleKey: String?

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

    /// What the run in flight was started with — not what the menu says now.
    ///
    /// The two differ for exactly as long as a walk lasts and the user is free
    /// to touch the menu, which is precisely the window in which a report gets
    /// copied (`copyableReport`, and the reason Copy is enabled while a run
    /// walks). A snapshot headed with the menu's current value would name a
    /// scope nothing on screen was measured under.
    ///
    /// `@ObservationIgnored`, like `attempt`: it is written only where `steps`
    /// is cleared, so every render that could read it is triggered by that
    /// write anyway.
    @ObservationIgnored private var walkingScope: DiagnosticScope = .complete

    @ObservationIgnored private let runner: Runner
    /// Where a copied report goes. A seam rather than a direct
    /// `NSPasteboard.general` call — the app has no pasteboard abstraction to
    /// reuse (every other copy site writes the general pasteboard inline), and
    /// a test cannot read the user's real clipboard without clobbering it.
    @ObservationIgnored private let copy: (String) -> Void

    @ObservationIgnored private let appVersion: String

    init(
        name: String,
        endpoint: Endpoint? = nil,
        appVersion: String = DiagnosticsViewModel.bundleVersion,
        runner: @escaping Runner,
        copy: @escaping (String) -> Void = DiagnosticsViewModel.writeToPasteboard
    ) {
        self.name = name
        self.endpoint = endpoint
        self.appVersion = appVersion
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
        let version = Self.bundleVersion
        let diagnostics = ConnectionDiagnostics(
            descriptor: descriptor, values: target.values, secrets: secrets,
            sessionID: target.sessionID, appVersion: version)
        self.init(
            name: target.name,
            // The same answer Core's first line computes, from the same
            // descriptor — asked here so the panel can name the endpoint, and
            // copy a partial report, before the walk has returned anything.
            endpoint: descriptor.endpoint(target.values),
            appVersion: version,
            runner: { scope, observer in
                await diagnostics.run(scope: scope, observer: observer)
            })
    }

    /// Starts a diagnosis of whatever `scope` says. The ONLY thing that does.
    ///
    /// Stops whatever was running through `cancel()` rather than reaching for
    /// `runTask` itself — one method owns the cancellation, which is what
    /// lets `DiagnosticsDoorsGuardTests` DERIVE that method's name instead of
    /// spelling it.
    ///
    /// The scope is read HERE, at the press, and carried into the task as a
    /// value: a run that read it again later would change what it is measuring
    /// under a user who touched the menu while it walked, and the report it
    /// hands back names the scope it was started with.
    func run() {
        cancel()
        let myAttempt = UUID()
        attempt = myAttempt
        isRunning = true
        steps = []
        report = nil
        runningStepTitleKey = nil
        let runner = self.runner
        let scope = self.scope
        walkingScope = scope
        runTask = Task { [weak self] in
            // `[weak self]` again in both halves, and not redundantly: inside
            // `Task { [weak self] … }` the name is an optional LOCAL, and a
            // nested closure capturing it captures it strongly — the runner
            // would then hold the model alive for the length of the walk, and
            // a panel dropped by `end()` would go on collecting rows nobody
            // can see. Re-weakening here is what makes the outer capture mean
            // what it says.
            //
            // Every event is also checked against the attempt that produced
            // it. A superseded run keeps walking until its cancellation
            // reaches it, and its late rows would otherwise append to the list
            // the reader is looking at — and its late STARTS would put a step
            // name over a walk that is not measuring them.
            let observer = DiagnosticRunObserver(
                onStepStarted: { [weak self] _, titleKey in
                    await MainActor.run { self?.stepStarted(titleKey, from: myAttempt) }
                },
                onStep: { [weak self] step in
                    await MainActor.run { self?.append(step, from: myAttempt) }
                })
            let produced = await runner(scope, observer)
            guard let self, self.attempt == myAttempt else { return }
            // A report with no steps is not a result. `ConnectionDiagnostics`
            // answers a task cancelled before the resolve step with exactly
            // that, and publishing it would swap the panel's idle explanation
            // for an empty rows area, offer "Run again" and enable the Copy
            // menu — three controls describing a measurement that never
            // happened. The run is over either way, so `isRunning` clears
            // regardless.
            if !produced.steps.isEmpty { self.report = produced }
            // The run is over — finished or cancelled, the runner answers
            // either way — so nothing is being measured and nothing may go on
            // being named. This is also where a CANCEL clears the line: the
            // cancellation reaches the walk, the walk returns what it had, and
            // the return lands here.
            self.runningStepTitleKey = nil
            self.isRunning = false
        }
    }

    /// One step about to be measured, from the run that is allowed to write.
    private func stepStarted(_ titleKey: String, from producer: UUID) {
        guard attempt == producer else { return }
        runningStepTitleKey = titleKey
    }

    /// One finished row, from the run that is allowed to write.
    private func append(_ step: DiagnosticStep, from producer: UUID) {
        guard attempt == producer else { return }
        steps.append(step)
        // The row IS the end of the step. The next step announces itself
        // before it starts measuring, so the line goes back to its unnamed
        // spelling for exactly the gap between the two.
        runningStepTitleKey = nil
    }

    /// Stops the running diagnosis. What it measured before the stop stays:
    /// `steps` is not cleared, and the runner hands back the rows it finished,
    /// which are the answer to "where did it get stuck". The name of the step
    /// it was stopped in the middle of does NOT stay — `run()`'s task clears
    /// it where it clears `isRunning`, on the answer the cancelled walk
    /// returns.
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

    /// What "Copy report" would put on the pasteboard right now, or `nil`
    /// when there is nothing worth copying.
    ///
    /// The report a finished or cancelled run produced when there is one —
    /// carrying whatever `DiagnosticReport.Completion` the runner labelled it
    /// with, so a cancel's "(cancelled after n steps)" marker reaches the
    /// pasteboard as measured. Otherwise the rows measured so far, rendered as
    /// a report that says it is one: `.running` puts "(run in progress)" under
    /// the header, so a partial paste cannot be read as a walk whose missing
    /// steps were measured and found absent.
    ///
    /// `nil` before the first row, and for a session with no endpoint to
    /// name. The second of those is about what a MID-RUN snapshot is worth,
    /// not about a fabricated header: a walk with no endpoint stops at its
    /// first row, so its only report is the one Core builds and publishes,
    /// and there is nothing this branch could add to it.
    ///
    /// The fabrication that used to be the reason here is gone from the other
    /// end: Core's endpointless report carries no endpoint at all, and both
    /// renderers omit the header line rather than printing one nobody
    /// measured (`DiagnosticReport.endpoint`).
    ///
    /// The scope goes in too, and it is the WALKING one rather than the menu's
    /// current value: Core stamps a finished report with what it was asked to
    /// run, and this snapshot is the only report built outside Core. Without
    /// it, a trace-only run copied while it walked pasted a header claiming
    /// the complete diagnosis — and the steps it left out then read as steps
    /// that were measured and found absent.
    var copyableReport: DiagnosticReport? {
        if let report { return report }
        guard !steps.isEmpty, let endpoint else { return nil }
        return DiagnosticReport(
            endpoint: endpoint, steps: steps, appVersion: appVersion, completion: .running,
            scope: walkingScope)
    }

    func copyPlainText() {
        guard let report = copyableReport else { return }
        copy(report.plainText())
    }

    func copyMarkdown() {
        guard let report = copyableReport else { return }
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
    nonisolated static var bundleVersion: String {
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

    /// What the menu beside Run calls one choice.
    ///
    /// A switch rather than a key composed from the case's `rawValue`.
    /// `DiagnosticsDoorsGuardTests` compares the `diagnostics.*` keys the
    /// SOURCES spell against `en.lproj` for equality, and an interpolated key
    /// is invisible to that scan — the five entries would be translations
    /// nothing requires, in four catalogs, with the check green either way.
    /// Being exhaustive, it also means a sixth scope in Core does not compile
    /// until it has a name here.
    static func scopeName(_ scope: DiagnosticScope) -> String {
        switch scope {
        case .complete:
            return L10n.string("diagnostics.scope.complete", "Everything")
        case .ping:
            return L10n.string("diagnostics.scope.ping", "Ping")
        case .trace:
            return L10n.string("diagnostics.scope.trace", "Trace")
        case .dial:
            return L10n.string("diagnostics.scope.dial", "Connect")
        case .contributions:
            return L10n.string("diagnostics.scope.contributions", "Protocol probes")
        }
    }

    /// One column header of a step's table.
    ///
    /// `DiagnosticTable.columns` are catalogue KEYS rather than text — Core
    /// does not decide what language a window is in — so this is the lookup.
    /// The fallback is the key's last component, which is exactly what the
    /// report prints for the same column, so a key the catalogs do not carry
    /// yet reads as `outcome` rather than as the whole key.
    static func columnTitle(_ key: String) -> String {
        L10n.string(key, key.components(separatedBy: ".").last ?? key)
    }

    /// One cell of a step's table, in the reader's language where it is a word
    /// this project chose and byte for byte where it is a measurement.
    ///
    /// The measured cells — a hop number, an address, a round trip — are
    /// copied through for the same reason the detail line is: they are what
    /// somebody pastes into a bug report, and a translated address is one its
    /// reader cannot search for. Only the outcome column holds words Core
    /// COMPOSED, and which column that is comes from the table's own key
    /// rather than from a position a reordering would silently change.
    static func cell(_ text: String, column key: String) -> String {
        guard key == DiagnosticTraceColumn.outcome else { return text }
        return traceOutcome(text)
    }

    /// The trace's outcome word, looked up under its own key.
    ///
    /// The words are Core's constants and are never spelled here (CLAUDE.md,
    /// "a guard that spells a symbol it could read"): a rename in Core drops
    /// the lookup and shows the measured word, rather than translating a word
    /// nothing produces any more.
    private static func traceOutcome(_ cell: String) -> String {
        switch cell {
        case DiagnosticTraceColumn.answered:
            return L10n.string("diagnostics.trace.outcome.answered", cell)
        case DiagnosticTraceColumn.silent:
            return L10n.string("diagnostics.trace.outcome.silent", cell)
        case DiagnosticTraceColumn.destination:
            return L10n.string("diagnostics.trace.outcome.destination", cell)
        default:
            guard let code = unreachableCode(in: cell) else { return cell }
            return String(
                format: L10n.string("diagnostics.trace.outcome.unreachable", cell), code)
        }
    }

    /// The code out of `unreachable (code 13)`, or `nil` where the cell is not
    /// that sentence at all.
    ///
    /// Read by composing Core's own spelling back from the number and
    /// comparing: this file therefore holds no second copy of that format, and
    /// a change to it in Core makes this return `nil` — the measured cell,
    /// shown as measured — instead of quietly mis-parsing.
    private static func unreachableCode(in cell: String) -> String? {
        let digits = cell.filter(\.isNumber)
        guard let code = UInt8(digits), DiagnosticTraceColumn.unreachable(code: code) == cell
        else { return nil }
        return digits
    }

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
