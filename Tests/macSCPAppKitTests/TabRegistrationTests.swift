import Foundation
import Testing
@testable import MacSCPAppKit
@testable import macSCPCore

/// Every tab a window makes is known to `TabRegistry` from the statement
/// that makes it (Detachable Tabs plan, Task 3 fix round 1).
///
/// **Why this had to become a rule.** Before this round, five call sites in
/// `ContentView*` called `tabsModel.addTab(…)` directly and the registry
/// caught up later, from `registerHeldTabs()` in the `.onChange(of:
/// tabIDs)` handler — a SwiftUI update pass, not the same main-actor turn.
/// Everything that reads the registry SYNCHRONOUSLY therefore read a count
/// that was one pass behind: `WindowCloseDecision.after(…:windowCount:)`
/// inside both of `TabDetachSequence`'s moves, and `MainWindowPresence`.
/// Nothing observable was traced to it, and that is exactly the shape this
/// project treats as a defect anyway — a second answer to "which window
/// holds this tab", arriving later than the first reader.
///
/// So `TabAdmission.add(_:to:in:window:)` is the one place a tab enters a
/// window, `ContentView.addTabRegistering(_:)` is its only caller in the
/// app, and `TabRegistrationWiringGuardTests` below pins that nothing goes
/// round it.
@Suite("Tab registration")
@MainActor
struct TabRegistrationTests {

    /// The same never-connecting tab `TabRegistryTests`,
    /// `TabsWindowLifecycleTests` and `TabDragTests` build.
    private func makeTab() -> SessionTab {
        SessionTab(
            connectionViewModel: ConnectionViewModel(connector: { _, _ in
                throw CancellationError()
            }),
            certificateBridge: CertificatePromptBridge(),
            limiter: BandwidthLimiter(),
            maxConcurrent: 2)
    }

    /// Both halves, read back in the statement after the call — no awaiting,
    /// no update pass, nothing that could let a later write make this true.
    @Test func aTabAdmittedToAWindowIsInItsModelAndItsRegistryAtOnce() {
        let registry = TabRegistry()
        let window = WindowID()
        let model = TabsViewModel<SessionTab>(initial: makeTab())
        let arriving = makeTab()

        TabAdmission.add(arriving, to: model, in: registry, window: window)

        #expect(model.tabs.contains { $0 === arriving })
        #expect(model.activeTabID == arriving.id)
        #expect(registry.tab(for: arriving.id) === arriving)
        #expect(registry.windowHolding(arriving.id) == window)
        #expect(registry.tabs(in: window).contains { $0 === arriving })
    }

    /// The control that makes the test above worth running: with the plain
    /// `addTab` the model is right and the registry knows nothing, so the
    /// four registry expectations up there really can fail. Without this,
    /// "the registry knew" would be indistinguishable from "the registry
    /// knows everything".
    @Test func aTabAddedWithoutAdmissionIsInNoWindow() {
        let registry = TabRegistry()
        let window = WindowID()
        let model = TabsViewModel<SessionTab>(initial: makeTab())
        let arriving = makeTab()

        model.addTab(arriving)

        #expect(model.tabs.contains { $0 === arriving })
        #expect(registry.tab(for: arriving.id) == nil)
        #expect(registry.tabs(in: window).isEmpty)
    }

    /// `windowCount` is the number the close decision is taken against
    /// (`WindowCloseDecision.after(removing:in:windowCount:)`), and it is
    /// read synchronously inside both of `TabDetachSequence`'s moves. A
    /// window whose only tab was admitted this turn has to count this turn.
    @Test func aWindowCountsAsSoonAsItsFirstTabIsAdmitted() {
        let registry = TabRegistry()
        let first = WindowID()
        let second = WindowID()
        let firstModel = TabsViewModel<SessionTab>(initial: makeTab())
        let secondModel = TabsViewModel<SessionTab>(initial: makeTab())
        #expect(registry.windowCount == 0)

        TabAdmission.add(firstModel.tabs[0], to: firstModel, in: registry, window: first)
        #expect(registry.windowCount == 1)

        TabAdmission.add(secondModel.tabs[0], to: secondModel, in: registry, window: second)
        #expect(registry.windowCount == 2)
    }

    /// The claim path admits a tab the registry has ALREADY moved to this
    /// window (`TabRegistry.claim(seedID:into:)` does the move; the window
    /// then puts it in its own model). Admission must be able to say the
    /// same thing twice without moving it somewhere else.
    @Test func admittingATabTheRegistryAlreadyPlacedHereChangesNothing() {
        let registry = TabRegistry()
        let window = WindowID()
        let model = TabsViewModel<SessionTab>(initial: makeTab())
        let arriving = makeTab()
        registry.register(arriving, in: window)

        TabAdmission.add(arriving, to: model, in: registry, window: window)

        #expect(model.tabs.filter { $0 === arriving }.count == 1)
        #expect(registry.tabs(in: window).filter { $0 === arriving }.count == 1)
        #expect(registry.windowHolding(arriving.id) == window)
    }
}

