import Foundation
import Testing

/// Guards ONE property of `TabStripView.swift`'s `livenessDot` (connection-
/// liveness plan, Task 5): three claims about the view code, each checked by
/// scanning source text rather than by running it — this project has no
/// SwiftUI rendering harness (same boundary as `LivenessProbeWiringGuardTests`
/// and `ConnectTimeoutAppWiringGuardTests`; see either's doc comment for the
/// same idiom), so a computed `View` property's shape can only be checked by
/// reading it, not by rendering it.
///
/// 1. The dot reads `tab.liveness` through `LivenessDotPlan.appearance(for:)`
///    — not some parallel condition reimplementing that mapping inline,
///    which could silently drift from `LivenessDotPlanTests`' pinned cases.
/// 2. The dot carries both a `.help` tooltip and an `.accessibilityLabel` —
///    colour is never the only carrier of the message; a dot with only one
///    of the two would be readable by a mouse user or a VoiceOver user, but
///    not both.
/// 3. The dot's color comes from `LivenessDotPlan`'s `Appearance`, not from
///    a color literal (`.red`, `.orange`, `.green`, `Color(`, `NSColor(`)
///    written directly in the view — literals here are exactly what
///    `DesignTokens` exists to centralize.
///
/// Fail-closed: an unreadable file, a missing anchor, or an unbalanced brace
/// all count as failures. Self-tested against synthetic source, so the guard
/// cannot pass silently just because the real file moved, was reformatted
/// past recognition, or failed to read.
@Suite("Liveness dot wiring guard")
struct LivenessDotWiringGuardTests {
    /// `#filePath` here is
    /// `<repoRoot>/Tests/macSCPAppKitTests/LivenessDotWiringGuardTests.swift`;
    /// three `deletingLastPathComponent()` calls recover the repo root
    /// regardless of `swift test`'s working directory (same trick as
    /// `LivenessProbeWiringGuardTests`).
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let tabStripFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/TabStripView.swift")

    /// Anchors the `livenessDot` property, unique in the file (checked by
    /// `theAnchorAppearsExactlyOnceInTheRealFile`).
    private static let anchor = "// Liveness dot (connection-liveness plan, Task 5)"

    private static let forbiddenColorLiterals = [".red", ".orange", ".green", "Color(", "NSColor("]

    private enum ScanError: Error { case anchorNotFound, openBraceNotFound, unbalancedBraces }

    // MARK: - The three guarded claims, run against the real file

