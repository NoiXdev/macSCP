import Foundation
import Testing

/// Guards that `ConnectionFormView`'s field area scrolls independently of
/// its footer (dev-build follow-up, 2026-09-04): on a short window the
/// lower fields used to run off the bottom of the form with no way to reach
/// them, while `SessionSidebar`'s own `List` already scrolled. The fix
/// wraps the fields in a `ScrollView(.vertical)` inside `body` and keeps the
/// footer's Back/Save/Save & connect/Connect row a sibling OUTSIDE it, so
/// those buttons stay reachable at any window height. This suite is the
/// wiring half of that: which region of `body` sits inside the scroll
/// boundary, and which sits outside it.
///
/// Every check reads STRIPPED source (`SwiftSource`): the strict view
/// (comments AND string literals blanked) for the structural claims — a
/// `ScrollView` exists, wraps the fields, and does not wrap the footer — and
/// the comments-only view for the footer buttons' own catalogue keys, which
/// the strict view would have blanked away along with everything else.
///
/// Reused rather than copied: `TransferQueueBarCancelGuardTests
/// .declarationBodyRange(of:in:)`/`.slice(_:of:)` for the brace-balanced
/// spans (`body` itself, and `ScrollView(`'s own trailing closure inside
/// it), and `DiagnosticsDoorsGuardTests.matches(of:in:)` to derive the
/// footer buttons' catalogue keys from the source instead of re-spelling
/// them here — a second, hand-typed copy of a catalogue key is exactly what
/// this project's rules about second copies are about.
///
/// ## The negative check has a positive partner beside it
///
/// CLAUDE.md, "Guards that name what they watch": a check that no footer key
/// appears inside the `ScrollView` span would pass trivially over a body
/// that lost the footer altogether, or over a derivation that silently
/// found zero keys. `theFooterKeysActuallyOccurInBody` is that positive
/// partner — it fails first, and loudly, if either happens.
///
/// Known blind spots: SOURCE TEXT only. Nothing here confirms the fields
/// actually scroll on screen, that the footer stays pinned at the bottom of
/// the window, or that a keyboard focus move reveals a clipped field —
/// only which expressions the source places inside or outside the
/// `ScrollView`'s own body.
@Suite("Connection form scroll wiring")
struct ConnectionFormScrollGuardTests {
    /// `#filePath` is
    /// `<repoRoot>/Tests/macSCPAppKitTests/ConnectionFormScrollGuardTests.swift`.
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let sourceFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/ConnectionFormView.swift")

    private static let bodyDeclaration = "var body: some View {"
    private static let scrollAnchor = "ScrollView("
    private static let footerAnchor = "HStack {"

    /// The one call that only appears inside the fields area: the
    /// backend-specific block (SSH/S3/WebDAV) the type switcher's picker
    /// selects between. Naming it, rather than a generic `FormRow(`, keeps
    /// this scan pointed at "the fields' builder call" the brief calls out —
    /// a `FormRow(` also appears inside `hostKeyPromptView`'s own footnote
    /// and would not distinguish the two.
    private static let fieldsBuilderCall = "backendSection"

    private static let expectedFooterKeys = [
        "common.back", "common.save", "connection.saveAndConnect", "connection.connect",
    ]

    // MARK: - The scan, generic over its source so the self-tests below

    /// reuse exactly the logic run against the real file.
    private static func views(of source: String) throws -> (code: String, withLiterals: String) {
        (try SwiftSource.blankingCommentsAndStrings(source), try SwiftSource.blankingComments(source))
    }

    /// `body`'s own brace-balanced span, in both views.
    private static func bodySpan(
        of views: (code: String, withLiterals: String)
    ) throws -> (code: String, withLiterals: String) {
        let range = try TransferQueueBarCancelGuardTests.declarationBodyRange(
            of: bodyDeclaration, in: views.code)
        return (TransferQueueBarCancelGuardTests.slice(range, of: views.code),
                TransferQueueBarCancelGuardTests.slice(range, of: views.withLiterals))
    }

    /// `ScrollView(`'s own trailing-closure span, sliced out of an
    /// already-restricted `body` span (so a `ScrollView` anywhere else in
    /// the file — there is none today — could never be mistaken for this
    /// one).
    private static func scrollSpan(
        of body: (code: String, withLiterals: String)
    ) throws -> (code: String, withLiterals: String) {
        let range = try TransferQueueBarCancelGuardTests.declarationBodyRange(
            of: scrollAnchor, in: body.code)
        return (TransferQueueBarCancelGuardTests.slice(range, of: body.code),
                TransferQueueBarCancelGuardTests.slice(range, of: body.withLiterals))
    }

