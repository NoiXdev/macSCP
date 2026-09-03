import Foundation
import Testing

/// Guards the sidebar's two dismissible red captions (dev-build follow-up,
/// 2026-09-03: the maintainer saw `core.session.groupMoveCycle` stay on
/// screen with nothing to close it) — `groupMoveErrorBanner`
/// (`viewModel.errorMessage`) and `jumpRestoreErrorBanner`
/// (`jumpRestoreErrorMessage`), both in `SessionSidebar.swift`.
///
/// What each banner must show, structurally: a close button bound to the
/// message it sits on top of (`viewModel.dismissError()` for the first,
/// `jumpRestoreErrorMessage = nil` for the second — a local `@State`, not a
/// view-model call), and a `.task(id:)` keyed on that same message that
/// sleeps for the shared `errorAutoDismissDelay` constant before clearing
/// it. Both claims are made against the BODY of the banner's own
/// declaration — a brace-balanced span, not a guessed window — for the
/// reason CLAUDE.md records from the snippets guard: a check that looks in
/// the wrong region cannot ever match a real violation, and a check with no
/// span at all is reading prose about the code rather than the code.
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
/// comments AND string literals blanked; the two catalogue-key claims are
/// about a literal, so they read the view that blanks comments only.
///
/// Known blind spots, so a green run is not read as more than it is:
/// - SOURCE TEXT, never a rendered view. Nothing here can tell whether the
///   caption is actually readable, whether the button is hit-testable, or
///   whether six seconds really elapse on screen.
/// - The negative check below (no `Task.sleep(` outside a banner's own
///   `.task`) is a COUNT, held to the real file by a positive anchor
///   (`bothBannersAreActuallyPlacedInTheSidebar`) for exactly the reason
///   CLAUDE.md gives for negative checks: `!contains` and an empty-count
///   both read as "satisfied" whether the thing they scan is present or has
///   quietly vanished, and only a paired positive check tells the two apart.
@Suite("Session sidebar dismissible error banners")
struct SessionSidebarErrorGuardTests {
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let sourceFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/SessionSidebar.swift")

    private static let groupMoveBannerDeclaration = "private var groupMoveErrorBanner: some View"
    private static let jumpRestoreBannerDeclaration = "private var jumpRestoreErrorBanner: some View"
    private static let delayDeclaration = "private static let errorAutoDismissDelay: Duration"

    private static let dismissKey = "\"sidebar.error.dismiss\""
    private static let helpModifier = ".help("
    private static let accessibilityLabelModifier = ".accessibilityLabel("
    private static let taskSleep = "Task.sleep("
    private static let delaySymbol = "Self.errorAutoDismissDelay"

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

    // MARK: - The guard

