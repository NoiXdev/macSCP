import Foundation
import Testing

/// Guards the `ContentView`-side half of `hiddenImportsErrorBanner`'s close
/// button (dev-build follow-up, 2026-09-03): `SessionSidebar` cannot clear
/// `hiddenImportsErrorMessage` itself — it reaches the sidebar as a plain
/// `let`, not `@State` — so the actual write has to happen on `ContentView`,
/// the property's real owner, and reach the sidebar through the
/// `onDismissHiddenImportsError` callback `SessionSidebarErrorGuardTests`
/// already holds the BANNER side of to.
///
/// Why this is a separate suite rather than more cases in
/// `SessionSidebarErrorGuardTests`: that file reads exactly one source file
/// (`SessionSidebar.swift`); this one reads two others
/// (`ContentView.swift`, where the clearing method lives, and
/// `ContentView+Detail.swift`, where the callback is wired to it), so the
/// same call to `SwiftSource` there does not cover this half.
///
/// **Why not a behavioral test.** `SessionListViewModelTests
/// .dismissErrorClearsTheMessage` proves `viewModel.dismissError()` by
/// calling it and reading `errorMessage` back — that works because
/// `SessionListViewModel` is a real class. `hiddenImportsErrorMessage` is a
/// `@State var` on `ContentView`, a `View` struct, and a bare, unmounted
/// `ContentView` drops writes to its own `@State`: measured directly (build
/// a `View` with one `@State` property, call a method on it that sets that
/// property, read the property back through the same instance with no
/// SwiftUI hierarchy in between — the read returns the value the property
/// started with, not the one the method wrote), and consistent with what
/// `AlreadyOpenSessionTests` and `ReconnectPathTests` already record about
/// constructing a bare `ContentView` in this exact codebase ("a `ContentView`
/// built outside a SwiftUI hierarchy drops writes to" its `@State`). A test
/// that constructed a `ContentView`, called `dismissHiddenImportsError()`,
/// and asserted `hiddenImportsErrorMessage == nil` would not be reading
/// evidence of anything — the assertion holds whether the method's body is
/// right, wrong, or empty. So this suite proves the SAME property by source
/// scan instead: the method clears the right thing, and the real call site
/// wires the real callback to it.
///
/// Every scan here reads STRIPPED source (`SwiftSource`, comments AND
/// string literals blanked) — a doc comment describing the write, or a
/// string that happens to contain the same characters, cannot satisfy a
/// structural claim.
///
/// Known blind spots: SOURCE TEXT only, never a running window — nothing
/// here can tell whether the button is actually reachable on screen, or
/// whether `dismissHiddenImportsError()` is ever really called by anything
/// other than the wiring this suite reads.
@Suite("Hidden-imports error dismiss (ContentView side)")
struct HiddenImportsErrorDismissGuardTests {
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let contentViewFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/ContentView.swift")
    private static let detailFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/ContentView+Detail.swift")

    private static let dismissMethodDeclaration = "func dismissHiddenImportsError()"
    private static let wiring = "onDismissHiddenImportsError: { dismissHiddenImportsError() }"

    private static func strictSource(of file: URL) throws -> String {
        try SwiftSource.blankingCommentsAndStrings(try String(contentsOf: file, encoding: .utf8))
    }

    // MARK: - The guard

