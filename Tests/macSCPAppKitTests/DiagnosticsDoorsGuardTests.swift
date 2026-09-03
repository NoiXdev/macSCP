import Foundation
import Testing

/// Guards the doors onto the diagnostics panel, and the rules the panel itself
/// was decided under (design §1/§4, decisions of 2026-09-02).
///
/// **The properties are the `@Test` names below, and this comment does not
/// list them.** It listed four while the suite guarded seven, twice — a
/// header enumeration is a claim about the rest of the file, and it goes stale
/// the moment a test is added, which is exactly when nobody is looking at the
/// header. What the two decisions ARE is worth writing down; which checks
/// happen to encode them is not.
///
/// The decisions:
///
/// * **A diagnosis runs when the user presses the button** — never on appear,
///   never after a failed connect, never from the entry that opens the panel.
///   It dials the user's server, and the SSH dial authenticates while doing
///   it; opening a panel is not consent to that. Every negative check here is
///   written against that.
/// * **"Copy report" offers plain text and Markdown**, as two entries of one
///   menu.
/// * **One entry.** Four surfaces offer "Diagnose…" — the toolbar of a
///   connected tab, the failed-connect surface, the session context menu and
///   the connect-error dialog — and they reach the panel through one function
///   on the window, because what a door has to get right is not the button but
///   the secret source, the descriptor and the session id the dial resolves
///   under. A second entry beside the first is how one of them quietly stops
///   carrying a rule the others do.
///
/// ## Nothing here spells a symbol it could read
///
/// The seed is one FILE PATH — the view model's — and the rest is derived from
/// the tree:
///
/// * the target type is the single `Identifiable` struct that file declares;
/// * the window's entry function is the single function, anywhere else in the
///   app target, that CONSTRUCTS that type;
/// * the run entry is the single method of the view model that starts a task,
///   and the cancel entry the single one that cancels it;
/// * the view model's own type is the one that owns the run entry, and the
///   presenter's "show this" method the single function in that file taking
///   one;
/// * each door's callback name is read out of the wiring that hands it the
///   entry, so the control-side check names nothing of its own.
///
/// A rename therefore moves the guard with it, and a SECOND entry function —
/// the regression property 1 exists for — makes the derivation ambiguous and
/// the scan fail rather than pick one.
///
/// ## The negative checks have a positive one beside them
///
/// CLAUDE.md, "Guards that name what they watch": `noDoorStartsTheDiagnosis
/// OnAppear` and `thePanelStartsNoRunOnAppear` are negative, and either would
/// pass over a file that had lost the call entirely. They are paired with
/// `theRunEntryIsReachableFromAButton` and `everyDoorOffersAControl`, which
/// assert the calls ARE there — so "nothing starts a run on appear" can never
/// be satisfied by "nothing starts a run".
///
/// ## What it reads
///
/// The `SwiftSource` strict view (comments AND string literals blanked) for
/// every structural claim, so a doc comment describing a call cannot satisfy
/// one; the comments-only view where the claim is about a catalogue key.
@Suite("Diagnostics doors")
struct DiagnosticsDoorsGuardTests {
    /// `#filePath` is
    /// `<repoRoot>/Tests/macSCPAppKitTests/DiagnosticsDoorsGuardTests.swift`.
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    /// The one seed. Everything else this suite names is read out of the tree.
    private static let viewModelPath = "Sources/MacSCPAppKit/Presentation/DiagnosticsViewModel.swift"
    private static let panelPath = "Sources/MacSCPAppKit/DiagnosticsPanel.swift"

    private static let detailPath = "Sources/MacSCPAppKit/ContentView+Detail.swift"

    /// A brace-balanced or paren-balanced region of one file, opened by an
    /// anchor that is already in that file for its own reasons.
    struct Span {
        let file: String
        let anchor: String
        /// Which occurrence of `anchor` opens the region (1-based). A count
        /// that no longer matches fails the scan rather than reading some
        /// other region of the same shape.
        var occurrence: Int = 1
        /// `.body` takes the trailing closure that follows the anchor (`{ … }`
        /// after any parenthesised arguments); `.arguments` takes the
        /// parenthesised argument list the anchor opens.
        var kind: Kind = .body

        enum Kind { case body, arguments }
    }

    /// One door: where the entry is CALLED, and where the user-facing control
    /// that reaches it lives. `control` is nil for the toolbar, which presses
    /// the entry directly rather than through a callback.
    struct Door {
        let what: String
        let wiring: Span
        var control: Span?
    }

    private static let doors: [Door] = [
        Door(
            what: "the connected tab's toolbar",
            wiring: Span(file: "Sources/MacSCPAppKit/ContentView+Lifecycle.swift", anchor: ".toolbar")),
        Door(
            what: "the failed-connect surface",
            wiring: Span(file: detailPath, anchor: "ConnectFailureView(", kind: .arguments),
            control: Span(file: detailPath, anchor: "struct ConnectFailureView")),
        Door(
            what: "the session row's context menu",
            wiring: Span(file: detailPath, anchor: "SessionSidebar(", kind: .arguments),
            control: Span(
                file: "Sources/MacSCPAppKit/SessionSidebar.swift", anchor: ".contextMenu",
                occurrence: 4)),
        Door(
            what: "the connect-error dialog",
            wiring: Span(file: detailPath, anchor: "ConnectionFormView(", kind: .arguments),
            control: Span(file: "Sources/MacSCPAppKit/ConnectionFormView.swift", anchor: ".alert")),
    ]

    // MARK: - The derivations (each fails closed rather than picking one)

