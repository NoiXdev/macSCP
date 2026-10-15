import Foundation
import MacSCPTestSupport
import Testing

/// The source-level half of the diff view's entry points (Task 12).
/// `BrowserContextMenuTests` holds WHICH selection is offered which entry;
/// this holds what no value test can reach: that both panes actually handle
/// the two entries, that the menu bar has its own door, that every one of
/// them goes through the single function which starts a comparison and opens
/// the window for THAT comparison, and that a refused start opens nothing.
///
/// Every negative check has a positive one beside it asserting the thing it
/// scans is there at all.
@Suite("Comparison entry wiring guard")
struct ComparisonEntryWiringGuardTests {
    private static let sources = SourceCorpus.url(of: .sources)
    private static let appKit = sources.appendingPathComponent("MacSCPAppKit")
    private static let doorFile = "ContentView+Comparison.swift"
    private static let comparisonFile = "Comparison.swift"
    /// Where the one menu-action switch lives. Its own file, for the reason
    /// that file's own doc comment gives: beside the `transferSelection` it
    /// routes to, it broke a bound `ToolbarTransferConfirmationGuardTests`
    /// holds over `ContentView+Transfers.swift`.
    private static let routerFile = "ContentView+MenuActions.swift"

    /// Code only: comments and string literals blanked, whitespace collapsed
    /// so a rewrap cannot move an anchor.
    private static func code(_ file: String) throws -> String {
        let view = try SourceCorpus.code(of: appKit.appendingPathComponent(file))
        return collapsed(view)
    }

    /// Comments blanked, literals KEPT — for a claim about a catalogue key,
    /// which is a claim about a literal. A comment naming the key still
    /// cannot satisfy it.
    private static func withLiterals(_ file: String) throws -> String {
        collapsed(try SourceCorpus.commentFree(of: appKit.appendingPathComponent(file)))
    }

    private static func collapsed(_ source: String) -> String {
        source.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .replacingOccurrences(of: "( ", with: "(")
            .replacingOccurrences(of: " )", with: ")")
    }

    /// A declaration's own body, by brace matching, read from code alone and
    /// then collapsed — so a statement or a comment added to it cannot push a
    /// call out of a fixed-length window.
    private static func body(_ declaration: String, in file: String) throws -> String {
        let source = try SourceCorpus.code(of: appKit.appendingPathComponent(file))
        return collapsed(
            try TransferQueueBarCancelGuardTests.declarationBody(of: declaration, in: source))
    }

    private static func occurrences(of needle: String, in code: String) -> Int {
        code.components(separatedBy: needle).count - 1
    }

    private static func swiftFiles() throws -> [URL] {
        try SourceCorpus.files(under: sources).filter { $0.pathExtension == "swift" }
    }

    // MARK: The two context-menu entries

