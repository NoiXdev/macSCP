import Foundation
import Testing

/// Guards the sidebar's three dismissible red captions (dev-build
/// follow-up, 2026-09-03: the maintainer saw `core.session.groupMoveCycle`
/// stay on screen with nothing to close it) — `groupMoveErrorBanner`
/// (`viewModel.errorMessage`), `jumpRestoreErrorBanner`
/// (`jumpRestoreErrorMessage`) and `hiddenImportsErrorBanner`
/// (`hiddenImportsErrorMessage`), all three in `SessionSidebar.swift`. The
/// first two got the close button and the auto-dismiss in `ece5aaf9`; the
/// third — `hiddenImportsErrorMessage`, owned by `ContentView` rather than
/// by this view or a view model, since both the "Hide" context-menu action
/// and the startup/refresh read can set it — was left open by that same
/// commit and is what that follow-up closed.
///
/// The three bodies were near-identical `HStack`/close-button/`.task(id:)`
/// copies of one another, which two review rounds (`ece5aaf9`, `c4558e9b`)
/// flagged as a follow-up; this refactor pulled the shared shape into one
/// `sidebarErrorBanner(message:onDismiss:)`, called once from each of the
/// three. This suite now proves the property in two halves: each banner
/// property reaches the shared builder and dismisses through the RIGHT
/// call (`viewModel.dismissError()` for the first, a direct
/// `jumpRestoreErrorMessage = nil` write for the second, and
/// `onDismissHiddenImportsError()` for the third); and the shared builder
/// itself carries the close button, the `.task(id:)` keyed on its own
/// `message` parameter, and the `errorAutoDismissDelay` constant — checked
/// once, since checking it three times over three near-identical copies is
/// exactly the duplication this refactor removed. Every claim is made
/// against the BODY of the relevant declaration — a brace-balanced span,
/// not a guessed window — for the reason CLAUDE.md records from the
/// snippets guard: a check that looks in the wrong region cannot ever
/// match a real violation, and a check with no span at all is reading
/// prose about the code rather than the code.
///
/// The delay itself is read from the source, not typed into this suite as
/// a literal `.seconds(6)` — CLAUDE.md's rule on comments/tests that quote a
/// number applies just as much to a guard: this file names the SYMBOL
/// (`errorAutoDismissDelay`) and confirms the declaration exists, so a
/// later change to how long the banner stays up does not require touching
/// two files that both spell out the same duration.
///
/// Every scan here reads STRIPPED source (`SwiftSource`). Structural claims
/// (bindings, the `.task` wiring) are made against the strict view —
/// comments AND string literals blanked; the catalogue-key claim is about a
/// literal, so it reads the view that blanks comments only.
///
/// Known blind spots, so a green run is not read as more than it is:
/// - SOURCE TEXT, never a rendered view. Nothing here can tell whether the
///   caption is actually readable, whether the button is hit-testable, or
///   whether six seconds really elapse on screen.
/// - The negative check below (no `Task.sleep(` outside the shared banner's
///   own `.task`) is a COUNT, held to the real file by a positive anchor
///   (`allBannersAreActuallyPlacedInTheSidebar` plus the shared builder's
///   own declared-once/called-three-times check) for exactly the reason
///   CLAUDE.md gives for negative checks: `!contains` and an empty-count
///   both read as "satisfied" whether the thing they scan is present or has
///   quietly vanished, and only a paired positive check tells the two apart.
/// - `hiddenImportsErrorBanner`'s own dismiss cannot be proven by running
///   code the way `SessionListViewModelTests.dismissErrorClearsTheMessage`
///   proves `viewModel.dismissError()`: `hiddenImportsErrorMessage` is a
///   `@State var` on `ContentView`, and a bare, unmounted `ContentView`
///   drops writes to its own `@State` — measured directly (a two-line
///   script: build a `View` with one `@State` property, call a method on
///   it that sets that property, read it back through the same instance —
///   the read shows the ORIGINAL value) and consistent with what
///   `AlreadyOpenSessionTests`/`ReconnectPathTests` already record about
///   this exact codebase. `jumpRestoreErrorMessage` — the other local
///   `@State` banner — got the identical guard-only treatment for the
///   identical reason; only `viewModel.errorMessage`, backed by a real
///   class, is behaviorally testable. `HiddenImportsErrorDismissGuardTests`
///   covers the `ContentView`-side half (the method body and the wiring
///   that reaches it) the same way, by source scan.
@Suite("Session sidebar dismissible error banners")
struct SessionSidebarErrorGuardTests {
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let sourceFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/SessionSidebar.swift")