/// That nothing in the app goes round `TabAdmission` — the half no value
/// test can reach, because a `ContentView` cannot be built outside a view
/// graph (the boundary every wiring guard in this target documents).
///
/// **The negative and its positives.** The negative is that no
/// `ContentView*.swift` file calls `.addTab(` on any receiver, outside
/// `addTabRegistering(_:)`'s own body — widened (Task 6 closeout) from a
/// literal match on `tabsModel.addTab(` alone, which would have gone quiet
/// the moment that property, not the method, was renamed (CLAUDE.md,
/// "Guards that name what they watch"). Four positives stand beside it:
/// `TabAdmission.add(` really is called from `ContentView+Lifecycle.swift`,
/// `addTabRegistering(` occurs there and in the two other files the
/// counted number of times, `TabAdmission`'s own body really does both
/// halves, and the replacement tab each of `TabDetachSequence`'s moves
/// makes registers into the window it lands in the same way. A rename of
/// `addTab`, of `addTabRegistering`, of `tabsModel`, or of
/// `makeTab(registeringIn:)` turns at least one of those red.
@Suite("Tab registration wiring (source guard)")
struct TabRegistrationWiringGuardTests {
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    /// Every `ContentView` file, so a sixth one added later is scanned
    /// without anyone remembering to add it here. Counted 2026-09-05: seven
    /// files match, of which three contain a tab-admitting call site today
    /// (`ContentView.swift`, `+Lifecycle`, `+Detail`).
    private static func contentViewFiles() throws -> [(name: String, source: String)] {
        let directory = repoRoot.appendingPathComponent("Sources/MacSCPAppKit")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("ContentView") && $0.hasSuffix(".swift") }
            .sorted()
        return try names.map { name in
            (name, try SwiftSource.blankingCommentsAndStrings(
                String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)))
        }
    }

    private static func strictSource(of path: String) throws -> String {
        try SwiftSource.blankingCommentsAndStrings(
            String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8))
    }

    /// POSITIVE, first: the files this suite scans are really there, and
    /// really are the window's own code. A directory listing that came back
    /// empty would satisfy the negative below perfectly.
    @Test func theWindowsFilesAreTheOnesBeingScanned() throws {
        let files = try Self.contentViewFiles()
        #expect(files.count == 7, "expected 7 ContentView*.swift files, found \(files.count)")
        #expect(files.contains { $0.name == "ContentView.swift" })
        #expect(files.contains { $0.name == "ContentView+Lifecycle.swift" })
        #expect(files.contains { $0.name == "ContentView+Detail.swift" })
        // Every one of them really is an extension on the window's view —
        // a directory listing that had drifted onto some other family of
        // files would satisfy the negative below without reading a line of
        // `ContentView`. Not `tabsModel`: four of the seven never mention
        // it (counted 2026-09-05 — `+Diagnostics`, `+ExportImport`,
        // `+Sheets` have none, `+Transfers` has one), which says nothing
        // about whether they could add a tab.
        #expect(files.allSatisfy {
            $0.source.contains("extension ContentView") || $0.source.contains("struct ContentView")
        })
    }

    /// NEGATIVE: no window adds a tab to its own model without admitting it.
    ///
    /// Matches `.addTab(` on ANY receiver, not only `tabsModel` by name
    /// (Task 6 closeout) — a model reached under a different local name
    /// would otherwise slip past a check spelled for one identifier. The
    /// one legitimate caller, `addTabRegistering(_:)`'s own body (which
    /// reaches `model.addTab(` indirectly through `TabAdmission.add`, never
    /// directly), is excluded by span rather than by teaching the scan a
    /// second exception to remember.
    @Test func noWindowAddsATabWithoutAdmittingIt() throws {
        for file in try Self.contentViewFiles() {
            var scanned = file.source
            if file.name == "ContentView+Lifecycle.swift" {
                let bodyRange = try TransferQueueBarCancelGuardTests.declarationBodyRange(
                    of: "func addTabRegistering(_ tab: SessionTab)", in: scanned)
                var chars = Array(scanned)
                for index in bodyRange { chars[index] = " " }
                scanned = String(chars)
            }
            #expect(!scanned.contains(".addTab("), """
                \(file.name) calls `.addTab(` directly outside `addTabRegistering(_:)`. A \
                tab added that way is unknown to `TabRegistry` until the next \
                `.onChange(of: tabIDs)` pass, and `WindowCloseDecision` reads `windowCount` \
                in the same turn a drag lands. Route it through `addTabRegistering(_:)`.
                """)
        }
    }

    /// POSITIVE beside it: the route that replaced those calls exists and is
    /// used. Recounted 2026-09-05 across the three files that have any:
    /// `ContentView+Lifecycle.swift` 4 (the declaration plus the ⌘N command,
    /// the claim, and the restoration rebuild added by the Detachable Tabs
    /// plan's Task 5), `ContentView.swift` 2 (a new connection over a
    /// connected tab, and `formTarget()`), `ContentView+Detail.swift` 1
    /// (the strip's ⊕ button) — seven occurrences, six of them calls.
    @Test func everyTabThisWindowMakesGoesThroughTheOneDoor() throws {
        let counts = try Self.contentViewFiles().reduce(into: [String: Int]()) { totals, file in
            totals[file.name] = TransferQueueBarCancelGuardTests.occurrenceCount(
                of: "addTabRegistering(", in: file.source)
        }
        #expect(counts["ContentView+Lifecycle.swift"] == 4)
        #expect(counts["ContentView.swift"] == 2)
        #expect(counts["ContentView+Detail.swift"] == 1)
        #expect(counts.values.reduce(0, +) == 7, """
            expected 7 `addTabRegistering(` occurrences across ContentView*.swift (one \
            declaration and six calls), found \(counts.values.reduce(0, +)). A new tab \
            site is not a problem — count it here and say what it does.
            """)
    }

    /// POSITIVE: the door leads somewhere, and the somewhere does both
    /// halves. Without this the helper could be an `addTab` with a longer
    /// name and every check above would still pass.
    @Test func theOneDoorAddsAndRegisters() throws {
        let helper = try TransferQueueBarCancelGuardTests.declarationBody(
            of: "func addTabRegistering(_ tab: SessionTab)",
            in: try Self.strictSource(of: "Sources/MacSCPAppKit/ContentView+Lifecycle.swift"))
        #expect(helper.contains("TabAdmission.add("))
        let admission = try TransferQueueBarCancelGuardTests.declarationBody(
            of: "static func add(", in: try Self.strictSource(
                of: "Sources/MacSCPAppKit/TabAdmission.swift"))
        #expect(admission.contains("model.addTab("))
        #expect(admission.contains("registry.register("))
    }

    /// The replacement tab both of `TabDetachSequence`'s moves put in a
    /// leaver's place is made by the view, not by the sequence, so it is a
    /// creation site like any other — and it is the one that must register
    /// into a window that is NOT always this one (`acceptDroppedTab` builds
    /// the source window's replacement). Counted 2026-09-05: two CALLS in
    /// `ContentView+Lifecycle.swift`, one per move. The declaration spells
    /// the label without a colon (`registeringIn window:`) and so is not
    /// among them, which is why it is asserted separately below — a count
    /// with nothing declared to call would otherwise be a count of two
    /// calls to nothing.
    @Test func aReplacementTabIsRegisteredIntoTheWindowItLandsIn() throws {
        let source = try Self.strictSource(of: "Sources/MacSCPAppKit/ContentView+Lifecycle.swift")
        #expect(source.contains("func makeTab(registeringIn window: WindowID) -> SessionTab"))
        let uses = TransferQueueBarCancelGuardTests.occurrenceCount(
            of: "makeTab(registeringIn:", in: source)
        #expect(uses == 2, """
            expected 2 `makeTab(registeringIn:` calls in ContentView+Lifecycle.swift, one \
            per `TabDetachSequence` move, found \(uses).
            """)
        #expect(source.contains("replacement: { makeTab(registeringIn: windowID) }"))
        #expect(source.contains("replacement: { makeTab(registeringIn: payload.sourceWindowID) }"))
    }

    /// The mirror. Every path that takes tabs OUT of a window's model
    /// releases them from the registry too — otherwise `tabs(in:)` keeps
    /// answering with tabs that are gone and `tab(for:)` resolves them.
    /// `performClose` had this from Task 2; `performCloseOthers` did not,
    /// and gained it in this round — through
    /// `closeOthersReportingRemoved(besides:)` since Task 6 closeout, not
    /// the plain `closeOthers(besides:)` (see that method's own doc
    /// comment for why: a snapshot taken before this function's teardown
    /// loop can miss a tab a cross-window drag adds mid-loop).
    @Test func everyPathThatRemovesTabsReleasesThem() throws {
        let source = try Self.strictSource(of: "Sources/MacSCPAppKit/ContentView+Lifecycle.swift")
        for closer in ["func performClose(_ tab: SessionTab) async",
                       "func performCloseOthers(of tab: SessionTab) async"] {
            let body = try TransferQueueBarCancelGuardTests.declarationBody(
                of: closer, in: source)
            #expect(
                body.contains("closeTab(") || body.contains("closeOthers(")
                    || body.contains("closeOthersReportingRemoved("),
                "the scanned span is not \(closer)")
            #expect(body.contains("TabRegistry.shared.release("), """
                `\(closer)` removes tabs from the model without releasing them from the \
                registry. `tabs(in:)` would keep answering with them and `tab(for:)` would \
                keep resolving them.
                """)
        }
    }
}