    @Test func groupMoveBannerClosesThroughDismissErrorAndAutoClearsOnItsOwnMessage() throws {
        let bodies = try Self.bannerBodies(of: Self.groupMoveBannerDeclaration)
        #expect(bodies.code.contains("viewModel.dismissError()"), """
            groupMoveErrorBanner's close button must call \
            viewModel.dismissError() -- any other write would leave \
            errorMessage set and the caption right back on screen.
            """)
        #expect(bodies.code.contains(".task(id: viewModel.errorMessage)"), """
            groupMoveErrorBanner must key its auto-dismiss task on \
            viewModel.errorMessage itself, so SwiftUI restarts the six-second \
            countdown whenever the message changes rather than counting down \
            from whenever the banner first appeared.
            """)
        #expect(bodies.code.contains(Self.taskSleep) && bodies.code.contains(Self.delaySymbol), """
            the auto-dismiss task must await Task.sleep(for: \
            Self.errorAutoDismissDelay) -- a hand-rolled duration here would be \
            a second spelling of the six seconds this suite holds to one \
            declaration.
            """)
        #expect(bodies.withLiterals.contains(Self.dismissKey), """
            The close button carries no visible text, so its catalogue key is \
            its whole label for VoiceOver and the hover hint -- it must come \
            from sidebar.error.dismiss.
            """)
    }

    @Test func jumpRestoreBannerClosesLocallyAndAutoClearsOnItsOwnMessage() throws {
        let bodies = try Self.bannerBodies(of: Self.jumpRestoreBannerDeclaration)
        #expect(bodies.code.contains("jumpRestoreErrorMessage = nil"), """
            jumpRestoreErrorBanner's close button must clear \
            jumpRestoreErrorMessage directly -- it is local @State, not a \
            view-model property, so there is no dismissError() to call here.
            """)
        #expect(bodies.code.contains(".task(id: jumpRestoreErrorMessage)"), """
            jumpRestoreErrorBanner must key its auto-dismiss task on \
            jumpRestoreErrorMessage itself, for the same restart-on-change \
            reason as the group-move banner above.
            """)
        #expect(bodies.code.contains(Self.taskSleep) && bodies.code.contains(Self.delaySymbol), """
            the auto-dismiss task must await Task.sleep(for: \
            Self.errorAutoDismissDelay) -- the same shared constant the \
            group-move banner uses, not a second duration.
            """)
        #expect(bodies.withLiterals.contains(Self.dismissKey), """
            The close button carries no visible text here either -- its \
            catalogue key must also come from sidebar.error.dismiss.
            """)
    }

    /// Both close buttons are icon-only, so they need BOTH `.help` (the
    /// pointer hover hint) and `.accessibilityLabel` (what VoiceOver reads)
    /// -- same pairing `TransferQueueBarCancelGuardTests` holds the row
    /// cancel to, and for the same reason: without the second one, the
    /// button announces itself as the name of an SF Symbol.
    @Test func bothCloseButtonsCarryBothHelpAndAccessibilityLabel() throws {
        for declaration in [Self.groupMoveBannerDeclaration, Self.jumpRestoreBannerDeclaration] {
            let body = try Self.bannerBodies(of: declaration).code
            let carriesHelp = body.contains(Self.helpModifier)
            let carriesAccessibilityLabel = body.contains(Self.accessibilityLabelModifier)
            #expect(carriesHelp, "\(declaration) no longer sets .help(")
            #expect(carriesAccessibilityLabel, "\(declaration) no longer sets .accessibilityLabel(")
        }
    }

    /// The shared delay is a named declaration this suite can point at,
    /// rather than a value it types out and repeats -- CLAUDE.md's rule
    /// that a number written into a comment or a test is a claim to verify,
    /// not evidence, applies to this guard's own expectations too.
    @Test func theSharedDelayIsANamedDurationDeclaration() throws {
        let code = try Self.sidebarViews().code
        #expect(code.contains(Self.delayDeclaration), """
            SessionSidebar.swift no longer declares \
            \(Self.delayDeclaration) -- both banners above are checked \
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
    @Test func bothBannersAreActuallyPlacedInTheSidebar() throws {
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
    }

    /// The negative half: nothing in `SessionSidebar.swift` may block on
    /// `Task.sleep(` except the two banners' own auto-dismiss tasks. A
    /// blocking wait anywhere else in this file would be exactly the shape
    /// CLAUDE.md's "tests never block the cooperative pool" section warns
    /// against, planted in application code rather than a test this time --
    /// and a stray sleep sitting outside a `.task` would run on whatever
    /// context calls it, not cancel when the view disappears the way these
    /// two do. Held to the file by the positive placement check above: if
    /// either banner's declaration went missing, its body would read as
    /// empty and this count would silently balance by finding nothing on
    /// both sides.
    @Test func noTaskSleepAppearsOutsideEitherBannersOwnTask() throws {
        let code = try Self.sidebarViews().code
        let totalSleeps = TransferQueueBarCancelGuardTests.occurrenceCount(
            of: Self.taskSleep, in: code)
        let groupMoveSleeps = TransferQueueBarCancelGuardTests.occurrenceCount(
            of: Self.taskSleep, in: try Self.bannerBodies(of: Self.groupMoveBannerDeclaration).code)
        let jumpRestoreSleeps = TransferQueueBarCancelGuardTests.occurrenceCount(
            of: Self.taskSleep, in: try Self.bannerBodies(of: Self.jumpRestoreBannerDeclaration).code)
        #expect(totalSleeps == groupMoveSleeps + jumpRestoreSleeps, """
            SessionSidebar.swift contains \(totalSleeps) Task.sleep( calls, \
            but only \(groupMoveSleeps + jumpRestoreSleeps) sit inside \
            groupMoveErrorBanner/jumpRestoreErrorBanner's own bodies -- a \
            blocking wait elsewhere in this file would not cancel when its \
            view disappears the way these two do.
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
        let bodies = try Self.bannerBodies(of: Self.groupMoveBannerDeclaration)
        #expect(bodies.code.contains("viewModel.dismissError()"))
        #expect(bodies.code.contains(Self.taskSleep))
        #expect(bodies.code.contains(Self.delaySymbol))
        #expect(bodies.withLiterals.contains(Self.dismissKey))
        let code = try Self.sidebarViews().code
        #expect(code.contains(Self.delayDeclaration))
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
    }
}