    /// Positive: the method that owns the clear actually clears the right
    /// property, read from its own brace-balanced body rather than a
    /// guessed window — the reason CLAUDE.md gives from the snippets guard.
    @Test func dismissHiddenImportsErrorClearsTheProperty() throws {
        let code = try Self.strictSource(of: Self.contentViewFile)
        let body = try TransferQueueBarCancelGuardTests.declarationBody(
            of: Self.dismissMethodDeclaration, in: code)
        #expect(body.contains("hiddenImportsErrorMessage = nil"), """
            \(Self.dismissMethodDeclaration) must set hiddenImportsErrorMessage \
            = nil -- any other write leaves the caption on screen after its \
            own close button is pressed.
            """)
    }

    /// Positive: the method is declared exactly once, so the body check
    /// above cannot be quietly reading some other declaration of the same
    /// name, and the wiring check below has exactly one real target to name.
    @Test func theDismissMethodIsDeclaredExactlyOnce() throws {
        let code = try Self.strictSource(of: Self.contentViewFile)
        let uses = TransferQueueBarCancelGuardTests.occurrenceCount(
            of: Self.dismissMethodDeclaration, in: code)
        #expect(uses == 1, """
            ContentView.swift must declare \(Self.dismissMethodDeclaration) \
            exactly once -- found \(uses).
            """)
    }

    /// Positive: the sidebar construction in `ContentView+Detail.swift`
    /// actually reaches `dismissHiddenImportsError()` -- a callback with the
    /// right parameter label wired to a DIFFERENT method, or to an inline
    /// `hiddenImportsErrorMessage = nil` that bypasses the named method
    /// entirely, both fail this exact-string match rather than passing on
    /// the strength of the parameter label alone.
    @Test func theSidebarConstructionWiresTheCallbackToTheDismissMethod() throws {
        let code = try Self.strictSource(of: Self.detailFile)
        #expect(code.contains(Self.wiring), """
            ContentView+Detail.swift's SessionSidebar(...) call must pass \
            \(Self.wiring) -- found no exact match, so either the parameter \
            is missing, or it reaches something other than \
            dismissHiddenImportsError().
            """)
    }

    /// What every check above would be worth nothing without: the strict
    /// view must actually be reaching both real files.
    @Test func theStrictViewsStillContainTheRealFiles() throws {
        let contentViewCode = try Self.strictSource(of: Self.contentViewFile)
        #expect(contentViewCode.contains("struct ContentView"), """
            the strict view of ContentView.swift no longer contains the \
            struct's own declaration -- the stripper or the path is wrong.
            """)
        let detailCode = try Self.strictSource(of: Self.detailFile)
        #expect(detailCode.contains("extension ContentView"), """
            the strict view of ContentView+Detail.swift no longer contains \
            its own extension declaration -- the stripper or the path is \
            wrong.
            """)
    }

    // MARK: - The scanner reacts (self-tests over synthetic sources)

    /// The needles the negative self-tests below use are the same strings
    /// the real-file checks read, so a needle can never name something that
    /// appears nowhere in the tree.
    @Test func theSelfTestNeedlesAreThingsTheRealFilesActuallyContain() throws {
        let contentViewCode = try Self.strictSource(of: Self.contentViewFile)
        let body = try TransferQueueBarCancelGuardTests.declarationBody(
            of: Self.dismissMethodDeclaration, in: contentViewCode)
        #expect(body.contains("hiddenImportsErrorMessage = nil"))
        let detailCode = try Self.strictSource(of: Self.detailFile)
        #expect(detailCode.contains(Self.wiring))
    }

    /// A method with the right name that clears something ELSE must be
    /// reported as not clearing `hiddenImportsErrorMessage`, not waved
    /// through because a method with the right name exists.
    @Test func scannerSeesADismissMethodThatClearsTheWrongProperty() throws {
        let source = """
            struct ContentView: View {
                \(Self.dismissMethodDeclaration) {
                    jumpRestoreErrorMessage = nil
                }
            }
            """
        let code = try SwiftSource.blankingCommentsAndStrings(source)
        let body = try TransferQueueBarCancelGuardTests.declarationBody(
            of: Self.dismissMethodDeclaration, in: code)
        // Positive first: the method really is there and really does clear
        // SOMETHING, so the negative below reports the wrong property, not
        // an empty read.
        #expect(body.contains("= nil"))
        #expect(!body.contains("hiddenImportsErrorMessage = nil"), """
            the scanner must report a dismiss method that clears a different \
            property as not clearing hiddenImportsErrorMessage, not accept \
            it because SOME "= nil" is present
            """)
    }

    /// A callback wired to a different method (or inlined instead of
    /// calling the named one) must be reported as not reaching
    /// `dismissHiddenImportsError()`, not accepted because SOME
    /// `onDismissHiddenImportsError:` argument is present.
    @Test func scannerSeesTheCallbackWiredToADifferentTarget() throws {
        let source = """
            SessionSidebar(
                hiddenImportsErrorMessage: hiddenImportsErrorMessage,
                onDismissHiddenImportsError: { hiddenImportsErrorMessage = nil },
                showsTagFilterBar: settingsStore.sidebarTagFilterEnabled
            )
            """
        let code = try SwiftSource.blankingCommentsAndStrings(source)
        // Positive first: the parameter label really is present, so the
        // negative below reports the wrong target specifically.
        #expect(code.contains("onDismissHiddenImportsError:"))
        #expect(!code.contains(Self.wiring), """
            the scanner must report a callback that bypasses \
            dismissHiddenImportsError() as not wired to it, not accept it \
            because SOME onDismissHiddenImportsError: argument is present
            """)
    }

    /// Fail closed: an unreadable/renamed declaration throws rather than
    /// reporting a caption that no longer has a way to close.
    @Test func scannerFailsClosedWhenTheDismissMethodIsGone() {
        let source = "struct ContentView: View { var body: some View { EmptyView() } }"
        #expect(throws: (any Error).self) {
            try TransferQueueBarCancelGuardTests.declarationBody(
                of: Self.dismissMethodDeclaration, in: source)
        }
    }
}
