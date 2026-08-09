import Foundation
import Testing
@testable import MacSCPAppKit

// `ExternalTerminalLauncher` is `@MainActor` as a whole (it wraps
// `NSWorkspace`), and neither tested member is marked `nonisolated`, so
// both `isValidCustomApp(atPath:)` and `sweepOrphanedTempDirectories(root:)`
// are main-actor-isolated. This suite must be `@MainActor` too, or every
// synchronous call site below fails to compile.
@Suite("ExternalTerminalLauncher")
@MainActor
struct ExternalTerminalLauncherTests {
    /// No path means no custom app — the settings UI must not accept an
    /// empty choice as valid.
    @Test func noPathIsNotAValidCustomApp() {
        #expect(ExternalTerminalLauncher.isValidCustomApp(atPath: nil) == false)
        #expect(ExternalTerminalLauncher.isValidCustomApp(atPath: "") == false)
    }

    /// A path to something that does not exist is not valid, however
    /// plausible it looks.
    @Test func aMissingPathIsNotAValidCustomApp() {
        #expect(
            ExternalTerminalLauncher.isValidCustomApp(
                atPath: "/Applications/\(UUID().uuidString).app") == false)
    }

    /// The sweep removes leftover directories under the root it is given —
    /// and must tolerate a root that does not exist at all, which is the
    /// normal state on a machine that never used the feature.
    @Test func sweepingAMissingRootIsHarmless() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macSCP-sweep-\(UUID().uuidString)")

        ExternalTerminalLauncher.sweepOrphanedTempDirectories(root: root)

        #expect(FileManager.default.fileExists(atPath: root.path) == false)
    }

    /// A populated root is cleared. The assertion is on the leftover being
    /// gone, not on the root itself — the sweep is free to remove or keep
    /// the root, and pinning that would over-specify it.
    @Test func sweepingRemovesALeftoverDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macSCP-sweep-\(UUID().uuidString)")
        let leftover = root.appendingPathComponent("orphan")
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        ExternalTerminalLauncher.sweepOrphanedTempDirectories(root: root)

        #expect(FileManager.default.fileExists(atPath: leftover.path) == false)
    }
}
