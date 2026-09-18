import Foundation
import MacSCPTestSupport
import Testing

/// Guards "the Settings window can be resized" (next build of 2026-09-17,
/// Task 4, BACKLOG row "A resizable Settings window (maintainer
/// wishlist)"): the root no longer pins a fixed `.frame(width:height:)`,
/// carries a minimum instead, the `Settings` scene is made resizable, and
/// the window remembers its size through an AppKit frame autosave name.
///
/// Every scan here reads the COMMENT-AND-STRING-BLANKED source
/// (`SwiftSource.blankingCommentsAndStrings`) — CLAUDE.md, "Source-scanning
/// guards read comments too": a doc comment that quotes the code it
/// describes reads identically to that code to a scanner that has not
/// blanked comments.
///
/// Every negative check here sits beside a positive one naming the same
/// span (CLAUDE.md, "Guards that name what they watch"): a `!contains` over
/// a span nobody writes to any more reads exactly like a check that is
/// satisfied.
///
/// Known blind spots: SOURCE TEXT only, never a rendered or resized window —
/// nothing here confirms the window actually drags larger on screen, that
/// dragging it persists across a relaunch, or that every pane still lays
/// out at the 680×620 floor; that is the maintainer's sight check (see the
/// task report).
@Suite("Settings window resizability and frame-autosave wiring")
struct SettingsWindowResizableGuardTests {
    /// `#filePath` here is
    /// `<repoRoot>/Tests/macSCPAppKitTests/SettingsWindowResizableGuardTests.swift`;
    /// three `deletingLastPathComponent()` calls recover the repo root
    /// regardless of `swift test`'s working directory.
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let settingsViewFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/SettingsView.swift")
    private static let appFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/MacSCPApp.swift")

    private enum ScanError: Error {
        case declarationNotFound(String)
        case unbalancedBraces(String)
        case unbalancedParens(String)
    }

    /// Everything between `anchor`'s own trailing `(` and its matching `)`,
    /// by plain paren counting — the parenthesis analogue of
    /// `TabsWindowLifecycleTests.body(after:in:)`, which only balances
    /// `{`/`}` and so cannot bound a call like `NSSize(...)` that has none.
    /// `nil` on a missing anchor or unbalanced parens, so a guard built on
    /// this fails closed when the call it names moves, the same as the
    /// brace version.
    private static func parenBody(after anchor: String, in source: String) throws -> String {
        guard let range = source.range(of: anchor) else {
            throw ScanError.declarationNotFound(anchor)
        }
        var depth = 1
        var index = range.upperBound
        let start = index
        while index < source.endIndex {
            switch source[index] {
            case "(": depth += 1
            case ")":
                depth -= 1
                if depth == 0 { return String(source[start..<index]) }
            default: break
            }
            index = source.index(after: index)
        }
        throw ScanError.unbalancedParens(anchor)
    }

    private static func strict(_ file: URL) throws -> String {
        try SwiftSource.blankingCommentsAndStrings(try String(contentsOf: file, encoding: .utf8))
    }

    /// `SettingsView`'s own `var body: some View` — the FIRST occurrence in
    /// the file (every section struct below it declares its own `body` too,
    /// but this one is the root, and `declarationBodyRange` matches the
    /// first occurrence of its `declaration` text).
    private static func settingsViewRootBody() throws -> String {
        let code = try strict(settingsViewFile)
        return try TransferQueueBarCancelGuardTests.declarationBody(
            of: "var body: some View", in: code)
    }