    /// Both entries reach a handler in BOTH panes' `onMenuAction`. The
    /// switches there are exhaustive, so a missing arm is a build failure —
    /// but an arm that falls through to `break` is not, and that is what this
    /// catches: the entry would be offered and clicking it would do nothing.
    /// Both entries reach a handler, and NEITHER PANE SPELLS ITS SIDE at the
    /// menu call at all (fix round 3, N1).
    ///
    /// Round 2 anchored each arm together with its own body, which killed the
    /// within-pane body swap. One layer out it was still open: give the LOCAL
    /// switch the `.remote` arms and the REMOTE switch the `.local` arms and
    /// every anchor is still present exactly once, because the guard reads
    /// the file as one string — the reviewer's probe P1, green scoped AND
    /// against the whole AppKit target. Both doors of both panes wrong,
    /// silently, from one copy-paste between two mirrored blocks.
    ///
    /// The fix is structural and goes one step further than a per-region
    /// scan: there is now ONE switch, in `ContentView+MenuActions.swift`
    /// (this sentence named `ContentView+Transfers.swift` until fix round 4 —
    /// the one file the router could NOT live in, for the reason
    /// `routerFile` above and that file's own doc comment give), and
    /// the side is not an argument either call site writes — `BrowserPane`
    /// hands it to `onMenuAction`, off the `side` it was already constructed
    /// with and already uses for the menu model and the key commands. So the
    /// two closures are textually identical, there is no second spelling of a
    /// side to permute, and the swap P1 plants cannot be written.
    @Test func bothPanesHandleBothEntriesAndNeitherSpellsItsSide() throws {
        let detail = try Self.code("ContentView+Detail.swift")
        // Positive: both panes still route their menu somewhere.
        let call = "onMenuAction: { entry, selection, side in "
            + "handleBrowserMenuEntry(entry, selection: selection, side: side, "
            + "in: tab, session: session) },"
        #expect(Self.occurrences(of: call, in: detail) == 2, "\(call)")
        #expect(Self.occurrences(of: "handleBrowserMenuEntry(", in: detail) == 2)
        // Negative, with the count above beside it: the switch is gone from
        // this file, so there is no per-pane arm left to give to the wrong
        // pane.
        for arm in [
            "case .compareWithOtherPane", "case .compareTwoSelected",
            "case .transferToOtherPane", "case .copyPath",
        ] {
            #expect(!detail.contains(arm), "a pane still switches on \(arm)")
        }

        // The one switch, each arm anchored together with its own body: a
        // body swap WITHIN it is still a permutation, and still caught.
        let router = try Self.body("func handleBrowserMenuEntry(", in: Self.routerFile)
        for (arm, body) in [
            ("case .compareWithOtherPane:",
             "compareWithOtherPane(selection, from: side, in: tab, session: session)"),
            ("case .compareTwoSelected:",
             "compareTwoSelected(selection, on: side, in: tab)"),
        ] {
            #expect(Self.occurrences(of: "\(arm) \(body)", in: router) == 1, "\(arm)")
        }
        #expect(Self.occurrences(of: "case .compareWithOtherPane: compareTwoSelected", in: router) == 0)
        #expect(Self.occurrences(of: "case .compareTwoSelected: compareWithOtherPane", in: router) == 0)

        // And the side the router hands on is the one it was given, never a
        // literal: a literal here would be the same defect one level in.
        for literal in ["from: .local", "from: .remote", "on: .local", "on: .remote"] {
            #expect(!router.contains(literal), "the router spells \(literal)")
        }

        // The two arms that are about ONE pane carry a `side ==` gate, and
        // what is pinned is its POLARITY, not its presence (fix round 4,
        // item 1). Inverting either one is a real break of an existing
        // feature — the remote pane's "Open", or its presigned URL — and
        // before the router it was pinned by nothing at all: the behaviour
        // was encoded by which of the two closures the arm sat in, which is
        // exactly what the swap above proved unpinned. Protection was zero
        // and is now two anchors; what the refactor bought is that there is
        // one spelling to anchor instead of two closures to bracket.
        //
        // Read with literals kept, because the second anchor is a claim
        // ABOUT a literal (`action.id`'s value), which the code-only view
        // blanks.
        let withLiterals = try Self.withLiterals(Self.routerFile)
        for gate in [
            "case .openInEditor: if side == .remote, let item = selection.first {",
            "if side == .remote, action.id == \"s3.presignedURL\",",
        ] {
            #expect(Self.occurrences(of: gate, in: withLiterals) == 1, "\(gate)")
        }
        // The inverted spellings, which is the whole point of anchoring the
        // polarity: neither may appear.
        for inverted in ["if side == .local,", "if side != .remote,"] {
            #expect(!withLiterals.contains(inverted), "the router gates on \(inverted)")
        }
    }