    private static let groupMoveBannerDeclaration = "private var groupMoveErrorBanner: some View"
    private static let jumpRestoreBannerDeclaration = "private var jumpRestoreErrorBanner: some View"
    private static let hiddenImportsBannerDeclaration = "private var hiddenImportsErrorBanner: some View"
    private static let delayDeclaration = "private static let errorAutoDismissDelay: Duration"
    /// A prefix, not a full signature: the shared builder's parameter list
    /// spans two lines, and a partial anchor stays valid across a reformat
    /// the way `TabContextMenuWiringGuardTests`'s `.contextMenu {` anchor
    /// does. `declarationBodyRange` only needs it to precede the opening
    /// brace with no `{` in between, which the parameter list never has.
    private static let sharedBannerDeclaration = "private func sidebarErrorBanner("
    /// How each of the three banner properties must reach the shared
    /// builder — the call, not the declaration, which also contains this
    /// substring and is excluded explicitly wherever the two are told apart.
    private static let sharedBannerCallPrefix = "sidebarErrorBanner(message:"
    private static let sharedBannerDeclarationPrefix = "func sidebarErrorBanner("

    private static let dismissKey = "\"sidebar.error.dismiss\""
    private static let helpModifier = ".help("
    private static let accessibilityLabelModifier = ".accessibilityLabel("
    private static let taskSleep = "Task.sleep("
    private static let delaySymbol = "Self.errorAutoDismissDelay"
    private static let taskIdMessage = ".task(id: message)"
    private static let hiddenImportsDismissCall = "onDismissHiddenImportsError()"

    /// The two views of the sidebar this suite reads, both derived from one
    /// read of the file and both the same length as it (see `SwiftSource`).
    private static func sidebarViews() throws -> (code: String, withLiterals: String) {
        let raw = try String(contentsOf: sourceFile, encoding: .utf8)
        return (try SwiftSource.blankingCommentsAndStrings(raw),
                try SwiftSource.blankingComments(raw))
    }

    private static func bannerBodies(
        of declaration: String
    ) throws -> (code: String, withLiterals: String) {
        let all = try sidebarViews()
        let range = try TransferQueueBarCancelGuardTests.declarationBodyRange(
            of: declaration, in: all.code)
        return (TransferQueueBarCancelGuardTests.slice(range, of: all.code),
                TransferQueueBarCancelGuardTests.slice(range, of: all.withLiterals))
    }

    /// The shared banner builder's own brace-balanced body — where the close
    /// button, the `.task(id:)` and the delay symbol actually live now.
    private static func sharedBannerBody() throws -> (code: String, withLiterals: String) {
        try bannerBodies(of: Self.sharedBannerDeclaration)
    }

    // MARK: - The guard

