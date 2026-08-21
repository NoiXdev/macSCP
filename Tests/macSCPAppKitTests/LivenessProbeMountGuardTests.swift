import Foundation
import Testing

/// Guards WHERE `LivenessProbeRunner` is mounted (connection-liveness plan,
/// Task 4, fix rounds 2 and 3) — inside `ContentView.splitLayout`, which
/// exists in the tree regardless of which tab is active, and never inside
/// `ContentView.detail`, which SwiftUI mounts only for the active tab; and
/// that `splitLayout` asks `LivenessProbeCoverage.tabsToProbe` for WHICH
/// tabs to mount one for, rather than building the `ForEach` list itself.
///
/// That placement IS the fix for "only the active tab was probed" (fix
/// round 1): `LivenessProbeWiringGuardTests` already pins the probe loop's
/// own internal shape (interval read fresh, decision through
/// `LivenessProbePolicy`, `.giveUp` delegated to `onGiveUp`), but nothing
/// before this file pinned WHERE the view carrying that loop is mounted. A
/// mount moved from `splitLayout` back into `detail` would still spell
/// `LivenessProbeRunner(` correctly, still pass every existing guard, and
/// still pass the whole suite — while silently reintroducing the exact bug
/// fix round 1 closed. Proving a call exists is not the same as proving it
/// exists in a place that runs for every tab; this guard is the second
/// half `LivenessProbeWiringGuardTests` cannot provide on its own.
///
/// This is still only half of THAT story, though: a fix-round-2 reviewer
/// showed that wrapping the mount in `if tab.id == tabsModel.activeTabID`
/// while leaving it textually inside `splitLayout`'s `.background` passes
/// every one of THESE tests too — a source scan can prove the view calls
/// `LivenessProbeCoverage.tabsToProbe(`, but not that nothing narrows what
/// comes back afterward. `LivenessProbeCoverageTests` is what actually
/// pins WHICH tabs get covered, on a value this project can run in a test;
/// this suite's newest claim only pins that `splitLayout` asks that value at all,
/// rather than deciding coverage inline the way it used to.
///
/// Same boundary as this project's other wiring guards: a SOURCE-TEXT scan,
/// not a behavioral test — this project has no SwiftUI rendering harness,
/// so which property's body a view sits in can only be checked by reading
/// it. Fail-closed: an unreadable file, a missing anchor, a non-unique
/// anchor, or an unbalanced brace all count as failures. Self-tested
/// against synthetic source, so the guard cannot pass silently just
/// because the real file moved or was reformatted past recognition.
@Suite("Liveness probe mount placement guard")
struct LivenessProbeMountGuardTests {
    /// `#filePath` here is
    /// `<repoRoot>/Tests/macSCPAppKitTests/LivenessProbeMountGuardTests.swift`;
    /// three `deletingLastPathComponent()` calls recover the repo root
    /// regardless of `swift test`'s working directory (same trick as
    /// `LivenessProbeWiringGuardTests`).
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let detailFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/ContentView+Detail.swift")

    private static let mountCall = "LivenessProbeRunner("
    private static let coverageCall = "LivenessProbeCoverage.tabsToProbe("
    private static let splitLayoutAnchor = "var splitLayout: some View {"
    private static let detailAnchor = "var detail: some View {"

    private enum ScanError: Error { case anchorNotFound, unbalancedBraces }

    // MARK: - The guarded placement, run against the real file