    /// The text right after the `Settings { … }` scene's own closing brace,
    /// up to `window` characters — where `.windowResizability(…)` must be
    /// chained for it to apply to the SETTINGS window rather than whatever
    /// scene follows.
    ///
    /// `Settings { … }` cannot be read with the shared
    /// `declarationBodyRange(of:in:)` helper as-is: that helper expects
    /// `declaration` to stop BEFORE the opening brace and finds the brace
    /// itself, but `Settings {` (a parameterless trailing closure) already
    /// contains its own opening brace as the last character matched — asking
    /// the helper to find the NEXT `{` after that would walk into whatever
    /// code follows the scene instead of balancing the scene's own body. So
    /// this balances from the brace already consumed (`depth` starts at 1),
    /// and returns everything after the matching close.
    private static func textAfterSettingsScene(window: Int = 1200) throws -> Substring {
        let code = try strict(appFile)
        guard let declarationRange = code.range(of: "Settings {") else {
            throw ScanError.declarationNotFound("Settings {")
        }
        var depth = 1
        var index = declarationRange.upperBound
        while index < code.endIndex {
            switch code[index] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    let after = code.index(index, offsetBy: 1)
                    let end = code.index(after, offsetBy: window, limitedBy: code.endIndex) ?? code.endIndex
                    return code[after..<end]
                }
            default: break
            }
            index = code.index(after: index)
        }
        throw ScanError.unbalancedBraces("Settings {")
    }

    /// The `WindowGroup` scene that precedes `Settings { … }` — the main
    /// window's own scene declaration through the start of the Settings
    /// one. Used only to assert `.windowResizability` was NOT left on the
    /// wrong scene.
    private static func windowGroupSceneRegion() throws -> Substring {
        let code = try strict(appFile)
        // `"macSCP"` is a string literal and blanked in the STRICT view
        // this reads (`SwiftSource.blankingCommentsAndStrings` blanks the
        // quotes too, not only their contents), so the anchor is the
        // surrounding call rather than the literal.
        guard let start = code.range(of: "WindowGroup(") else {
            throw ScanError.declarationNotFound("WindowGroup(")
        }
        guard let end = code.range(of: "Settings {", range: start.upperBound..<code.endIndex) else {
            throw ScanError.declarationNotFound("Settings {")
        }
        return code[start.upperBound..<end.lowerBound]
    }

    // MARK: - The root carries a minimum, not a fixed size

    @Test func theRootUsesAMinimumFrameAndNoFixedFrameRemains() throws {
        let source = try Self.strict(Self.settingsViewFile)
        let body = try Self.settingsViewRootBody()
        // Positive: one shared constant (final review Minor 6), declared
        // exactly once, rather than 680×620 spelled twice — the min-frame
        // call below and `contentMinSize` in the WindowAccessor closure
        // must both read it, not carry their own copy of the numbers.
        #expect(
            source.contains("static let minimumSize = CGSize(width: 680, height: 620)"),
            "SettingsView no longer declares a single minimumSize constant — re-anchor this guard")
        #expect(
            body.contains(".frame(minWidth: Self.minimumSize.width, minHeight: Self.minimumSize.height)"),
            "SettingsView's root no longer sizes its minimum frame off Self.minimumSize — re-anchor this guard")
        // Negative beside the positive above: the frame call itself carries
        // no digit literal of its own — a hardcoded 680/620 pair reappearing
        // here is the second copy Minor 6 asked to be removed.
        #expect(
            !body.contains(".frame(minWidth: 680") && !body.contains("minHeight: 620)"),
            "SettingsView's root frame spells 680/620 again instead of reading Self.minimumSize")
        #expect(
            !body.contains(".frame(width:"),
            "a fixed-width .frame(width:…) is back on SettingsView's root — the window cannot resize below it")
    }

    // MARK: - The Settings scene, and only the Settings scene, is resizable

    @Test func theSettingsSceneIsResizableWithAMinimumContentSize() throws {
        let after = try Self.textAfterSettingsScene()
        // Comments between the scene's closing brace and the modifier are
        // blanked to same-length whitespace (`SwiftSource`), not removed —
        // trimming it is what lets a `.frame(width: 680, height: 620)`
        // doc-comment-sized explanation sit there without breaking the
        // "immediately follows" claim this asserts.
        let trimmed = after.drop(while: { $0.isWhitespace })
        #expect(
            trimmed.hasPrefix(".windowResizability(.contentMinSize)"),
            "the Settings scene is no longer immediately followed by .windowResizability(.contentMinSize) — re-anchor this guard")
        let mainWindowRegion = try Self.windowGroupSceneRegion()
        #expect(
            !mainWindowRegion.contains(".windowResizability"),
            "the main window's WindowGroup now carries .windowResizability — it belongs on the Settings scene only")
    }

    // MARK: - The window remembers its size, the simple way

    @Test func theSettingsWindowAutosavesItsFrameWithoutTheMainWindowsSuspendLogic() throws {
        let body = try Self.settingsViewRootBody()
        #expect(
            body.contains("WindowAccessor"),
            "SettingsView's root no longer resolves its NSWindow through WindowAccessor")
        #expect(
            body.contains(".setFrameAutosaveName("),
            "SettingsView's root no longer sets a frame autosave name — the window will not remember its size")
        #expect(
            !body.contains("frameAutosaveSuspended"),
            """
            the Settings window's autosave wiring pulled in the main window's suspend/resume dance \
            (ContentView.frameAutosaveSuspended) — the task brief asks for the simple case: set the \
            name once, when the window first appears
            """)
    }

    // MARK: - The window is ACTUALLY resizable (fix round 1)

    /// Fix round 1 (2026-09-17): the reviewer's scratch app, reproducing
    /// this exact pattern — a `minWidth`/`minHeight` root plus
    /// `.windowResizability(.contentMinSize)` on the `Settings` scene, the
    /// window opened through the real "Settings…" menu item — measured
    /// `resizable == false`, `styleMask == 32771` (titled + closable +
    /// fullSizeContentView, no `.resizable`). SwiftUI's own resizability
    /// modifier does NOT flip that bit for a `Settings` scene; only
    /// inserting `.resizable` into the `NSWindow`'s `styleMask` directly
    /// does (measured: `styleMask == 32779`, `resizable == true` once
    /// added). So this checks the ACTUAL mechanism, not the SwiftUI one
    /// `theSettingsSceneIsResizableWithAMinimumContentSize` above already
    /// covers (and which is kept, but is not sufficient by itself).
    @Test func theWindowAccessorForcesResizableStyleMaskAndContentMinSize() throws {
        let body = try Self.settingsViewRootBody()
        #expect(
            body.contains("styleMask.contains(.resizable)"),
            """
            SettingsView's WindowAccessor no longer guards on whether .resizable is already \
            in styleMask — re-anchor this guard
            """)
        #expect(
            body.contains("styleMask.insert(.resizable)"),
            """
            SettingsView's WindowAccessor no longer inserts .resizable into styleMask — the \
            Settings window reads out resizable == false despite .windowResizability(.contentMinSize) \
            on the Settings scene (measured 2026-09-17, reviewer's scratch app): SwiftUI's own \
            modifier does not do this for a Settings scene
            """)
        #expect(
            body.contains("contentMinSize = "),
            """
            SettingsView's WindowAccessor no longer sets window.contentMinSize — a Settings-scene \
            window made resizable through styleMask needs its own contentMinSize, the SwiftUI frame \
            minimum reaching the window is not enough on its own
            """)
        // The assignment through to its own closing paren, whatever the
        // line-wrapping — found by the anchor every shape of this call
        // shares ("window.contentMinSize = NSSize(") and paren-balanced
        // from there (`parenBody(after:in:)`, above), so reformatting the
        // call does not break this guard the way an exact multi-line
        // string match would.
        let assignment = try Self.parenBody(after: "window.contentMinSize = NSSize(", in: body)
        // Positive: contentMinSize reads the same Self.minimumSize the root
        // frame uses (final review Minor 6) — one constant, not a second
        // 680×620 literal pair that could drift from the first.
        #expect(
            assignment.contains("Self.minimumSize.width") && assignment.contains("Self.minimumSize.height"),
            """
            SettingsView's WindowAccessor no longer builds contentMinSize from Self.minimumSize — \
            re-anchor this guard on wherever it reads the shared constant now
            """)
        // Negative beside the positive above: contentMinSize itself carries
        // no digit literal — a hardcoded 680/620 NSSize reappearing here is
        // the second copy Minor 6 asked to be removed.
        #expect(
            !assignment.contains("680") && !assignment.contains("620"),
            "SettingsView's WindowAccessor spells 680/620 again instead of reading Self.minimumSize")
    }
}
