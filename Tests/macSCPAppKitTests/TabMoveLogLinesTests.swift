import Foundation
import Testing

@testable import MacSCPAppKit
@testable import macSCPCore

/// Pins the two "app"-category lines `ContentView.moveToNewWindow`,
/// `ContentView.releaseUnclaimedSeedsOnClose()`, and `AppDelegate
/// .sweepUnclaimedMoves()` write about a moved tab — none of which a test
/// can drive directly (Views and `NSApplicationDelegate` methods, in a
/// project with no SwiftUI rendering harness). `TabMoveLogLines` is where
/// those three sites' text actually lives, so this suite exercises it
/// directly rather than through any of them (Detachable Tabs plan, Task 6
/// closeout — deferred from Task 2 round 3, "no test pins the two log
/// lines' text").
///
/// A private `DiagnosticLog()` instance, not `.shared`: nothing here needs
/// the process-wide singleton, and `DiagnosticLogSharedSinkIsolationGuardTests`
/// reserves `DiagnosticLog.shared` as code for `DiagnosticLogSharedSinkTests
/// .swift` alone.
@Suite("Tab move log lines")
struct TabMoveLogLinesTests {
    private func makeTempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "TabMoveLogLinesTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func fileContents(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    @Test func parkedNamesTheSeedAndItsTabCount() {
        let seedID = UUID()
        #expect(
            TabMoveLogLines.parked(seedID: seedID, tabCount: 1)
                == "window move parked seed=\(seedID) tabs=1")
        #expect(
            TabMoveLogLines.parked(seedID: seedID, tabCount: 3)
                == "window move parked seed=\(seedID) tabs=3")
    }

    @Test func tornDownUnclaimedNamesTheSeed() {
        let seedID = UUID()
        #expect(
            TabMoveLogLines.tornDownUnclaimed(seedID: seedID)
                == "window move torn down unclaimed seed=\(seedID)")
    }

    /// The "sink instance" half: both lines, written through a real
    /// `DiagnosticLog`, land in its file byte for byte — proving the
    /// format survives the sink's own line-writing path, not just string
    /// concatenation in isolation.
    @Test func bothLinesReachTheSinkVerbatim() async throws {
        let log = DiagnosticLog()
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        log.configure(level: .info, directory: directory)

        let parkedSeedID = UUID()
        let tornDownSeedID = UUID()
        log.log(.info, "app", TabMoveLogLines.parked(seedID: parkedSeedID, tabCount: 2))
        log.log(.info, "app", TabMoveLogLines.tornDownUnclaimed(seedID: tornDownSeedID))
        await log.flush()

        let url = try #require(log.currentFileURL)
        let contents = fileContents(url)
        #expect(contents.contains("window move parked seed=\(parkedSeedID) tabs=2"))
        #expect(contents.contains("window move torn down unclaimed seed=\(tornDownSeedID)"))
    }
}