    @Test func theRunnerIsMountedInSplitLayout() throws {
        let source = try String(contentsOf: Self.detailFile, encoding: .utf8)
        let body = try Self.propertyBody(after: Self.splitLayoutAnchor, in: source)
        #expect(body.contains(Self.mountCall), """
            `ContentView.splitLayout`'s body no longer mounts \
            `\(Self.mountCall)` — `splitLayout` exists for the whole window \
            regardless of which tab is active, which is what makes every \
            connected tab's probe run, not only the active one.
            """)
    }

    @Test func theRunnerIsNotMountedInDetail() throws {
        let source = try String(contentsOf: Self.detailFile, encoding: .utf8)
        let body = try Self.propertyBody(after: Self.detailAnchor, in: source)
        #expect(!body.contains(Self.mountCall), """
            `ContentView.detail`'s body now mounts `\(Self.mountCall)` — \
            SwiftUI mounts `detail` only for the active tab, so a probe \
            mounted there would silently stop running for every background \
            tab again, the exact bug fix round 1 closed.
            """)
    }

    @Test func theSplitLayoutAsksLivenessProbeCoverage() throws {
        let source = try String(contentsOf: Self.detailFile, encoding: .utf8)
        let body = try Self.propertyBody(after: Self.splitLayoutAnchor, in: source)
        #expect(body.contains(Self.coverageCall), """
            `ContentView.splitLayout`'s body no longer calls             `\(Self.coverageCall)` — building the mounted tab list some             other way here would make coverage a decision this view makes             again, unobservable by `LivenessProbeCoverageTests`.
            """)
    }

    /// Fail-closed check, same reasoning as this project's other wiring
    /// guards: if either anchor ever stops being unique, this suite's
    /// placement claims could be scanning the wrong property silently.
    @Test func bothAnchorsAppearExactlyOnceInTheRealFile() throws {
        let source = try String(contentsOf: Self.detailFile, encoding: .utf8)
        let splitLayoutCount = source.components(separatedBy: Self.splitLayoutAnchor).count - 1
        let detailCount = source.components(separatedBy: Self.detailAnchor).count - 1
        #expect(splitLayoutCount == 1, """
            expected exactly 1 occurrence of `\(Self.splitLayoutAnchor)` in \
            ContentView+Detail.swift, found \(splitLayoutCount) — re-anchor \
            this guard.
            """)
        #expect(detailCount == 1, """
            expected exactly 1 occurrence of `\(Self.detailAnchor)` in \
            ContentView+Detail.swift, found \(detailCount) — re-anchor this \
            guard.
            """)
    }

    // MARK: - Scanner self-tests (synthetic source, so the scanner cannot
    // silently pass just because the real file moved or failed to read)

    @Test func scannerFlagsTheRunnerMountedInDetailInstead() throws {
        let source = """
            var splitLayout: some View {
                HSplitView { detail }
            }

            var detail: some View {
                Group {
                    LivenessProbeRunner(tab: tab, settingsStore: settingsStore, onGiveUp: onGiveUp)
                }
            }
            """
        let splitLayoutBody = try Self.propertyBody(after: Self.splitLayoutAnchor, in: source)
        let detailBody = try Self.propertyBody(after: Self.detailAnchor, in: source)
        #expect(!splitLayoutBody.contains(Self.mountCall))
        #expect(detailBody.contains(Self.mountCall))
    }

    @Test func scannerAcceptsTheRunnerMountedInSplitLayout() throws {
        let source = """
            var splitLayout: some View {
                HSplitView { detail }
                .background {
                    ForEach(LivenessProbeCoverage.tabsToProbe(from: tabsModel.tabs)) { tab in
                        LivenessProbeRunner(tab: tab, settingsStore: settingsStore, onGiveUp: onGiveUp)
                    }
                }
            }

            var detail: some View {
                Group { EmptyView() }
            }
            """
        let splitLayoutBody = try Self.propertyBody(after: Self.splitLayoutAnchor, in: source)
        let detailBody = try Self.propertyBody(after: Self.detailAnchor, in: source)
        #expect(splitLayoutBody.contains(Self.mountCall))
        #expect(splitLayoutBody.contains(Self.coverageCall))
        #expect(!detailBody.contains(Self.mountCall))
    }

    @Test func scannerFlagsSplitLayoutBuildingItsOwnTabList() throws {
        let source = """
            var splitLayout: some View {
                HSplitView { detail }
                .background {
                    ForEach(tabsModel.tabs) { tab in
                        LivenessProbeRunner(tab: tab, settingsStore: settingsStore, onGiveUp: onGiveUp)
                    }
                }
            }
            """
        let splitLayoutBody = try Self.propertyBody(after: Self.splitLayoutAnchor, in: source)
        #expect(!splitLayoutBody.contains(Self.coverageCall))
    }

    @Test func scannerThrowsWhenTheAnchorIsMissing() {
        let source = "var somethingElse: some View { EmptyView() }"
        #expect(throws: ScanError.anchorNotFound) {
            _ = try Self.propertyBody(after: Self.splitLayoutAnchor, in: source)
        }
    }

    // MARK: - Scanner
    //
    // Anchors on the property declaration's own text (through its opening
    // `{`), then depth-counts braces to the matching close — the same
    // brace-matching technique `LivenessProbeWiringGuardTests.loopBody`
    // uses for a `while` block, applied here to a computed property's whole
    // body instead.

    /// The text between a property declaration's own opening `{` (the
    /// anchor's last character) and its balanced-brace close. Throws rather
    /// than returning `nil` so a missing anchor or an unbalanced file fails
    /// the calling test loudly, not as a silently-empty string that would
    /// make every `contains` check in the calling tests trivially false.
    private static func propertyBody(after anchor: String, in source: String) throws -> String {
        guard let anchorRange = source.range(of: anchor) else { throw ScanError.anchorNotFound }
        let afterAnchor = source[anchorRange.upperBound...]
        // The anchor's own trailing "{" already opened depth 1 — this scan
        // starts counting from there, so a "}" seen at depth 1 is that same
        // opening brace's match.
        var depth = 1
        var index = afterAnchor.startIndex
        while index < afterAnchor.endIndex {
            let character = afterAnchor[index]
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(afterAnchor[afterAnchor.startIndex..<index])
                }
            }
            index = afterAnchor.index(after: index)
        }
        throw ScanError.unbalancedBraces
    }
}