    /// The side reaches the router from `BrowserPane`, which is the only
    /// place either pane's side is written down.
    @Test func theSideComesFromThePaneRatherThanFromTheCallSite() throws {
        let pane = try Self.code("BrowserPane.swift")
        #expect(pane.contains(
            "var onMenuAction: ((BrowserMenuEntry, [RemoteFileItem], BrowserPaneSide) -> Void)? = nil"))
        #expect(pane.contains("default: onMenuAction?(entry, selection, side)"))
        // Positive beside it: `side` really is the pane's own stored one, so
        // the forward above is not reading something a caller passed twice.
        #expect(pane.contains("let side: BrowserPaneSide"))

        // Each pane writes its side exactly once, in its own construction.
        // Two guards for two unrelated features already split this file by
        // that exact spelling and would both go red if the two were swapped,
        // named here rather than left as an implicit "every other guard"
        // (fix round 4, item 4):
        // `BucketListTransferGuardTests.bothPanesHandTheirTableTheOtherPanesScope`
        // and `FileActionPaneWiringGuardTests.onlyTheRemotePaneIsHandedTheShell`.
        // Measured 2026-10-15 by planting the swap against the whole AppKit
        // target; both are in the catcher list, and this suite's own two
        // `side`-reading cases are not — they read the spelling, not which
        // pane carries it.
        let detail = try Self.code("ContentView+Detail.swift")
        #expect(Self.occurrences(of: "side: .local,", in: detail) == 1)
        #expect(Self.occurrences(of: "side: .remote,", in: detail) == 1)
    }

    /// `BrowserPane` forwards what it does not handle itself, so neither
    /// entry may be swallowed there.
    @Test func theBrowserPaneForwardsTheComparisonEntriesInsteadOfSwallowingThem() throws {
        let pane = try Self.code("BrowserPane.swift")
        // Positive: the forwarding default is there, and the pane does keep
        // other entries to itself.
        #expect(pane.contains("default: onMenuAction?(entry, selection, side)"))
        #expect(pane.contains("case .rename:"))
        // Negative: it claims neither comparison entry.
        #expect(!pane.contains("case .compareWithOtherPane"))
        #expect(!pane.contains("case .compareTwoSelected"))
    }

    /// The tree-wide caller set of `BrowserContextMenu.entries(` (fix round
    /// 3, item 4).
    ///
    /// `destinationRows` is DEFAULTED, and deliberately — house style defaults
    /// exactly this (`supportsArchiving`'s own doc comment gives the same
    /// reasoning), and removing it would force five unrelated call sites to
    /// spell `[]`. The five on the default are latent rather than wrong:
    /// none of them asks about a comparison entry. What a scoped count cannot
    /// see is a SEVENTH caller in some other file defaulting into the weaker
    /// behaviour with nothing failing, so the set is asserted here the way
    /// this suite asserts `startComparison(`'s: adding a caller is a decision
    /// somebody makes in this test.
    @Test func everyCallerOfTheMenuModelIsAccountedFor() throws {
        var callers: [String: Int] = [:]
        for url in try Self.swiftFiles() {
            let code = Self.collapsed(try SourceCorpus.code(of: url))
            let calls = Self.occurrences(of: "BrowserContextMenu.entries(", in: code)
            guard calls > 0 else { continue }
            callers[url.lastPathComponent] = calls
        }
        // Six production calls, in three files. The declaration is not a call
        // and does not appear here.
        #expect(callers == [
            "BrowserKeyCommand.swift": 4,
            "RemoteFileTableView.swift": 1,
            "ContentView+Transfers.swift": 1,
        ], "\(callers)")
        #expect(callers.values.reduce(0, +) == 6)

        // Exactly one of the six passes `destinationRows`, and it is the
        // context menu's own — the only one that can offer a comparison entry.
        let table = try Self.code("RemoteFileTableView.swift")
        #expect(Self.occurrences(of: "destinationRows: currentDestinationRows)", in: table) == 1)
        var passing: [String] = []
        for url in try Self.swiftFiles() {
            let code = Self.collapsed(try SourceCorpus.code(of: url))
            if Self.occurrences(of: "destinationRows:", in: code) > 0 {
                passing.append(url.lastPathComponent)
            }
        }
        // The menu model's declaration, the two views that forward the
        // closure, and the window that supplies it. No other file names it.
        #expect(passing.sorted() == [
            "BrowserContextMenu.swift", "BrowserPane.swift", "ContentView+Detail.swift",
            "RemoteFileTableView.swift",
        ], "\(passing.sorted())")
    }

    /// Both items are titled from the catalogue, never from a literal in the
    /// view — CLAUDE.md's "never hardcode a display string".
    @Test func bothItemsAreTitledFromTheCatalogue() throws {
        let table = try Self.withLiterals("RemoteFileTableView.swift")
        // Positive: the neighbouring item this one sits beside still reads
        // its own key.
        #expect(table.contains("L10n.string(\"menu.copyPath\""))
        #expect(table.contains("L10n.string(\"menu.compare.otherPane\""))
        #expect(table.contains("L10n.string(\"menu.compare.twoSelected\""))
    }

    // MARK: One door, and it opens the window for what it started

    /// `SessionTab.startComparison` is called from exactly ONE place in the
    /// App, the function that also opens the window. A second caller is a
    /// comparison that runs with nothing on screen.
    @Test func everyComparisonIsStartedThroughTheOneFunctionThatOpensItsWindow() throws {
        var callers: [String] = []
        for url in try Self.swiftFiles() {
            let code = try SourceCorpus.code(of: url)
            if Self.occurrences(of: "startComparison(", in: Self.collapsed(code)) > 0 {
                callers.append(url.lastPathComponent)
            }
        }
        // The one caller's file, and the declaration's.
        #expect(callers.sorted() == [Self.doorFile, "SessionTab.swift"])

        let door = try Self.code(Self.doorFile)
        #expect(Self.occurrences(of: "tab.startComparison(", in: door) == 1)
        #expect(Self.occurrences(of: "openWindow(value: ComparisonSeed(", in: door) == 1)
    }

    /// The seed names the comparison that was JUST returned — never one
    /// lying around. A window resolves its seed once, so a seed built from
    /// anything else latches onto whatever that id still means, or onto
    /// nothing.
    @Test func theSeedIsBuiltFromTheComparisonThatWasJustStarted() throws {
        let open = try Self.body("func openComparison(", in: Self.doorFile)
        #expect(open.contains("guard let comparison = tab.startComparison("))
        #expect(open.contains("openWindow(value: ComparisonSeed(tabID: tab.id, comparisonID: comparison.id))"))

        // Negative beside it: nothing else in the App builds a seed. The
        // window file declares the type and the app declares the scene, and
        // neither constructs one.
        var builders: [String] = []
        for url in try Self.swiftFiles() {
            let code = Self.collapsed(try SourceCorpus.code(of: url))
            if Self.occurrences(of: "ComparisonSeed(", in: code) > 0 {
                builders.append(url.lastPathComponent)
            }
        }
        #expect(builders.sorted() == [Self.doorFile])
    }

    /// A refused start opens nothing: `startComparison` answers nil when the
    /// tab has no session or a teardown is running, and the only `openWindow`
    /// in the function stands after the `guard` that returns on it.
    @Test func aRefusedStartOpensNothing() throws {
        let open = try Self.body("func openComparison(", in: Self.doorFile)
        let guardRange = try #require(open.range(of: "else { return }"))
        let opens = try #require(open.range(of: "openWindow("))
        #expect(guardRange.upperBound <= opens.lowerBound)
        #expect(Self.occurrences(of: "openWindow(", in: open) == 1)
    }

    // MARK: What each door compares

    /// Every door asks `ComparisonRequest` for its routing and hands the
    /// request to the one function that starts a comparison and opens its
    /// window. What each request CONTAINS is `ComparisonRequestTests`'
    /// business — a value, not an anchor (fix round 1, F3).
    @Test func everyDoorAsksForARequestAndHandsItToTheOneOpener() throws {
        let doors = [
            "func compareWithOtherPane(": "ComparisonRequest.forRow(",
            "func compareTwoSelected(": "ComparisonRequest.forTwoSelected(",
            "func compareBothPanes(": "ComparisonRequest.forBothPanes(",
        ]
        for (declaration, factory) in doors {
            let body = try Self.body(declaration, in: Self.doorFile)
            #expect(body.contains(factory), "\(declaration)")
            #expect(body.contains("openComparison("), "\(declaration)")
        }
        // Three doors calling it, plus its own declaration.
        let door = try Self.code(Self.doorFile)
        #expect(Self.occurrences(of: "openComparison(", in: door) == 4)
        #expect(Self.occurrences(of: "func openComparison(", in: door) == 1)
    }

    /// NEGATIVE, with the positives beside it: no door spells a side against
    /// a root, or builds a counterpart path, itself. That decision lives in
    /// exactly one type, so there is no second place for it to drift in —
    /// which is what made the reviewer's plants B and C free.
    @Test func noDoorRoutesASideToARootItself() throws {
        let decisions = [
            "RemotePath.join(", "left: .local", "right: .remote", "left: .remote",
            "right: .local", "kind: .folders", "kind: .filePair",
        ]
        let door = try Self.code(Self.doorFile)
        for spelling in decisions + ["? .folders :", ".currentPath :"] {
            #expect(!door.contains(spelling), "a door spells \(spelling)")
        }
        // Positive: the request type spells the ones it is supposed to, so
        // the scan above is not looking for strings nothing in the tree has.
        let request = try Self.code("ComparisonRequest.swift")
        for spelling in decisions where spelling != "left: .remote" && spelling != "right: .local" {
            #expect(request.contains(spelling), "the request does not spell \(spelling)")
        }

        // EVERY side and root the door names is read off the request, not
        // chosen: the counts match, so a hand-picked one would show up as an
        // extra. This is the positive form the negatives above rest on.
        for (label, read) in [
            ("left:", "left: request.left"), ("leftRoot:", "leftRoot: request.leftRoot"),
            ("right:", "right: request.right"), ("rightRoot:", "rightRoot: request.rightRoot"),
            ("kind:", "kind: request.kind"),
        ] {
            #expect(
                Self.occurrences(of: label, in: door) == Self.occurrences(of: read, in: door),
                "\(label)")
            #expect(Self.occurrences(of: read, in: door) == 1, "\(read)")
        }

        // The two pane directories the doors DO read go to the labels that
        // name them. A value test cannot see this: swapping these two
        // arguments is the reviewer's plant B one level up, and it would make
        // every one-row comparison compare a row against itself.
        #expect(Self.occurrences(of: "localDirectory: session.local.currentPath", in: door) == 2)
        #expect(Self.occurrences(of: "remoteDirectory: session.remote.currentPath", in: door) == 2)
        #expect(Self.occurrences(of: "localDirectory:", in: door) == 2)
        #expect(Self.occurrences(of: "remoteDirectory:", in: door) == 2)
    }

    /// Fix round 2. The far side's kind is read from the OTHER pane's loaded
    /// rows, and each pane has to be handed the other one's. A value test
    /// cannot see this: swapping these two closures hands each pane its own
    /// rows, whereupon a row is checked against ITSELF — plant B's shape,
    /// one layer out — and every symlink row would be withheld while every
    /// far symlink was offered.
    @Test func eachPaneIsHandedTheOtherPanesRows() throws {
        let detail = try Self.code("ContentView+Detail.swift")
        #expect(Self.occurrences(of: "destinationRows: { session.remote.items }", in: detail) == 1)
        #expect(Self.occurrences(of: "destinationRows: { session.local.items }", in: detail) == 1)
        #expect(Self.occurrences(of: "destinationRows:", in: detail) == 2)
        // Each one sits with the scope closure that names the SAME pane, so
        // the two reads of "the other pane" cannot disagree.
        for pane in ["remote", "local"] {
            let rows = try #require(
                detail.range(of: "destinationRows: { session.\(pane).items }"))
            let before = String(detail[..<rows.lowerBound].suffix(260))
            #expect(
                before.contains("currentPath: session.\(pane).currentPath)"),
                "the \(pane) rows do not sit with the \(pane) scope")
        }

        // Plumbed, not merely declared: a closure the pane never forwards is
        // a gate that reads an empty listing for ever.
        let pane = try Self.code("BrowserPane.swift")
        #expect(pane.contains("var destinationRows: (() -> [RemoteFileItem])? = nil"))
        #expect(pane.contains("destinationRows: destinationRows"))
        let table = try Self.code("RemoteFileTableView.swift")
        #expect(table.contains("var destinationRows: (() -> [RemoteFileItem])? = nil"))
        #expect(Self.occurrences(of: "coordinator.destinationRows = destinationRows", in: table) == 2)
        #expect(table.contains("var currentDestinationRows: [RemoteFileItem] { destinationRows?() ?? [] }"))
        // And the menu model is asked with them, beside the scope it was
        // already asked with.
        #expect(table.contains("destination: currentDestinationScope, destinationRows: currentDestinationRows)"))
    }

    /// Fix round 1, F1. A file pair has no classification, so the kind check
    /// in the shared diff step is the last thing between the FAR side of a
    /// one-row comparison and the transfer queue — and the only one at all
    /// for a far side the menu model had no row for. It is stated once, where
    /// both diff entry points pass. This read "the only thing between the FAR
    /// side of a one-row comparison — a path the menu model never saw — and
    /// the transfer queue" until fix round 3: since round 2 the menu model
    /// does see that side, when the other pane has listed it.
    @Test func theOnlyKindCheckAFilePairGetsIsStatedOnceAndBeforeTheFetch() throws {
        let comparison = try Self.code(Self.comparisonFile)
        #expect(Self.occurrences(of: "notAnOrdinaryFile", in: comparison) == 1)
        let body = try Self.body("private func diffUnmapped(", in: Self.comparisonFile)
        #expect(body.contains("switch item.kind {"))
        // What it refuses is what is KNOWN to be unsuitable; `.other` (a type
        // nobody reported) is not in that arm, and the behaviour is pinned in
        // `ComparisonFetchTests`.
        #expect(body.contains("case .directory, .symlink:"))
        // Before the size question and before the fetch: a directory is
        // refused as one rather than as an oversized file, and no byte moves.
        let kind = try #require(body.range(of: "switch item.kind {"))
        let size = try #require(body.range(of: "DiffEligibility.refusal(forByteCount:"))
        let fetch = try #require(body.range(of: "try await fetch(leftPath: leftPath"))
        #expect(kind.upperBound <= size.lowerBound)
        #expect(kind.upperBound <= fetch.lowerBound)
    }

    // MARK: Who opts in to cancelling the transfer

    /// One occurrence of `enqueueAndWait(` in code: where it is, whether it
    /// is the declaration, and whether its argument list names
    /// `cancelsWithTask: true`.
    private struct QueueWaitCall: Equatable {
        let file: String
        let isDeclaration: Bool
        let optsIn: Bool
    }

    /// Every `enqueueAndWait(` in `code` (comments and string literals already
    /// blanked). The needle does not match `enqueueEditUploadAndWait(`, which
    /// does not contain it, and a name that merely ends in it is skipped by
    /// requiring a non-identifier character before.
    private static func queueWaitCalls(in code: String, file: String) -> [QueueWaitCall] {
        let needle = "enqueueAndWait("
        var found: [QueueWaitCall] = []
        var cursor = code.startIndex
        while let hit = code.range(of: needle, range: cursor..<code.endIndex) {
            cursor = hit.upperBound
            if hit.lowerBound > code.startIndex {
                let before = code[code.index(before: hit.lowerBound)]
                if before.isLetter || before.isNumber || before == "_" { continue }
            }
            var depth = 1
            var end = hit.upperBound
            while end < code.endIndex, depth > 0 {
                if code[end] == "(" { depth += 1 } else if code[end] == ")" { depth -= 1 }
                end = code.index(after: end)
            }
            let arguments = collapsed(String(code[hit.upperBound..<end]))
            let head = code[..<hit.lowerBound].split(whereSeparator: \.isWhitespace).last
            found.append(QueueWaitCall(
                file: file, isDeclaration: head == "func",
                optsIn: arguments.contains("cancelsWithTask: true")))
        }
        return found
    }

    /// The scanner above, on literal fixture input and not on the tree: a
    /// declaration, a call that opts in, a call that does not (wrapped over
    /// lines, with a nested call in its arguments), the edit-upload sibling,
    /// and a name that only ends in the needle.
    @Test func theQueueWaitScannerReadsCallsDeclarationsAndOptInFromAFixture() {
        let fixture = """
            public func enqueueAndWait(
                fileName: String, cancelsWithTask: Bool = false
            ) async throws {}
            try await queue.enqueueAndWait(
                fileName: a, destinationDirectory: dir.path(percentEncoded: false),
                cancelsWithTask: true)
            try await queue.enqueueAndWait(
                fileName: b, destinationDirectory: dir.path(percentEncoded: false))
            try? await queue.enqueueEditUploadAndWait(fileName: c)
            try await queue.reenqueueAndWait(fileName: d)
            """
        let calls = Self.queueWaitCalls(in: fixture, file: "Fixture.swift")
        #expect(calls == [
            QueueWaitCall(file: "Fixture.swift", isDeclaration: true, optsIn: false),
            QueueWaitCall(file: "Fixture.swift", isDeclaration: false, optsIn: true),
            QueueWaitCall(file: "Fixture.swift", isDeclaration: false, optsIn: false),
        ])
    }

    /// `TransferQueueViewModel.enqueueAndWait` keeps its default (the weaker
    /// behaviour: the awaiting task's cancel does not reach the item), so a
    /// new caller would take that default without anyone deciding it. This
    /// names the callers, tree-wide, and says which opt in:
    ///
    /// - `Comparison.swift`, both fetches: opt in. Selecting a row starts its
    ///   diff and moving the selection cancels the task.
    /// - `ContentView+Transfers.swift` (the Finder promise provider): does
    ///   not. Its `Task` is started and no handle is kept, and the delegate
    ///   implements no cancel callback, so nothing can cancel it today — a
    ///   latent gap, and the one caller where a future cancel source should
    ///   opt in.
    /// - `EditSessionManager.swift` (`downloadAndRegister`): does not, and
    ///   should not. It runs inside the shared `inFlightDownloads[remotePath]`
    ///   task that every concurrent opener awaits through `task.value`, which
    ///   does not propagate cancellation; a per-caller cancel that killed a
    ///   shared download would be wrong for the other openers.
    ///
    /// Counted by name and not by number, over code only (comments and
    /// literals blanked, so the prose mention in `RemoteFilePromise.swift`
    /// cannot count), with the raw total beside it.
    @Test func theCallersOfEnqueueAndWaitThatOptInToCancellationAreNamed() throws {
        var calls: [QueueWaitCall] = []
        var withTheParameter: Set<String> = []
        var raw = 0
        for url in try Self.swiftFiles() {
            let code = try SourceCorpus.code(of: url)
            raw += code.components(separatedBy: "enqueueAndWait(").count - 1
            calls += Self.queueWaitCalls(in: code, file: url.lastPathComponent)
            if code.contains("cancelsWithTask") { withTheParameter.insert(url.lastPathComponent) }
        }
        // Raw total: five occurrences in code under `Sources`, one of them
        // the declaration. The prose mention in a comment is not among them,
        // because the blanked view drops it.
        #expect(raw == 5)
        let declarations = calls.filter(\.isDeclaration).map(\.file)
        #expect(declarations == ["TransferQueueViewModel.swift"])
        let callers = calls.filter { !$0.isDeclaration }
        #expect(callers.map(\.file).sorted() == [
            "Comparison.swift", "Comparison.swift", "ContentView+Transfers.swift",
            "EditSessionManager.swift",
        ])
        #expect(callers.filter(\.optsIn).map(\.file) == ["Comparison.swift", "Comparison.swift"])
        // The parameter exists only where it is declared and where it is used.
        #expect(withTheParameter == ["TransferQueueViewModel.swift", "Comparison.swift"])
    }

    /// The menu-bar item exists, is wired by the window that owns the tabs,
    /// and is disabled on the capability — the same bridge shape as every
    /// other `tabCommands` entry.
    @Test func theMenuBarItemIsWiredThroughTheFocusedWindowsBridge() throws {
        let app = try Self.code("MacSCPApp.swift")
        #expect(app.contains("var compareBothPanes: (() -> Void)?"))

        let commands = try Self.withLiterals("MacSCPCommands.swift")
        #expect(commands.contains("L10n.string(\"menu.compare.panes\""))
        #expect(commands.contains("tabCommands?.compareBothPanes?()"))
        // Positive beside the gate below: the neighbouring item that reads
        // its own mirror is still there.
        #expect(commands.contains("tabCommands?.toggleTransfers?()"))
        let item = try #require(commands.range(of: "tabCommands?.compareBothPanes?()"))
        let rest = String(commands[item.upperBound...].prefix(160))
        #expect(rest.contains(".disabled(tabCommands?.canCompareBothPanes != true)"))

        let lifecycle = try Self.code("ContentView+Lifecycle.swift")
        #expect(Self.occurrences(of: "tabCommands.compareBothPanes =", in: lifecycle) == 1)
        #expect(lifecycle.contains("compareBothPanes(in: tabsModel.activeTab, session: session)"))
    }

    /// Fix round 1, F2. The entry is gated on a CAPABILITY mirror, not on
    /// "connected" alone and not on a `guard … else { return }` inside the
    /// closure: a bucket list is not a directory, and a folder comparison
    /// against one walks every matching bucket. The mirror has to exist, be
    /// read by the `.disabled` above, be fed from the pane scopes, and be
    /// kept in sync — four separate ways for it to be inert.
    @Test func theMenuBarEntryIsDisabledWhileEitherPaneSitsAtAContainerList() throws {
        let app = try Self.code("MacSCPApp.swift")
        #expect(app.contains("var activeTabPanesAreComparable = true"))
        #expect(app.contains(
            "var canCompareBothPanes: Bool { isActiveTabConnected && activeTabPanesAreComparable }"))
        // Positive beside it: the mirror this one is modelled on is still
        // spelled the same way, so the scan is reading this file's real shape.
        #expect(app.contains("var activeTabSupportsShell = true"))

        // Fed from the pane scopes, through the one predicate the value tests
        // cover — not a second spelling of "is this a bucket list".
        let door = try Self.body("var activeTabPanesAreComparable: Bool", in: Self.doorFile)
        #expect(door.contains("ComparisonRequest.panesAreComparable("))
        #expect(door.contains("local: localScope(session)"))
        #expect(door.contains("remote: remoteScope(session)"))
        #expect(!door.contains("isContainerListRoot"), "the door re-spells the bucket-list rule")

        // Kept in sync, beside the three mirrors that were already there.
        let view = try Self.code("ContentView.swift")
        #expect(Self.occurrences(
            of: ".onChange(of: activeTabPanesAreComparable, initial: true)", in: view) == 1)
        #expect(Self.occurrences(
            of: "tabCommands.activeTabPanesAreComparable = newValue", in: view) == 1)
        #expect(Self.occurrences(
            of: ".onChange(of: activeTabSupportsShell, initial: true)", in: view) == 1)
    }
}