    /// The footer buttons' own catalogue keys, read out of `Button(L10n
    /// .string("key", …))` calls rather than spelled a second time here.
    private static func footerButtonKeys(in bodyWithLiterals: String) -> [String] {
        DiagnosticsDoorsGuardTests.matches(
            of: #"Button\(L10n\.string\("([\w.]+)""#, in: bodyWithLiterals)
    }

    private static func realFileBody() throws -> (code: String, withLiterals: String) {
        let raw = try String(contentsOf: sourceFile, encoding: .utf8)
        return try bodySpan(of: try views(of: raw))
    }

    // MARK: - Positive anchors

    @Test func bodyContainsAScrollView() throws {
        let body = try Self.realFileBody()
        #expect(body.code.contains(Self.scrollAnchor), """
            ConnectionFormView.body no longer contains a ScrollView( — the \
            field area is unscrollable again, so a short window clips the \
            lower fields with no way to reach them.
            """)
    }

    @Test func theScrollViewWrapsTheFieldsBuilderCall() throws {
        let body = try Self.realFileBody()
        let scroll = try Self.scrollSpan(of: body)
        #expect(scroll.code.contains(Self.fieldsBuilderCall), """
            backendSection is no longer inside the ScrollView's own body — \
            either the backend-specific fields (SSH/S3/WebDAV) moved outside \
            the scroll region, or the ScrollView no longer wraps the field \
            area at all.
            """)
    }

    @Test func theFooterRowSitsOutsideTheScrollView() throws {
        let body = try Self.realFileBody()
        let scroll = try Self.scrollSpan(of: body)
        #expect(body.code.contains(Self.footerAnchor), """
            ConnectionFormView.body no longer contains the footer's own \
            HStack { — the Back / Save / Save & connect / Connect row is \
            gone from body.
            """)
        #expect(!scroll.code.contains(Self.footerAnchor), """
            The footer's HStack { is inside the ScrollView's own body — the \
            Back / Save / Save & connect / Connect row would scroll away \
            with the fields instead of staying reachable at any window \
            height.
            """)
    }

    // MARK: - The negative check, and its positive partner

    /// The positive partner CLAUDE.md's "Guards that name what they watch"
    /// asks for beside the negative check below: the four footer keys
    /// really do occur in `body` at all, so a pass below is reporting
    /// "outside the ScrollView, but present" rather than "neither scan
    /// found anything".
    @Test func theFooterKeysActuallyOccurInBody() throws {
        let body = try Self.realFileBody()
        let keys = Self.footerButtonKeys(in: body.withLiterals)
        for expected in Self.expectedFooterKeys {
            #expect(keys.contains(expected), """
                \(expected) is no longer among the catalogue keys a Button( \
                call inside ConnectionFormView.body passes to L10n.string( \
                — either the footer button carrying it is gone, or it moved \
                somewhere this scan does not read literals from. Either way \
                the negative check below would then be satisfied by an \
                empty derivation rather than by the button actually sitting \
                outside the ScrollView.
                """)
        }
    }

    @Test func noFooterButtonKeyIsInsideTheScrollView() throws {
        let body = try Self.realFileBody()
        let scroll = try Self.scrollSpan(of: body)
        let keys = Self.footerButtonKeys(in: body.withLiterals)
        for key in keys {
            #expect(!scroll.withLiterals.contains("\"\(key)\""), """
                \(key) — one of the footer's own catalogue keys — occurs \
                inside the ScrollView's body: that button would scroll away \
                with the fields instead of staying reachable at any window \
                height.
                """)
        }
    }

    // MARK: - The scanner reacts (self-tests over synthetic sources)

    /// The exact violation the two checks above exist to catch: a footer
    /// button's `Button(` call moved inside the `ScrollView`'s own body.
    @Test func scannerCatchesAFooterButtonMovedInsideTheScrollView() throws {
        let source = """
            var body: some View {
                VStack {
                    ScrollView(.vertical) {
                        VStack {
                            backendSection
                            Button(L10n.string("common.back", "Back")) { onCancelEdit() }
                        }
                    }
                    HStack {
                        Button(L10n.string("connection.connect", "Connect")) { }
                    }
                }
            }
            """
        let body = try Self.bodySpan(of: try Self.views(of: source))
        let scroll = try Self.scrollSpan(of: body)
        let keys = Self.footerButtonKeys(in: body.withLiterals)
        // Positive first: the derivation really does find both keys, so the
        // violation below is reported because one sits in the wrong place —
        // not because the derivation found nothing.
        #expect(keys.contains("common.back"))
        #expect(keys.contains("connection.connect"))
        #expect(scroll.withLiterals.contains("\"common.back\""), """
            this synthetic source moved common.back's Button( inside the \
            ScrollView on purpose — if the scan does not see it there, the \
            span it reads is not the one this suite's real checks read.
            """)
    }

    /// A comment quoting the footer's own catalogue key, sitting inside the
    /// `ScrollView`, must not be mistaken for the button itself (CLAUDE.md,
    /// "Source-scanning guards read comments too") — the comments-only view
    /// keeps literals but blanks comments, so a quoted key inside a comment
    /// does not satisfy `noFooterButtonKeyIsInsideTheScrollView`.
    @Test func aCommentQuotingAFooterKeyInsideTheScrollViewDoesNotSatisfyTheGuard() throws {
        let source = """
            var body: some View {
                VStack {
                    ScrollView(.vertical) {
                        VStack {
                            backendSection
                            // Unlike the removed prototype, common.back is not wired here.
                        }
                    }
                    HStack {
                        Button(L10n.string("common.back", "Back")) { onCancelEdit() }
                    }
                }
            }
            """
        let body = try Self.bodySpan(of: try Self.views(of: source))
        let scroll = try Self.scrollSpan(of: body)
        #expect(!scroll.withLiterals.contains("\"common.back\""), """
            the comments-only view must blank the comment quoting \
            common.back — a scan reading the raw file would find the \
            substring inside the ScrollView's span and misreport the \
            button as misplaced when it is correctly outside.
            """)
    }

    @Test func scannerFailsClosedWhenTheScrollViewIsGone() throws {
        let source = """
            var body: some View {
                VStack {
                    VStack {
                        backendSection
                    }
                    HStack {
                        Button(L10n.string("common.back", "Back")) { onCancelEdit() }
                    }
                }
            }
            """
        let body = try Self.bodySpan(of: try Self.views(of: source))
        #expect(throws: (any Error).self) {
            try Self.scrollSpan(of: body)
        }
    }
}
