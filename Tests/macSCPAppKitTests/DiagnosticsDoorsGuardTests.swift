import Foundation
import Testing

/// Guards the three doors onto the diagnostics panel, and the two rules the
/// panel itself was decided under (design §1/§4, decisions of 2026-09-02).
///
/// Four properties, in the order they matter:
///
/// 1. **One entry.** Every door reaches the panel through the SAME function on
///    the window. Four surfaces offer "Diagnose…" — the toolbar of a connected
///    tab, the failed-connect surface, the session context menu and the
///    connect-error dialog — and a second entry beside the first is how one of
///    them quietly stops carrying a rule the others do (the secret source, the
///    session id the dial resolves under, the app version in the report).
/// 2. **Every door is a control the user presses.** The maintainer decided on
///    2026-09-02 that the diagnosis runs when the user asks for it, never
///    automatically after a failed connect. The shape that breaks that is an
///    `.onAppear` (or `.task`) whose body opens or runs the diagnosis — at a
///    door, or in the panel — and it is the violation this suite is written
///    against.
/// 3. **"Copy report" is a menu with two entries**, plain text and Markdown,
///    the second half of the same decision.
/// 4. **The panel starts no run of its own on appear**, stated separately from
///    2 because the panel is where an appear-time run would be written most
///    naturally.
///
/// ## Nothing here spells a symbol it could read
///
/// The seed is one FILE PATH — the view model's — and the rest is derived from
/// the tree:
///
/// * the target type is the single `Identifiable` struct that file declares;
/// * the window's entry function is the single function, anywhere else in the
///   app target, that CONSTRUCTS that type;
/// * the run entry is the single method of the view model that starts a task;
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

    /// The window's one entry: the single function in the app target, outside
    /// the view model's own file, whose body constructs the target type.
    static func entryFunctionName() throws -> String {
        let target = try targetTypeName()
        var owners: Set<String> = []
        for file in try appTargetFiles() where file != viewModelPath {
            let lines = try strictSource(of: file).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() where line.contains("\(target)(") {
                guard let owner = enclosingFunctionName(in: lines, at: index) else { continue }
                owners.insert(owner)
            }
        }
        guard owners.count == 1, let name = owners.first else {
            throw ScanError.derivation("""
                exactly ONE function outside \(viewModelPath) may build \(target) — that \
                function is the window's single entry onto the panel — found \
                \(owners.count): \(owners.sorted())
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
        for keyword in Self.appearModifiers {
            for body in Self.bodies(after: keyword, in: source) {
                #expect(!body.contains("\(run)("), """
                    \(Self.panelPath) starts a diagnosis from \(keyword) — the diagnosis runs \
                    only when the user presses the button (decision of 2026-09-02). \
                    Offending body: \(body)
                    """)
            }
        }
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
            var spans: [(Span, [String])] = [(door.wiring, ["\(run)(", "\(entry)("])]
            if let control = door.control {
                let callback = try Self.callbackName(of: door)
                spans.append((control, ["\(run)(", "\(entry)(", "\(callback)("]))
            }
            for (span, forbidden) in spans {
                let text = try Self.text(of: span)
                for keyword in Self.appearModifiers {
                    for body in Self.bodies(after: keyword, in: text) {
                        let hit = forbidden.first { body.contains($0) }
                        #expect(hit == nil, """
                            \(door.what) (\(span.file)) opens or runs the diagnosis from \
                            \(keyword), through \(hit ?? ""). A door is a control the user \
                            presses, never a lifecycle hook. Offending body: \(body)
                            """)
                    }
                }
            }
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
        for door in Self.doors {
            guard let control = door.control else { continue }
            keys.formUnion(Self.lookedUpKeys(in: try Self.text(of: control, view: .literals)))
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

    private static let appearModifiers = [".onAppear", ".task"]

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