    @Test func groupMoveBannerReachesTheSharedBuilderAndClosesThroughDismissError() throws {
        let bodies = try Self.bannerBodies(of: Self.groupMoveBannerDeclaration)
        #expect(bodies.code.contains(Self.sharedBannerCallPrefix), """
            groupMoveErrorBanner must call the shared \
            sidebarErrorBanner(message:onDismiss:) builder -- a banner that \
            stopped calling it would draw nothing the shared-builder checks \
            below actually cover.
            """)
        #expect(bodies.code.contains("viewModel.dismissError()"), """
            groupMoveErrorBanner's dismiss closure must call \
            viewModel.dismissError() -- any other write would leave \
            errorMessage set and the caption right back on screen.
            """)
    }

    @Test func jumpRestoreBannerReachesTheSharedBuilderAndClosesLocally() throws {
        let bodies = try Self.bannerBodies(of: Self.jumpRestoreBannerDeclaration)
        #expect(bodies.code.contains(Self.sharedBannerCallPrefix), """
            jumpRestoreErrorBanner must call the shared \
            sidebarErrorBanner(message:onDismiss:) builder -- a banner that \
            stopped calling it would draw nothing the shared-builder checks \
            below actually cover.
            """)
        #expect(bodies.code.contains("jumpRestoreErrorMessage = nil"), """
            jumpRestoreErrorBanner's dismiss closure must clear \
            jumpRestoreErrorMessage directly -- it is local @State, not a \
            view-model property, so there is no dismissError() to call here.
            """)
    }

    /// `hiddenImportsErrorMessage` reaches `SessionSidebar` as a plain
    /// `let` (owned by `ContentView`, not this view), so unlike the other
    /// two banners there is no property this view can write directly --
    /// the dismiss closure has to go through the
    /// `onDismissHiddenImportsError` callback instead.
    @Test func hiddenImportsBannerReachesTheSharedBuilderAndClosesThroughTheCallback() throws {
        let bodies = try Self.bannerBodies(of: Self.hiddenImportsBannerDeclaration)
        #expect(bodies.code.contains(Self.sharedBannerCallPrefix), """
            hiddenImportsErrorBanner must call the shared \
            sidebarErrorBanner(message:onDismiss:) builder -- a banner that \
            stopped calling it would draw nothing the shared-builder checks \
            below actually cover.
            """)
        #expect(bodies.code.contains(Self.hiddenImportsDismissCall), """
            hiddenImportsErrorBanner's dismiss closure must call \
            onDismissHiddenImportsError() -- hiddenImportsErrorMessage is a \
            plain let here, so nothing in this view can clear it directly.
            """)
    }

    /// The shared builder is declared exactly once and called exactly three
    /// times -- once from each of the three banner properties above. The
    /// positive companion to the three "reaches the shared builder" checks:
    /// those only prove EACH banner names the builder, not that the builder
    /// itself is not, say, declared twice with the second copy doing
    /// nothing, or called a fourth time from somewhere with no message to
    /// show.
    @Test func theSharedBannerIsDeclaredOnceAndCalledFromAllThreeBanners() throws {
        let code = try Self.sidebarViews().code
        let totalMentions = TransferQueueBarCancelGuardTests.occurrenceCount(
            of: "sidebarErrorBanner(", in: code)
        let declarations = TransferQueueBarCancelGuardTests.occurrenceCount(
            of: Self.sharedBannerDeclarationPrefix, in: code)
        #expect(declarations == 1, """
            SessionSidebar.swift must declare sidebarErrorBanner(message:onDismiss:) \
            exactly once -- found \(declarations).
            """)
        let calls = totalMentions - declarations
        #expect(calls == 3, """
            sidebarErrorBanner(message:onDismiss:) must be called exactly three \
            times -- once each from groupMoveErrorBanner, jumpRestoreErrorBanner \
            and hiddenImportsErrorBanner. Found \(calls) call(s) against \
            \(totalMentions) total mentions and \(declarations) declaration(s).
            """)
    }

    /// The shared builder's own body: the auto-dismiss task keyed on its
    /// `message` parameter, sleeping for the one shared delay constant and
    /// clearing through whichever `onDismiss` its caller passed. Checked
    /// once here instead of three times over three near-identical copies --
    /// that duplication is exactly what this refactor removed.
    @Test func theSharedBannerKeysItsAutoDismissTaskOnItsOwnMessageParameter() throws {
        let bodies = try Self.sharedBannerBody()
        #expect(bodies.code.contains(Self.taskIdMessage), """
            sidebarErrorBanner(message:onDismiss:) must key its auto-dismiss task \
            on its own message parameter, so SwiftUI restarts the six-second \
            countdown whenever the caller's message changes rather than counting \
            down from whenever the banner first appeared.
            """)
        #expect(bodies.code.contains(Self.taskSleep) && bodies.code.contains(Self.delaySymbol), """
            the auto-dismiss task must await Task.sleep(for: \
            Self.errorAutoDismissDelay) -- a hand-rolled duration here would be \
            a second spelling of the six seconds this suite holds to one \
            declaration, inherited by all three banners that call this builder.
            """)
        #expect(bodies.code.contains("onDismiss()"), """
            the auto-dismiss task must call onDismiss() when it fires -- \
            without it, the countdown would elapse and leave the caption on \
            screen exactly as before.
            """)
    }

    /// The shared builder's close button is icon-only, so it needs BOTH
    /// `.help` (the pointer hover hint) and `.accessibilityLabel` (what
    /// VoiceOver reads) -- same pairing `TransferQueueBarCancelGuardTests`
    /// holds the row cancel to, and for the same reason: without the second
    /// one, the button announces itself as the name of an SF Symbol. And
    /// its catalogue key: the button carries no visible text, so the key is
    /// its whole label, and it must come from `sidebar.error.dismiss` for
    /// all three banners that call this builder.
    @Test func theSharedBannerCloseButtonCarriesTheCatalogueKeyHelpAndAccessibilityLabel() throws {
        let bodies = try Self.sharedBannerBody()
        #expect(bodies.withLiterals.contains(Self.dismissKey), """
            The close button's catalogue key must come from \
            sidebar.error.dismiss.
            """)
        #expect(bodies.code.contains(Self.helpModifier),
            "sidebarErrorBanner(message:onDismiss:) no longer sets .help(")
        #expect(bodies.code.contains(Self.accessibilityLabelModifier),
            "sidebarErrorBanner(message:onDismiss:) no longer sets .accessibilityLabel(")
    }

    /// The shared delay is a named declaration this suite can point at,
    /// rather than a value it types out and repeats -- CLAUDE.md's rule
    /// that a number written into a comment or a test is a claim to verify,
    /// not evidence, applies to this guard's own expectations too.
    @Test func theSharedDelayIsANamedDurationDeclaration() throws {
        let code = try Self.sidebarViews().code
        #expect(code.contains(Self.delayDeclaration), """
            SessionSidebar.swift no longer declares \
            \(Self.delayDeclaration) -- all three banners above are checked \
            against Self.errorAutoDismissDelay, which must name a real \
            declaration, not a symbol nothing defines.
            """)
    }

    /// Positive anchor for the check above and for the negative check below:
    /// each banner must be declared once and placed once in `body`, or an
    /// unreadable/renamed declaration would leave every `contains` check in
    /// this suite green over a caption the user can never see -- the exact
    /// failure mode CLAUDE.md records from the transfer bar's cancel guard,
    /// where a doc comment naming a control held a count green after the
    /// real placement was deleted.
    @Test func allBannersAreActuallyPlacedInTheSidebar() throws {
        let code = try Self.sidebarViews().code
        let groupMoveUses = TransferQueueBarCancelGuardTests.occurrenceCount(
            of: "groupMoveErrorBanner", in: code)
        #expect(groupMoveUses == 2, """
            groupMoveErrorBanner must be declared once and placed once in \
            the sidebar's body -- found \(groupMoveUses) mentions in code.
            """)
        let jumpRestoreUses = TransferQueueBarCancelGuardTests.occurrenceCount(
            of: "jumpRestoreErrorBanner", in: code)
        #expect(jumpRestoreUses == 2, """
            jumpRestoreErrorBanner must be declared once and placed once in \
            the sidebar's body -- found \(jumpRestoreUses) mentions in code.
            """)
        let hiddenImportsUses = TransferQueueBarCancelGuardTests.occurrenceCount(
            of: "hiddenImportsErrorBanner", in: code)
        #expect(hiddenImportsUses == 2, """
            hiddenImportsErrorBanner must be declared once and placed once \
            in the sidebar's body -- found \(hiddenImportsUses) mentions in \
            code.
            """)
    }

    /// The negative half: nothing in `SessionSidebar.swift` may block on
    /// `Task.sleep(` except the shared banner's own auto-dismiss task. A
    /// blocking wait anywhere else in this file would be exactly the shape
    /// CLAUDE.md's "tests never block the cooperative pool" section warns
    /// against, planted in application code rather than a test this time --
    /// and a stray sleep sitting outside a `.task` would run on whatever
    /// context calls it, not cancel when the view disappears the way this
    /// one does. Held to the file by the positive check just above (the
    /// builder is declared exactly once) plus the positive check right here
    /// (its body really does sleep once): if the builder's declaration went
    /// missing, its body would read as empty and this count would silently
    /// balance by finding nothing on both sides.
    @Test func noTaskSleepAppearsOutsideTheSharedBannersOwnTask() throws {
        let code = try Self.sidebarViews().code
        let totalSleeps = TransferQueueBarCancelGuardTests.occurrenceCount(
            of: Self.taskSleep, in: code)
        let sharedBannerSleeps = TransferQueueBarCancelGuardTests.occurrenceCount(
            of: Self.taskSleep, in: try Self.sharedBannerBody().code)
        // Positive first: the shared banner really does sleep once, so the
        // negative below is a real balance check, not two empty counts
        // agreeing by accident.
        #expect(sharedBannerSleeps == 1, """
            sidebarErrorBanner(message:onDismiss:) must contain exactly one \
            Task.sleep( call -- found \(sharedBannerSleeps).
            """)
        #expect(totalSleeps == sharedBannerSleeps, """
            SessionSidebar.swift contains \(totalSleeps) Task.sleep( calls, \
            but only \(sharedBannerSleeps) sit inside \
            sidebarErrorBanner(message:onDismiss:)'s own body -- a blocking \
            wait elsewhere in this file would not cancel when its view \
            disappears the way this one does.
            """)
    }

    /// What the checks above would be worth nothing without: the strict view
    /// must actually be reaching the file.
    @Test func theStrictViewStillContainsTheSidebarsCode() throws {
        let readsTheSidebar = try Self.sidebarViews().code.contains("struct SessionSidebar: View")
        #expect(readsTheSidebar, """
            the strict view of SessionSidebar.swift no longer contains the \
            sidebar's own declaration -- the stripper or the path is wrong, \
            and every scan in this suite is reading something other than the \
            file it names
            """)
    }

    // MARK: - The scanner reacts (self-tests over synthetic sources)

    /// The needles the negative self-tests below use are the same constants
    /// the real-file checks read, so a needle can never name a string that
    /// appears nowhere in the tree.
    @Test func theSelfTestNeedlesAreThingsTheRealFileActuallyContains() throws {
        let groupMoveBodies = try Self.bannerBodies(of: Self.groupMoveBannerDeclaration)
        #expect(groupMoveBodies.code.contains(Self.sharedBannerCallPrefix))
        #expect(groupMoveBodies.code.contains("viewModel.dismissError()"))
        let hiddenImportsBodies = try Self.bannerBodies(of: Self.hiddenImportsBannerDeclaration)
        #expect(hiddenImportsBodies.code.contains(Self.hiddenImportsDismissCall))
        let sharedBody = try Self.sharedBannerBody()
        #expect(sharedBody.code.contains(Self.taskIdMessage))
        #expect(sharedBody.code.contains(Self.taskSleep))
        #expect(sharedBody.code.contains(Self.delaySymbol))
        #expect(sharedBody.withLiterals.contains(Self.dismissKey))
        let code = try Self.sidebarViews().code
        #expect(code.contains(Self.delayDeclaration))
        #expect(code.contains(Self.sharedBannerDeclarationPrefix))
    }

    @Test func scannerSeesACloseButtonNotBoundToDismissError() throws {
        let source = """
            \(Self.groupMoveBannerDeclaration) {
                if let errorMessage = viewModel.errorMessage {
                    HStack {
                        Text(errorMessage)
                        Button {
                            jumpRestoreErrorMessage = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .help(L10n.string("sidebar.error.dismiss", "Dismiss"))
                        .accessibilityLabel(L10n.string("sidebar.error.dismiss", "Dismiss"))
                    }
                }
            }
            """
        let code = try SwiftSource.blankingCommentsAndStrings(source)
        let body = try TransferQueueBarCancelGuardTests.declarationBody(
            of: Self.groupMoveBannerDeclaration, in: code)
        // Positive first: a close button really is there, wired to
        // *something* -- so the negative below reports the wrong binding
        // rather than an empty read.
        #expect(body.contains("Button {"))
        #expect(!body.contains("viewModel.dismissError()"), """
            the scanner must report a close button bound to a different \
            property as not calling dismissError(), not wave it through \
            because a Button with the right label is present
            """)
    }

    @Test func scannerSeesATaskKeyedOnTheWrongMessage() throws {
        let source = """
            \(Self.groupMoveBannerDeclaration) {
                if let errorMessage = viewModel.errorMessage {
                    HStack {
                        Text(errorMessage)
                        Button { viewModel.dismissError() } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .help(L10n.string("sidebar.error.dismiss", "Dismiss"))
                        .accessibilityLabel(L10n.string("sidebar.error.dismiss", "Dismiss"))
                    }
                    .task(id: jumpRestoreErrorMessage) {
                        try? await Task.sleep(for: Self.errorAutoDismissDelay)
                        viewModel.dismissError()
                    }
                }
            }
            """
        let code = try SwiftSource.blankingCommentsAndStrings(source)
        let body = try TransferQueueBarCancelGuardTests.declarationBody(
            of: Self.groupMoveBannerDeclaration, in: code)
        // Positive first: the binding and the sleep ARE both present, so the
        // negative below reports the mis-keyed task rather than an empty
        // read.
        #expect(body.contains("viewModel.dismissError()"))
        #expect(body.contains(Self.taskSleep))
        #expect(!body.contains(".task(id: viewModel.errorMessage)"), """
            the scanner must report a task keyed on the wrong message as not \
            wired to viewModel.errorMessage, not accept it because SOME \
            .task(id:) is present
            """)
    }

    @Test func scannerSeesASleepThatDoesNotUseTheSharedConstant() throws {
        let source = """
            \(Self.groupMoveBannerDeclaration) {
                if let errorMessage = viewModel.errorMessage {
                    HStack {
                        Text(errorMessage)
                        Button { viewModel.dismissError() } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .help(L10n.string("sidebar.error.dismiss", "Dismiss"))
                        .accessibilityLabel(L10n.string("sidebar.error.dismiss", "Dismiss"))
                    }
                    .task(id: viewModel.errorMessage) {
                        try? await Task.sleep(for: .seconds(6))
                        viewModel.dismissError()
                    }
                }
            }
            """
        let code = try SwiftSource.blankingCommentsAndStrings(source)
        let body = try TransferQueueBarCancelGuardTests.declarationBody(
            of: Self.groupMoveBannerDeclaration, in: code)
        // Positive first: the task IS correctly keyed and does sleep, so the
        // negative below reports the missing shared constant specifically.
        #expect(body.contains(".task(id: viewModel.errorMessage)"))
        #expect(body.contains(Self.taskSleep))
        #expect(!body.contains(Self.delaySymbol), """
            the scanner must report a hand-rolled duration as not using the \
            shared Self.errorAutoDismissDelay constant, not accept it \
            because some Task.sleep( call is present
            """)
    }

    @Test func scannerSeesAMissingHoverHintOrAccessibilityLabel() throws {
        let helpOnly = """
            \(Self.groupMoveBannerDeclaration) {
                Button { viewModel.dismissError() } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .help(L10n.string("sidebar.error.dismiss", "Dismiss"))
            }
            """
        let code = try SwiftSource.blankingCommentsAndStrings(helpOnly)
        let body = try TransferQueueBarCancelGuardTests.declarationBody(
            of: Self.groupMoveBannerDeclaration, in: code)
        // Positive first: .help( really is there, so the missing pairing is
        // what the negative below is actually reporting.
        #expect(body.contains(Self.helpModifier))
        #expect(!body.contains(Self.accessibilityLabelModifier), """
            the scanner must report a button with only .help( as missing its \
            accessibility label, not accept it because SOME hint is present
            """)
    }

    @Test func scannerSeesTaskSleepPlantedOutsideEitherBanner() throws {
        let source = """
            struct SessionSidebar: View {
                private static let errorAutoDismissDelay: Duration = .seconds(6)

                var body: some View {
                    VStack {
                        groupMoveErrorBanner
                        jumpRestoreErrorBanner
                    }
                    .task {
                        try? await Task.sleep(for: .seconds(1))
                    }
                }

                \(Self.groupMoveBannerDeclaration) {
                    if let errorMessage = viewModel.errorMessage {
                        Text(errorMessage)
                            .task(id: viewModel.errorMessage) {
                                try? await Task.sleep(for: Self.errorAutoDismissDelay)
                                viewModel.dismissError()
                            }
                    }
                }

                \(Self.jumpRestoreBannerDeclaration) {
                    if let jumpRestoreErrorMessage {
                        Text(jumpRestoreErrorMessage)
                            .task(id: jumpRestoreErrorMessage) {
                                try? await Task.sleep(for: Self.errorAutoDismissDelay)
                                jumpRestoreErrorMessage = nil
                            }
                    }
                }
            }
            """
        let code = try SwiftSource.blankingCommentsAndStrings(source)
        let totalSleeps = TransferQueueBarCancelGuardTests.occurrenceCount(of: Self.taskSleep, in: code)
        let groupMoveSleeps = TransferQueueBarCancelGuardTests.occurrenceCount(
            of: Self.taskSleep,
            in: try TransferQueueBarCancelGuardTests.declarationBody(
                of: Self.groupMoveBannerDeclaration, in: code))
        let jumpRestoreSleeps = TransferQueueBarCancelGuardTests.occurrenceCount(
            of: Self.taskSleep,
            in: try TransferQueueBarCancelGuardTests.declarationBody(
                of: Self.jumpRestoreBannerDeclaration, in: code))
        // Positive first: both banners' own sleeps ARE counted correctly, so
        // the mismatch below is entirely the planted third sleep in `body`.
        #expect(groupMoveSleeps == 1)
        #expect(jumpRestoreSleeps == 1)
        #expect(totalSleeps != groupMoveSleeps + jumpRestoreSleeps, """
            the scanner must notice a Task.sleep( planted outside either \
            banner's own body as an imbalance between the file-wide count \
            and the two banner counts, not average it away
            """)
    }

    @Test func scannerFailsClosedWhenABannerIsGone() {
        let source = "struct SessionSidebar: View { var body: some View { Text(\"hi\") } }"
        #expect(throws: (any Error).self) {
            try TransferQueueBarCancelGuardTests.declarationBody(
                of: Self.groupMoveBannerDeclaration, in: source)
        }
        #expect(throws: (any Error).self) {
            try TransferQueueBarCancelGuardTests.declarationBody(
                of: Self.jumpRestoreBannerDeclaration, in: source)
        }
        #expect(throws: (any Error).self) {
            try TransferQueueBarCancelGuardTests.declarationBody(
                of: Self.hiddenImportsBannerDeclaration, in: source)
        }
        #expect(throws: (any Error).self) {
            try TransferQueueBarCancelGuardTests.declarationBody(
                of: Self.sharedBannerDeclaration, in: source)
        }
    }
}