    @Test func theDotReadsTabLivenessThroughThePlan() throws {
        let source = try String(contentsOf: Self.tabStripFile, encoding: .utf8)
        let body = try Self.propertyBody(after: Self.anchor, in: source)
        #expect(body.contains("LivenessDotPlan.appearance(for: tab.liveness)"), """
            `livenessDot` no longer calls `LivenessDotPlan.appearance(for: tab.liveness)` — \
            a condition reimplemented inline here could drift from the pinned mapping in \
            `LivenessDotPlanTests` without either suite noticing.
            """)
    }

    @Test func theDotCarriesBothHelpAndAccessibilityLabel() throws {
        let source = try String(contentsOf: Self.tabStripFile, encoding: .utf8)
        let body = try Self.propertyBody(after: Self.anchor, in: source)
        #expect(body.contains(".help("), """
            `livenessDot` no longer sets `.help(` — colour would be the only carrier of the \
            message for a mouse/trackpad user, exactly what this dot exists to avoid.
            """)
        #expect(body.contains(".accessibilityLabel("), """
            `livenessDot` no longer sets `.accessibilityLabel(` — colour would be the only \
            carrier of the message under VoiceOver.
            """)
    }

    @Test func theDotsColorHasNoLiteralInTheView() throws {
        let source = try String(contentsOf: Self.tabStripFile, encoding: .utf8)
        let body = try Self.propertyBody(after: Self.anchor, in: source)
        for literal in Self.forbiddenColorLiterals {
            #expect(!body.contains(literal), """
                `livenessDot` contains the color literal `\(literal)` — colors belong in \
                `DesignTokens`, not inlined in the view body.
                """)
        }
    }

    /// Fail-closed check, same reasoning as
    /// `LivenessProbeWiringGuardTests.theAnchorAppearsExactlyOnceInTheRealFile`:
    /// if the anchor ever stops being unique, the three claims above could be
    /// scanning the wrong property silently.
    @Test func theAnchorAppearsExactlyOnceInTheRealFile() throws {
        let source = try String(contentsOf: Self.tabStripFile, encoding: .utf8)
        let count = source.components(separatedBy: Self.anchor).count - 1
        #expect(count == 1, """
            expected exactly 1 occurrence of `\(Self.anchor)` in TabStripView.swift, found \
            \(count) — re-anchor this guard.
            """)
    }

    // MARK: - Scanner self-tests (synthetic source, so the scanner cannot
    // silently pass just because the real file moved or failed to read)

    @Test func scannerAcceptsAPropertyThatDelegatesToThePlan() throws {
        let source = """
            // Liveness dot (connection-liveness plan, Task 5)
            private var livenessDot: some View {
                if let appearance = LivenessDotPlan.appearance(for: tab.liveness) {
                    Circle().fill(appearance.color).help("x").accessibilityLabel("y")
                }
            }
            """
        let body = try Self.propertyBody(after: Self.anchor, in: source)
        #expect(body.contains("LivenessDotPlan.appearance(for: tab.liveness)"))
    }

    @Test func scannerFlagsAnInlineReimplementation() throws {
        let source = """
            // Liveness dot (connection-liveness plan, Task 5)
            private var livenessDot: some View {
                if tab.liveness == .lost {
                    Circle().fill(.red)
                }
            }
            """
        let body = try Self.propertyBody(after: Self.anchor, in: source)
        #expect(!body.contains("LivenessDotPlan.appearance(for: tab.liveness)"))
        #expect(body.contains(".red"))
    }

    @Test func scannerFlagsAMissingAccessibilityLabel() throws {
        let source = """
            // Liveness dot (connection-liveness plan, Task 5)
            private var livenessDot: some View {
                if let appearance = LivenessDotPlan.appearance(for: tab.liveness) {
                    Circle().fill(appearance.color).help("x")
                }
            }
            """
        let body = try Self.propertyBody(after: Self.anchor, in: source)
        #expect(!body.contains(".accessibilityLabel("))
    }

    @Test func scannerThrowsWhenTheAnchorIsMissing() {
        let source = "private var livenessDot: some View { EmptyView() }"
        #expect(throws: ScanError.anchorNotFound) {
            _ = try Self.propertyBody(after: Self.anchor, in: source)
        }
    }

    // MARK: - Scanner
    //
    // Anchors on the comment marker itself, then depth-counts braces from
    // the property's own opening `{` to its matching close — the same
    // brace-matching technique `LivenessProbeWiringGuardTests` uses for a
    // `while` block, applied here to a computed property instead.

    /// The `livenessDot` property's body text: everything between its own
    /// opening `{` (the first one found after `anchor`) and its balanced-
    /// brace close. Throws rather than returning `nil` so a missing anchor
    /// or an unbalanced file fails the calling test loudly, not as a
    /// silently-empty string that would make every `contains` check in the
    /// calling tests trivially false.
    private static func propertyBody(after anchor: String, in source: String) throws -> String {
        guard let anchorRange = source.range(of: anchor) else { throw ScanError.anchorNotFound }
        let afterAnchor = source[anchorRange.upperBound...]
        guard let openBraceIndex = afterAnchor.firstIndex(of: "{") else {
            throw ScanError.openBraceNotFound
        }
        var depth = 0
        var index = openBraceIndex
        while index < afterAnchor.endIndex {
            let character = afterAnchor[index]
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth == 0 {
                    let bodyStart = afterAnchor.index(after: openBraceIndex)
                    return String(afterAnchor[bodyStart..<index])
                }
            }
            index = afterAnchor.index(after: index)
        }
        throw ScanError.unbalancedBraces
    }
}