    /// The value a door hands the panel: the single `Identifiable` struct the
    /// view model's own file declares.
    static func targetTypeName() throws -> String {
        let source = try strictSource(of: viewModelPath)
        let names = matches(of: #"struct\s+(\w+)\s*:\s*[^\n{]*\bIdentifiable\b"#, in: source)
        guard names.count == 1 else {
            throw ScanError.derivation("""
                \(viewModelPath) must declare exactly ONE Identifiable struct — the value a \
                door hands the panel — found \(names.count): \(names)
                """)
        }
        return names[0]
    }

    /// The window's one entry, and the file it lives in: the single function
    /// in the app target, outside the view model's own file, whose body
    /// constructs the target type.
    static func entrySite() throws -> (file: String, function: String) {
        let target = try targetTypeName()
        var owners: Set<String> = []
        var files: Set<String> = []
        for file in try appTargetFiles() where file != viewModelPath {
            let lines = try strictSource(of: file).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() where line.contains("\(target)(") {
                guard let owner = enclosingFunctionName(in: lines, at: index) else { continue }
                owners.insert(owner)
                files.insert(file)
            }
        }
        guard owners.count == 1, let name = owners.first,
              files.count == 1, let file = files.first
        else {
            throw ScanError.derivation("""
                exactly ONE function outside \(viewModelPath) may build \(target) — that \
                function is the window's single entry onto the panel — found \
                \(owners.count) in \(files.count) files: \(owners.sorted())
                """)
        }
        return (file, name)
    }

    static func entryFunctionName() throws -> String { try entrySite().function }

    /// The view model itself: the type whose body owns the run entry.
    static func viewModelTypeName() throws -> String {
        let lines = try strictSource(of: viewModelPath).components(separatedBy: "\n")
        var owners: Set<String> = []
        for (index, line) in lines.enumerated() where line.contains("Task {") {
            guard let owner = enclosingTypeName(in: lines, at: index) else { continue }
            owners.insert(owner)
        }
        guard owners.count == 1, let name = owners.first else {
            throw ScanError.derivation("""
                exactly ONE type in \(viewModelPath) may start the diagnosis task — found \
                \(owners.count): \(owners.sorted())
                """)
        }
        return name
    }

    /// The presenter's "show this panel" method: the single function in the
    /// view model's file that TAKES a view model. Derived rather than
    /// spelled, so the entry-body check below names nothing of its own.
    static func presenterOpenMethodName() throws -> String {
        let model = try viewModelTypeName()
        let source = collapsingWhitespace(try strictSource(of: viewModelPath))
        let names = matches(of: #"func\s+(\w+)\s*\([^)]*:\s*\#(model)\b"#, in: source)
        guard names.count == 1, let name = names.first else {
            throw ScanError.derivation("""
                exactly ONE function in \(viewModelPath) may take a \(model) — the one that \
                puts a panel on screen — found \(names.count): \(names)
                """)
        }
        return name
    }

    /// The method that STARTS a diagnosis: the single method of the view model
    /// whose body creates the running task.
    static func runEntryName() throws -> String {
        let lines = try strictSource(of: viewModelPath).components(separatedBy: "\n")
        var owners: Set<String> = []
        for (index, line) in lines.enumerated() where line.contains("Task {") || line.contains("Task<") {
            guard let owner = enclosingFunctionName(in: lines, at: index) else { continue }
            owners.insert(owner)
        }
        guard owners.count == 1, let name = owners.first else {
            throw ScanError.derivation("""
                exactly ONE method of the view model may start the diagnosis task — found \
                \(owners.count): \(owners.sorted())
                """)
        }
        return name
    }

    /// The method that STOPS a diagnosis: the single method of the view model
    /// whose body cancels the running task.
    ///
    /// `run()` reaches the same cancellation through `cancel()` rather than
    /// touching `runTask` itself, which is what leaves exactly one owner here
    /// — and is the reason this derivation can be a derivation at all.
    static func cancelEntryName() throws -> String {
        let lines = try strictSource(of: viewModelPath).components(separatedBy: "\n")
        var owners: Set<String> = []
        for (index, line) in lines.enumerated() where line.contains("runTask?.cancel()") {
            guard let owner = enclosingFunctionName(in: lines, at: index) else { continue }
            owners.insert(owner)
        }
        guard owners.count == 1, let name = owners.first else {
            throw ScanError.derivation("""
                exactly ONE method of the view model may cancel the running task — found \
                \(owners.count): \(owners.sorted())
                """)
        }
        return name
    }

    /// The type that turns a step into what the panel draws: the single
    /// `enum` the view model's file declares.
    static func presentationTypeName() throws -> String {
        let source = try strictSource(of: viewModelPath)
        let names = matches(of: #"enum\s+(\w+)"#, in: source)
        guard names.count == 1 else {
            throw ScanError.derivation("""
                \(viewModelPath) must declare exactly ONE enum — the row renderer — found \
                \(names.count): \(names)
                """)
        }
        return names[0]
    }

    /// The argument label a door's wiring hands the entry through — read out
    /// of the wiring itself (`someLabel: { … entry(…) }`), so the check on the
    /// control side spells nothing.
    static func callbackName(of door: Door) throws -> String {
        let entry = try entryFunctionName()
        let wiring = try text(of: door.wiring)
        let labels = matches(
            of: #"(\w+)\s*:\s*\{[^{}]*"# + entry + #"\("#, in: collapsingWhitespace(wiring))
        guard labels.count == 1, let name = labels.first else {
            throw ScanError.derivation("""
                \(door.what): exactly one argument of \(door.wiring.anchor) may carry \
                \(entry)(…) — found \(labels.count): \(labels)
                """)
        }
        return name
    }

    // MARK: - The guards

    @Test func everyDoorCallsTheSameEntry() throws {
        let entry = try Self.entryFunctionName()
        for door in Self.doors {
            let wiring = try Self.text(of: door.wiring)
            #expect(wiring.contains("\(entry)("), """
                \(door.what) must open the diagnostics panel through \(entry)(…) — the one \
                entry every other door uses. Found no call to it inside \
                \(door.wiring.file)'s \(door.wiring.anchor).
                """)
        }
    }

    /// The positive half of "every door is a control": the three doors wired
    /// through a callback actually OFFER that callback to the user, from a
    /// button inside their own surface.
    @Test func everyDoorOffersAControl() throws {
        for door in Self.doors {
            guard let control = door.control else { continue }
            let callback = try Self.callbackName(of: door)
            let span = try Self.text(of: control)
            // Whole invocations, not just trailing closures: this file's
            // buttons are written both ways — `Button(title) { handler() }`
            // and `Button(title, action: handler)` — and a scan that read
            // only the closure form would report the second as absent while
            // it sat right there.
            let calls = Self.invocations(of: "Button", in: span)
                .filter { $0.contains(callback) }
            #expect(calls.count == 1, """
                \(door.what) must offer exactly one Button whose action calls \(callback)(…) \
                — found \(calls.count) inside \(control.file)'s \(control.anchor). A door \
                wired but never drawn is a door nobody can open, and it would leave every \
                negative check in this suite green.
                """)
        }
    }

    /// The positive anchor for the two negative checks below.
    @Test func theRunEntryIsReachableFromAButton() throws {
        let run = try Self.runEntryName()
        let source = try Self.strictSource(of: Self.panelPath)
        let buttons = Self.bodies(after: "Button", in: source)
        let starting = buttons.filter { $0.contains("\(run)()") }
        #expect(!starting.isEmpty, """
            the panel must start the diagnosis from a Button — that is the decision of \
            2026-09-02, and it is also what keeps the two "nothing runs on appear" checks \
            from passing over a panel that runs nothing at all. Found \(buttons.count) \
            button bodies, none calling \(run)().
            """)
    }

    @Test func thePanelStartsNoRunOnAppear() throws {
        let run = try Self.runEntryName()
        let source = try Self.strictSource(of: Self.panelPath)
        for offence in Self.automaticStarts(of: [run], in: source) {
            Issue.record("""
                \(Self.panelPath) starts a diagnosis automatically: \(offence). The \
                diagnosis runs only when the user presses the button (decision of \
                2026-09-02).
                """)
        }
    }

    /// The other half of the lifecycle the UI owns: a panel that goes away
    /// takes its diagnosis with it.
    ///
    /// Without this, closing the sheet leaves the run walking — the remaining
    /// steps under their budgets, and the SSH dial holding Citadel's
    /// uncancellable `openSFTP` timer — authenticating against the user's
    /// server after the user has visibly withdrawn. CLAUDE.md's "the UI owns
    /// lifecycles explicitly … no `deinit` cleanup" is the invariant, and a
    /// free `Task` (which is what the run is) is not touched by a view being
    /// torn down.
    ///
    /// A POSITIVE check: `.onDisappear` must be there and must carry the
    /// cancel entry. The tab's own teardown path is covered by
    /// `DiagnosticsLifecycleTests`, which runs the real function rather than
    /// reading it.
    @Test func thePanelCancelsItsRunWhenItGoesAway() throws {
        let cancel = try Self.cancelEntryName()
        let source = try Self.strictSource(of: Self.panelPath)
        let cancelling = Self.invocations(of: ".onDisappear", in: source)
            .filter { Self.mentions(cancel, in: $0) }
        #expect(cancelling.count == 1, """
            \(Self.panelPath) must carry exactly one .onDisappear calling \(cancel)(…) — \
            found \(cancelling.count). A run that outlives its panel keeps dialling the \
            user's server after the user closed the sheet.
            """)
    }

    /// A door may not open or run the diagnosis from a lifecycle hook.
    ///
    /// The forbidden set is per SPAN, not per suite, and that is what makes it
    /// reach: a control span does not call the entry at all — it calls the
    /// CALLBACK its wiring handed the entry to — so a check that only knew the
    /// entry's name read `.onAppear { onDiagnose() }` on the failed-connect
    /// surface as violation-free. Measured 2026-09-03 by planting exactly
    /// that: the whole suite stayed green, and `scannerSeesTheCallbackFired
    /// FromAnAppear` is the self-test written from it.
    @Test func noDoorStartsTheDiagnosisOnAppear() throws {
        let run = try Self.runEntryName()
        let entry = try Self.entryFunctionName()
        for door in Self.doors {
            var spans: [(Span, [String])] = [(door.wiring, [run, entry])]
            if let control = door.control {
                let callback = try Self.callbackName(of: door)
                spans.append((control, [run, entry, callback]))
            }
            for (span, forbidden) in spans {
                let text = try Self.text(of: span)
                for offence in Self.automaticStarts(of: forbidden, in: text) {
                    Issue.record("""
                        \(door.what) (\(span.file)) opens or runs the diagnosis \
                        automatically: \(offence). A door is a control the user presses, \
                        never a lifecycle hook.
                        """)
                }
            }
        }
    }

    /// The entry itself starts nothing.
    ///
    /// The fifth form, and the one no other check in this suite could see:
    /// `thePanelStartsNoRunOnAppear` reads the panel, and
    /// `noDoorStartsTheDiagnosisOnAppear` reads each door's CALL SITES — never
    /// the entry's own body. Appending `.run()` where the entry presents the
    /// model is a one-liner, and until fix round 2 the whole suite stayed
    /// green over it.
    ///
    /// Not hypothetical: design §4 said for a while that the error dialog's
    /// button "runs it immediately", so "restoring the design" is the exact
    /// edit a reader makes, in exactly this function.
    ///
    /// Positive and negative, as always: the body must still put a panel on
    /// screen (so the check cannot be satisfied by an entry that presents
    /// nothing), and it must not mention the run entry.
    @Test func theEntryOpensThePanelWithoutStartingIt() throws {
        let (file, entry) = try Self.entrySite()
        let run = try Self.runEntryName()
        let show = try Self.presenterOpenMethodName()
        let lines = try Self.strictSource(of: file).components(separatedBy: "\n")
        let body = try Self.functionBody(named: entry, in: lines)

        #expect(body.contains("\(show)("), """
            \(file): \(entry)(…) must still hand the panel to the presenter through \
            \(show)(…) — without that, "it starts no run" is satisfied by an entry that \
            opens nothing.
            """)
        #expect(!Self.mentions(run, in: body), """
            \(file): \(entry)(…) starts the diagnosis itself. Opening the panel is not \
            consent to dial the user's server — the panel's own button is (decision of \
            2026-09-02). Body: \(body)
            """)
    }

    /// Nothing in the panel starts a run except a button.
    ///
    /// Stronger than the modifier list `automaticStarts` walks, and
    /// deliberately so: that list is an enumeration, and the most likely
    /// automatic start in this file is not on it at all — `DiagnosticsPanel`
    /// has a hand-written `init`, and `model.run()` inside it is a modifier of
    /// no kind. This check needs no enumeration: every mention of the run
    /// entry in the whole file has to sit inside a `Button` invocation.
    @Test func thePanelStartsARunOnlyFromAButton() throws {
        let run = try Self.runEntryName()
        let source = try Self.strictSource(of: Self.panelPath)
        let inButtons = Self.invocations(of: "Button", in: source)
            .reduce(0) { $0 + Self.wordCount(of: run, in: $1) }
        let total = Self.wordCount(of: run, in: source)
        #expect(inButtons >= 1, """
            the panel must start the diagnosis from a Button — found no \(run) inside one.
            """)
        #expect(total == inButtons, """
            \(Self.panelPath) mentions \(run) \(total) times but only \(inButtons) of them \
            are inside a Button. Everything else — a lifecycle modifier, the view's own \
            init, a computed property — starts a diagnosis nobody asked for.
            """)
    }

    /// The panel draws no detail line Core wrote without putting it through
    /// the renderer.
    ///
    /// A step's `detail` is mostly measurement — addresses, ports, statuses,
    /// hop rows — copied through byte for byte because it is what somebody
    /// pastes into a bug report. Exactly one thing in it is a sentence about
    /// the CHECK rather than about the network (the trace's "stopped by the
    /// budget" marker), and that one is looked up in the reader's language.
    /// Drawing the raw line skips the lookup, and the marker then prints as
    /// the English Core composed — in every language, with nothing red.
    ///
    /// Measured in fix round 1: reverting the panel's one call to
    /// `Text(step.detail)` left `theTraceBudgetMarkerIsLocalizedInsideThe
    /// DetailLine` green, because that test exercises the RENDERER and the
    /// panel is free not to call it. A negative check ("no `Text` draws a raw
    /// detail") with a positive one beside it ("the renderer is called
    /// exactly once") is what closes the gap.
    ///
    /// Blind spot, stated: a raw detail bound to a local first
    /// (`let d = step.detail; Text(d)`) is invisible to the negative half —
    /// but replacing the rendering that way drops the renderer's one call
    /// site, which the positive half then catches.
    @Test func thePanelRendersTheDetailThroughItsRenderer() throws {
        let renderer = try Self.presentationTypeName()
        let source = try Self.strictSource(of: Self.panelPath)
        // `>= 1`, not `== 1`: the count is of SOURCE call sites, and a second
        // correct one — a summary line, a `.help` tooltip, a collapsed/
        // expanded pair — is a panel doing exactly the right thing. What this
        // half is for is that the renderer is called AT ALL, so the negative
        // half below cannot be satisfied by a panel that draws no detail.
        let calls = Self.occurrences(of: "\(renderer).detail(", in: source)
        #expect(calls >= 1, """
            the panel must render a step's detail through \(renderer).detail(of:) — found \
            \(calls) call sites. Without one, the trace's markers print as the English Core \
            composed, in all four languages.
            """)
        for drawn in Self.invocations(of: "Text", in: source)
        where Self.mentions("detail", in: drawn) {
            #expect(drawn.contains("\(renderer).detail("), """
                the panel draws a detail line without the renderer: \(drawn)
                """)
        }
    }

    /// "Copy report" is one `Menu` with exactly two entries — plain text and
    /// Markdown (decision of 2026-09-02, second half).
    @Test func copyReportIsAMenuWithTwoEntries() throws {
        let source = try Self.strictSource(of: Self.panelPath)
        let menus = Self.bodies(after: "Menu", in: source)
        #expect(menus.count == 1, """
            the panel must carry exactly one Menu — the copy menu — found \(menus.count).
            """)
        guard let menu = menus.first else { return }
        let entries = Self.occurrences(of: "Button(", in: menu)
        #expect(entries == 2, """
            "Copy report" is a Menu with exactly two entries, plain text and Markdown \
            (decision of 2026-09-02) — found \(entries) buttons in it.
            """)
        let copyMethods = Self.matches(of: #"\.(\w+)\(\)"#, in: menu)
        #expect(Set(copyMethods).count == 2, """
            the two entries must call two DIFFERENT methods — found \
            \(Set(copyMethods).sorted()). One entry calling the other's method is exactly \
            the regression a count of buttons alone cannot see.
            """)
    }

    /// The catalogue-key half, read on the comments-only view so the literals
    /// survive: every key the panel, the view model and the doors' controls
    /// look up exists in all four App catalogs, and every fixed reason Core
    /// emits has one. A key present in `en` alone renders as English in the
    /// other three without anything going red.
    @Test func everyKeyTheDoorsAndThePanelUseExistsInAllFourCatalogs() throws {
        var keys: Set<String> = []
        for path in [Self.panelPath, Self.viewModelPath] {
            keys.formUnion(Self.lookedUpKeys(in: try Self.literalSource(of: path)))
        }
        // BOTH spans of every door, not just the control. Measured in fix
        // round 1: the toolbar door has no control span — it presses the
        // entry directly — so `diagnostics.menuHelp`, which is looked up
        // nowhere else, was checked by nothing. Deleting it from all four
        // catalogs left this suite and `LocalizableStringsTests` (which only
        // compares the other three languages against `en`) green, and the
        // tooltip would have fallen back to its English literal in every
        // language without a red.
        for door in Self.doors {
            for span in [door.wiring, door.control].compactMap({ $0 }) {
                keys.formUnion(Self.lookedUpKeys(in: try Self.text(of: span, view: .literals)))
            }
        }
        // The row titles and the fixed reasons are named in CORE, and reach
        // the panel as data rather than as a literal a scan of the panel
        // could see. Read there, so a key Core starts emitting is a key the
        // catalogs must carry — the alternative is a row that silently draws
        // its own key text in three of the four languages.
        keys.formUnion(try Self.coreDiagnosticsKeys())
        let ours = keys.filter { $0.hasPrefix("diagnostics.") }
        #expect(!ours.isEmpty, """
            the panel must look up its rows through diagnostics.* keys — found none, which \
            means this check is reading the wrong file or the panel hardcodes its text.
            """)
        for locale in ["en", "de", "fr", "pl"] {
            let catalog = try String(
                contentsOf: Self.url(
                    "Sources/MacSCPAppKit/Resources/\(locale).lproj/Localizable.strings"),
                encoding: .utf8)
            for key in keys.sorted() {
                #expect(catalog.contains("\"\(key)\""), """
                    \(locale).lproj/Localizable.strings is missing "\(key)", which the panel \
                    or a door looks up.
                    """)
            }
        }
    }

    // MARK: - The scanner reacts (self-tests over synthetic sources)

    @Test func scannerSeesARunStartedOnAppear() {
        let source = """
            struct Panel: View {
                var body: some View {
                    List { }
                    .onAppear { viewModel.run() }
                }
            }
            """
        let bodies = Self.bodies(after: ".onAppear", in: source)
        #expect(bodies.count == 1)
        #expect(bodies[0].contains("run("), """
            the scanner must see the planted violation — without this, the two negative \
            checks above are checks that cannot fail.
            """)
    }

    /// Every spelling of an automatic start must be visible to the scanner —
    /// one synthetic body per form, read by the same function the real checks
    /// use.
    ///
    /// Three of these six were invisible until fix round 1: both
    /// `perform:` spellings, and `.onChange`, which was not on the round-0
    /// list at all (`appearModifiers = [".onAppear", ".task"]`). The report's
    /// mutation table said four plants went green; that comment said two, and
    /// two was the number that was wrong. `.onReceive` was added in round 2.
    @Test func scannerSeesEveryFormOfAnAutomaticStart() {
        let forms: [(String, String)] = [
            (".onAppear trailing closure", ".onAppear { model.run() }"),
            (".onAppear(perform:) as a value", ".onAppear(perform: model.run)"),
            (".onAppear(perform:) as a closure", ".onAppear(perform: { model.run() })"),
            (".task trailing closure", ".task { model.run() }"),
            (".onChange trailing closure", ".onChange(of: endpoint) { _, _ in model.run() }"),
            (".onReceive trailing closure", ".onReceive(timer) { _ in model.run() }"),
        ]
        for (what, source) in forms {
            let offences = Self.automaticStarts(of: ["run"], in: source)
            #expect(offences.count == 1, """
                the scanner must see \(what) — without it, that spelling plants the \
                behaviour with the suite green. Got \(offences) for: \(source)
                """)
        }
    }

    /// The other side of the same claim: an ordinary lifecycle hook that
    /// starts nothing must not be reported, or the checks above would be
    /// unfalsifiable in the other direction.
    @Test func scannerAcceptsLifecycleHooksThatStartNothing() {
        let innocent = [
            ".onAppear { isFocused = true }",
            ".onAppear(perform: focus)",
            ".task { await store.reload() }",
            ".onChange(of: model.isRunning) { _, _ in announce() }",
            ".onDisappear { model.cancel() }",
        ]
        for source in innocent {
            #expect(Self.automaticStarts(of: ["run"], in: source).isEmpty, """
                `\(source)` starts no diagnosis and must not be reported — note the fourth, \
                which contains "Running" and would trip a substring test.
                """)
        }
    }

    /// The hole a fresh planting found: a control fires its CALLBACK from an
    /// appear, and the callback's name is nowhere in the entry's or the run
    /// entry's spelling. The scan must see the callback too.
    @Test func scannerSeesTheCallbackFiredFromAnAppear() {
        let source = """
            Button(title, action: onDiagnose)
                .onAppear { onDiagnose() }
            """
        let bodies = Self.bodies(after: ".onAppear", in: source)
        #expect(bodies.count == 1)
        #expect(bodies[0].contains("onDiagnose("))
    }

    @Test func scannerAcceptsAnAppearThatStartsNothing() {
        let source = """
            struct Panel: View {
                var body: some View {
                    List { }
                    .onAppear { isFocused = true }
                }
            }
            """
        #expect(Self.bodies(after: ".onAppear", in: source)[0].contains("run(") == false)
    }

    @Test func scannerCountsAMenusEntries() {
        let two = """
            Menu(title) {
                Button(a) { model.copyPlainText() }
                Button(b) { model.copyMarkdown() }
            }
            """
        let one = """
            Menu(title) {
                Button(a) { model.copyPlainText() }
            }
            """
        #expect(Self.occurrences(of: "Button(", in: Self.bodies(after: "Menu", in: two)[0]) == 2)
        #expect(Self.occurrences(of: "Button(", in: Self.bodies(after: "Menu", in: one)[0]) == 1)
    }

    /// The trailing closure of a call whose ARGUMENTS carry closures of their
    /// own — the `.alert(title, isPresented: Binding(get: { … }, set: { … })) { … }`
    /// shape the connect-error dialog is written in. A scan that took the
    /// first `{` after the anchor would read the binding's getter and report
    /// the dialog's buttons as absent.
    @Test func scannerSkipsClosuresInsideAnArgumentList() {
        let source = """
            .alert(title, isPresented: Binding(get: { a != nil }, set: { b = $0 })) {
                Button(ok) { onDiagnose() }
            }
            """
        let bodies = Self.bodies(after: ".alert", in: source)
        #expect(bodies.count == 1)
        #expect(bodies[0].contains("onDiagnose()"), """
            the trailing closure is the dialog's buttons, not the binding's getter — got \
            \(bodies)
            """)
    }

    @Test func scannerReadsAnArgumentListRatherThanItsFirstClosure() throws {
        let source = """
            SomeView(
                a: { first() },
                b: { second() })
            """
        let span = try Self.argumentSpan(after: "SomeView(", in: source, occurrence: 1)
        #expect(span.contains("first()") && span.contains("second()"), """
            an .arguments span must cover the whole call — got \(span)
            """)
    }

    /// Both button spellings must read as one invocation each — the closure
    /// form and the `action:` form. Written before the real check needed it:
    /// the failed-connect surface uses `action:` for every one of its
    /// controls, and a scan that only knew the closure form reported its
    /// diagnose control as missing while it was there.
    @Test func scannerReadsBothButtonSpellings() {
        let source = """
            Button(title) { onDiagnose() }
            Button(other, action: onDiagnose)
            Button(unrelated, action: onClose)
            """
        let carrying = Self.invocations(of: "Button", in: source)
            .filter { $0.contains("onDiagnose") }
        #expect(carrying.count == 2, "got \(Self.invocations(of: "Button", in: source))")
    }

    @Test func scannerComposesAnInterpolatedKeyFromItsTwoHalves() {
        let source = """
            enum StepID {
                static let resolve = "resolve"
                static let tcp = "tcp"
                static func titleKey(for id: String) -> String { "diagnostics.step.\\(id)" }
            }
            """
        #expect(Self.interpolatedStepKeys(in: source)
            == ["diagnostics.step.resolve", "diagnostics.step.tcp"])
    }

    @Test func scannerComposesNothingWhereNoKeyIsInterpolated() {
        let source = """
            enum Elsewhere {
                static let resolve = "resolve"
            }
            """
        #expect(Self.interpolatedStepKeys(in: source).isEmpty)
    }

    @Test func scannerReadsTheEnclosingTypeName() {
        let lines = """
            @MainActor
            final class Model {
                func run() {
                    runTask = Task {
                        await work()
                    }
                }
            }
            """.components(separatedBy: "\n")
        #expect(Self.enclosingTypeName(in: lines, at: 3) == "Model")
        #expect(Self.enclosingFunctionName(in: lines, at: 3) == "run")
    }

    @Test func scannerReadsAFunctionsWholeBody() throws {
        let lines = """
            extension ContentView {
                func showDiagnostics(for source: Source) {
                    let target = Target(kind: source.kind)
                    diagnostics.present(Model(target: target), for: nil)
                }

                func endDiagnostics() {
                    diagnostics.end()
                }
            }
            """.components(separatedBy: "\n")
        let body = try Self.functionBody(named: "showDiagnostics", in: lines)
        #expect(body.contains("present("))
        #expect(!body.contains("end()"), """
            the span must stop at the function's own closing brace, or a neighbouring \
            function's body would satisfy — or violate — a check about this one
            """)
    }

    @Test func scannerCountsWholeIdentifiersOnly() {
        #expect(Self.wordCount(of: "run", in: "model.run(); model.run()") == 2)
        #expect(Self.wordCount(of: "run", in: "isRunning; rerun(); runner") == 0)
    }

    @Test func scannerReadsTheEnclosingFunctionName() {
        let lines = """
            extension ContentView {
                func showDiagnostics(for tab: SessionTab) {
                    request = Whatever(kind: tab.kind)
                }
            }
            """.components(separatedBy: "\n")
        #expect(Self.enclosingFunctionName(in: lines, at: 2) == "showDiagnostics")
    }

    /// Fail-closed: an anchor that is not in the file must throw, not hand
    /// back an empty string that every `contains` check then reports as a
    /// violation-free span.
    @Test func scannerFailsClosedOnAMissingAnchor() {
        let span = Span(file: "Package.swift", anchor: "ZZ-NOT-PRESENT-ZZ")
        #expect(throws: (any Error).self) { try Self.text(of: span) }
    }

    /// The same fail-closed rule for a count that has gone stale: the file has
    /// the anchor, but not that many times.
    @Test func scannerFailsClosedOnAnOccurrenceThatIsNotThere() {
        let span = Span(file: "Package.swift", anchor: "targets", occurrence: 99)
        #expect(throws: (any Error).self) { try Self.text(of: span) }
    }

    /// Two builders must read as two, so `entryFunctionName` refuses rather
    /// than picking one. This is what catches a SECOND entry beside the first
    /// — the regression a per-door `contains` could never see.
    @Test func scannerSeesTwoBuildersAsTwo() {
        let lines = """
            func a() {
                request = Target(x: 1)
            }
            func b() {
                request = Target(x: 2)
            }
            """.components(separatedBy: "\n")
        let owners = Set([1, 4].compactMap { Self.enclosingFunctionName(in: lines, at: $0) })
        #expect(owners == ["a", "b"])
    }

    @Test func scannerReadsACallbackLabelOutOfItsWiring() {
        let wiring = """
            (
                content: plan,
                onDiagnose: { showDiagnostics(for: tab) },
                onClose: { requestClose(tab) })
            """
        let labels = Self.matches(
            of: #"(\w+)\s*:\s*\{[^{}]*showDiagnostics\("#,
            in: Self.collapsingWhitespace(wiring))
        #expect(labels == ["onDiagnose"])
    }

    // MARK: - Scanner

    enum ScanError: Error, CustomStringConvertible {
        case derivation(String)
        case spanNotFound(String)

        var description: String {
            switch self {
            case .derivation(let text), .spanNotFound(let text): return text
            }
        }
    }

    enum SourceView { case strict, literals }

    /// The SwiftUI modifiers this scan knows can fire a closure without
    /// anybody pressing anything. Four, counted here.
    ///
    /// **An enumeration, and it states its own blind spot.** It is not every
    /// such modifier — `.refreshable`, `.onOpenURL` and `.onGeometryChange`
    /// are not on it — and the likeliest automatic start in the panel is not
    /// a modifier at all: `DiagnosticsPanel` has a hand-written `init`, and
    /// `model.run()` inside one is invisible to every list of this shape.
    /// `thePanelStartsARunOnlyFromAButton` is what actually covers the panel,
    /// without enumerating anything; this list is what covers the DOOR spans,
    /// where a whole-file rule cannot apply because those files legitimately
    /// mention the entry elsewhere.
    ///
    /// `.onChange` and `.onReceive` earn their places for the same reason: a
    /// panel wired to re-run when the endpoint changes, or on a timer, is
    /// exactly as automatic as `.onAppear` and reads as a feature while it is
    /// being written.
    private static let automaticModifiers = [".onAppear", ".task", ".onChange", ".onReceive"]

    /// Every automatic-start offence in `source`: an occurrence of one of the
    /// modifiers above whose invocation mentions one of `names`.
    ///
    /// Reads whole INVOCATIONS, not trailing closures. Measured in fix round
    /// 1: the previous scan took the first `{` after the anchor at paren depth
    /// zero, so `.onAppear(perform: model.run)` and
    /// `.onAppear(perform: { model.run() })` — ordinary SwiftUI, and exactly
    /// the violation this suite exists for — were both invisible, and the
    /// suite stayed green over them. `invocations(of:)` covers the argument
    /// list too, which is where both of those live.
    ///
    /// The needle is the bare IDENTIFIER on a word boundary, not `name(`,
    /// for the same measurement: `perform: model.run` passes the method as a
    /// value and never writes a parenthesis.
    static func automaticStarts(of names: [String], in source: String) -> [String] {
        var offences: [String] = []
        for modifier in automaticModifiers {
            for invocation in invocations(of: modifier, in: source) {
                guard let name = names.first(where: { mentions($0, in: invocation) })
                else { continue }
                offences.append("\(modifier) mentioning `\(name)` — \(invocation)")
            }
        }
        return offences
    }

    /// Whether `name` occurs in `source` as a whole identifier. A substring
    /// test would read `isRunning` as `run`, and `\(name)(` would miss the
    /// method-as-a-value spelling.
    static func mentions(_ name: String, in source: String) -> Bool {
        !matches(of: #"\b(\#(name))\b"#, in: source).isEmpty
    }

    static func url(_ relativePath: String) -> URL {
        repoRoot.appendingPathComponent(relativePath)
    }

    static func strictSource(of relativePath: String) throws -> String {
        try SwiftSource.blankingCommentsAndStrings(
            try String(contentsOf: url(relativePath), encoding: .utf8))
    }

    static func literalSource(of relativePath: String) throws -> String {
        try SwiftSource.blankingComments(
            try String(contentsOf: url(relativePath), encoding: .utf8))
    }

    /// Every Swift file of the app target, so the entry derivation looks at
    /// the whole target rather than at a list somebody has to maintain.
    static func appTargetFiles() throws -> [String] {
        let root = url("Sources/MacSCPAppKit")
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        else { return [] }
        let base = repoRoot.standardizedFileURL.path + "/"
        var files: [String] = []
        for case let fileURL as URL in walker where fileURL.pathExtension == "swift" {
            let full = fileURL.standardizedFileURL.path
            files.append(full.hasPrefix(base) ? String(full.dropFirst(base.count)) : full)
        }
        return files.sorted()
    }

    /// The text of a span, in the requested view. The region is FOUND in the
    /// strict view — so a brace inside a comment or a literal cannot move its
    /// end — and sliced out of whichever view the caller asked for, which the
    /// two views' shared character indexing (`SwiftSource`'s length
    /// preservation) makes exact.
    static func text(of span: Span, view: SourceView = .strict) throws -> String {
        let raw = try String(contentsOf: url(span.file), encoding: .utf8)
        let strict = try SwiftSource.blankingCommentsAndStrings(raw)
        let region: Range<Int>
        switch span.kind {
        case .body:
            region = try bodyRange(after: span.anchor, in: strict, occurrence: span.occurrence)
        case .arguments:
            region = try argumentRange(after: span.anchor, in: strict, occurrence: span.occurrence)
        }
        let source = view == .strict ? strict : try SwiftSource.blankingComments(raw)
        return String(Array(source)[region])
    }

    /// The index just past the `occurrence`-th occurrence of `anchor`, or nil.
    private static func offset(
        after anchor: String, in source: String, occurrence: Int
    ) -> Int? {
        var searchFrom = source.startIndex
        var found: String.Index?
        for _ in 0..<max(1, occurrence) {
            guard let hit = source.range(of: anchor, range: searchFrom..<source.endIndex)
            else { return nil }
            found = hit.upperBound
            searchFrom = hit.upperBound
        }
        guard let found else { return nil }
        return source.distance(from: source.startIndex, to: found)
    }

    private static func bodyRange(
        after anchor: String, in source: String, occurrence: Int
    ) throws -> Range<Int> {
        guard let start = offset(after: anchor, in: source, occurrence: occurrence),
              let range = braceBody(in: Array(source), from: start)
        else {
            throw ScanError.spanNotFound("""
                \(anchor) #\(occurrence) opens no brace-balanced body — the region this scan \
                reads cannot be located, so it reports nothing rather than an all-clear.
                """)
        }
        return range
    }

    private static func argumentRange(
        after anchor: String, in source: String, occurrence: Int
    ) throws -> Range<Int> {
        guard let start = offset(after: anchor, in: source, occurrence: occurrence) else {
            throw ScanError.spanNotFound("\(anchor) #\(occurrence) is not in this file")
        }
        let chars = Array(source)
        var depth = 1
        var index = start
        while index < chars.count {
            if chars[index] == "(" { depth += 1 }
            if chars[index] == ")" {
                depth -= 1
                if depth == 0 { return start..<index }
            }
            index += 1
        }
        throw ScanError.spanNotFound("\(anchor) #\(occurrence) opens no balanced argument list")
    }

    /// Test-visible wrapper so the scanner's own self-tests can exercise the
    /// argument scan without a file on disk.
    static func argumentSpan(after anchor: String, in source: String, occurrence: Int) throws -> String {
        String(Array(source)[try argumentRange(after: anchor, in: source, occurrence: occurrence)])
    }

    /// The brace-balanced closure that follows position `start`, skipping any
    /// parenthesised arguments in between — so `Button(label) { … }` and
    /// `.alert(a, b: B(get: { … })) { … }` both land on the trailing closure
    /// rather than on a closure written inside the argument list.
    private static func braceBody(in chars: [Character], from start: Int) -> Range<Int>? {
        var cursor = start
        var parens = 0
        var opened: Int?
        scan: while cursor < chars.count {
            switch chars[cursor] {
            case "(": parens += 1
            case ")": parens -= 1
            case "{" where parens == 0:
                opened = cursor
                break scan
            case "\n" where parens == 0:
                break scan
            default: break
            }
            cursor += 1
        }
        guard let opened else { return nil }
        var depth = 0
        for position in opened..<chars.count {
            if chars[position] == "{" { depth += 1 }
            if chars[position] == "}" { depth -= 1 }
            if depth == 0 { return opened..<(position + 1) }
        }
        return nil
    }

    /// Every brace-balanced body that follows an occurrence of `keyword`.
    static func bodies(after keyword: String, in source: String) -> [String] {
        let chars = Array(source)
        let needle = Array(keyword)
        var results: [String] = []
        var index = 0
        while index + needle.count <= chars.count {
            guard Array(chars[index..<(index + needle.count)]) == needle else {
                index += 1
                continue
            }
            guard let range = braceBody(in: chars, from: index + needle.count) else {
                index += needle.count
                continue
            }
            results.append(String(chars[range]))
            index = range.upperBound
        }
        return results
    }

    /// Every whole invocation of `keyword` in `source`: the keyword, its
    /// parenthesised arguments if it has any, and its trailing closure if it
    /// has one. What a control DOES can live in either half — `action:` is an
    /// argument, a handler written as a trailing closure is not — so a check
    /// about a control has to read both.
    static func invocations(of keyword: String, in source: String) -> [String] {
        let chars = Array(source)
        let needle = Array(keyword)
        var results: [String] = []
        var index = 0
        while index + needle.count <= chars.count {
            guard Array(chars[index..<(index + needle.count)]) == needle else {
                index += 1
                continue
            }
            var cursor = index + needle.count
            while cursor < chars.count, chars[cursor] == " " { cursor += 1 }
            if cursor < chars.count, chars[cursor] == "(" {
                var depth = 0
                while cursor < chars.count {
                    if chars[cursor] == "(" { depth += 1 }
                    if chars[cursor] == ")" {
                        depth -= 1
                        if depth == 0 { cursor += 1; break }
                    }
                    cursor += 1
                }
            }
            if let body = braceBody(in: chars, from: cursor) {
                cursor = body.upperBound
            }
            guard cursor > index + needle.count else {
                index += needle.count
                continue
            }
            results.append(String(chars[index..<cursor]))
            index = cursor
        }
        return results
    }

    /// The name of the type whose body contains line `index` — the same
    /// backwards brace walk as `enclosingFunctionName`, stopping at a type
    /// declaration instead of a function.
    static func enclosingTypeName(in lines: [String], at index: Int) -> String? {
        let pattern = #"(?:final\s+)?(?:class|struct|actor|enum|extension)\s+(\w+)"#
        var depth = 0
        var line = index
        while line >= 0 {
            if line != index {
                for character in lines[line].reversed() {
                    if character == "}" { depth += 1 }
                    if character == "{" { depth -= 1 }
                }
            }
            if depth < 0 {
                if let name = matches(of: pattern, in: lines[line]).first { return name }
                depth = 0
            }
            line -= 1
        }
        return nil
    }

    /// The name of the `func` whose body contains line `index`.
    static func enclosingFunctionName(in lines: [String], at index: Int) -> String? {
        // A body written on its own declaration's line owns itself. Checked
        // first because the backwards walk below deliberately does not count
        // the braces of the starting line.
        if let sameLine = matches(of: #"func\s+(\w+)"#, in: lines[index]).first { return sameLine }
        var depth = 0
        var line = index - 1
        while line >= 0 {
            for character in lines[line].reversed() {
                if character == "}" { depth += 1 }
                if character == "{" { depth -= 1 }
            }
            if depth < 0 {
                if let name = matches(of: #"func\s+(\w+)"#, in: lines[line]).first { return name }
                depth = 0
            }
            line -= 1
        }
        return nil
    }

    /// How many times `name` occurs in `source` as a whole identifier.
    static func wordCount(of name: String, in source: String) -> Int {
        matches(of: #"\b(\#(name))\b"#, in: source).count
    }

    /// The brace-balanced body of the named function.
    static func functionBody(named name: String, in lines: [String]) throws -> String {
        guard let start = lines.firstIndex(where: {
            !matches(of: #"func\s+(\w+)"#, in: $0).filter { $0 == name }.isEmpty
        }) else {
            throw ScanError.spanNotFound("no `func \(name)` in this file")
        }
        let source = lines[start...].joined(separator: "\n")
        guard let body = bodies(after: "func \(name)", in: source).first else {
            throw ScanError.spanNotFound("`func \(name)` opens no brace-balanced body")
        }
        return body
    }

    static func occurrences(of substring: String, in source: String) -> Int {
        source.components(separatedBy: substring).count - 1
    }

    /// Every `diagnostics.*` catalogue key Core's diagnostics module writes
    /// into a step — the row titles and the fixed reasons. Found by reading
    /// the directory, not by listing files, so a new probe's key is covered
    /// the moment it is written.
    static func coreDiagnosticsKeys() throws -> Set<String> {
        let root = url("Sources/macSCPCore/Diagnostics")
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        else { throw ScanError.spanNotFound("Sources/macSCPCore/Diagnostics is not readable") }
        var keys: Set<String> = []
        var files = 0
        for case let fileURL as URL in walker where fileURL.pathExtension == "swift" {
            files += 1
            let source = try SwiftSource.blankingComments(
                try String(contentsOf: fileURL, encoding: .utf8))
            keys.formUnion(matches(of: #""(diagnostics\.[A-Za-z0-9._]+)""#, in: source))
            keys.formUnion(interpolatedStepKeys(in: source))
        }
        guard files > 0 else {
            throw ScanError.spanNotFound("Sources/macSCPCore/Diagnostics holds no Swift files")
        }
        return keys
    }

    /// The keys Core does not spell: `"diagnostics.step.\(id)"` composes a
    /// prefix with a step id, and neither half is a whole key a literal scan
    /// can see.
    ///
    /// Measured 2026-09-03: dropping `diagnostics.step.trace` from the Polish
    /// catalog left the whole suite green, because a literal scan reads
    /// `diagnostics.step.sshConnect` (spelled in `DialProbes`) and nothing at
    /// all for the five ids the runner composes. Both halves are read here
    /// instead — the prefix out of the interpolation itself, the ids out of
    /// the same declaration that carries it, so a renamed prefix or a sixth id
    /// moves the check with it.
    static func interpolatedStepKeys(in source: String) -> Set<String> {
        var keys: Set<String> = []
        for name in matches(of: #"enum\s+(\w+)"#, in: source) {
            for body in bodies(after: "enum \(name)", in: source) {
                let prefixes = matches(of: #""(diagnostics\.[A-Za-z0-9._]*)\\\("#, in: body)
                guard !prefixes.isEmpty else { continue }
                let ids = matches(of: #"static let \w+ = "([A-Za-z0-9_]+)""#, in: body)
                for prefix in prefixes {
                    for id in ids { keys.insert(prefix + id) }
                }
            }
        }
        return keys
    }

    /// Catalogue keys looked up through the App's helper, on a view where
    /// literals survive.
    static func lookedUpKeys(in source: String) -> Set<String> {
        Set(matches(of: #"L10n\.(?:string|text)\(\s*"([^"]+)""#, in: collapsingWhitespace(source)))
    }

    /// Newlines folded to spaces, so a regex written for one line still reads
    /// a call the formatter wrapped across three.
    static func collapsingWhitespace(_ source: String) -> String {
        source.replacingOccurrences(of: "\n", with: " ")
    }

    /// First capture group of every match, in source order.
    static func matches(of pattern: String, in source: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return regex.matches(in: source, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let captured = Range(match.range(at: 1), in: source)
            else { return nil }
            return String(source[captured])
        }
    }
}
