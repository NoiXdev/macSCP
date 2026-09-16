import Foundation
import MacSCPTestSupport
import Testing
import macSCPCore

@testable import MacSCPAppKit

/// A forwarding that stays up while some of its connections could not be
/// carried says so: "Active · N connections failed" as its state, and the
/// last failure — translated from its kind — in the tooltip. With no failure
/// it renders exactly as it did before the count existed.
@MainActor @Suite struct TunnelActiveFailuresLabelTests {
    private static let sentinel = "ZZ-UNRESOLVED-ZZ"
    private static let countKey = "tunnel.state.activeWithFailures %lld"
    private static let lastFailureKey = "tunnel.state.lastFailure %@"

    private static let appKitRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/MacSCPAppKit")

    @Test func noFailureRendersAsBefore() {
        let idle = TunnelState.active(connections: 0, failedConnections: 0, lastFailure: nil)
        #expect(TunnelProfilesSheet.stateLabel(idle) == L10n.string("tunnel.state.active", Self.sentinel))
        let busy = TunnelState.active(connections: 3)
        #expect(
            TunnelProfilesSheet.stateLabel(busy)
                == String(format: L10n.string("tunnel.state.activeConnections %lld", Self.sentinel), 3))
        #expect(TunnelProfilesSheet.stateTooltip(idle) == TunnelProfilesSheet.stateLabel(idle))
        #expect(TunnelProfilesSheet.stateTooltip(busy) == TunnelProfilesSheet.stateLabel(busy))
    }

    @Test(arguments: [1, 5])
    func theCountIsTheLabel(_ count: Int) {
        let template = L10n.string(Self.countKey, Self.sentinel)
        #expect(template != Self.sentinel)
        let state = TunnelState.active(
            connections: 2, failedConnections: count, lastFailure: .channelOpenFailed)
        #expect(TunnelProfilesSheet.stateLabel(state) == String(format: template, count))
    }

    /// The plural is real: one failure and five read differently once the
    /// digits are gone, in whatever language the test process resolves.
    @Test func oneAndFiveAreWordedDifferently() {
        func words(_ count: Int) -> String {
            TunnelProfilesSheet.stateLabel(
                .active(connections: 0, failedConnections: count, lastFailure: .connectFailed)
            ).filter { !$0.isNumber }
        }
        #expect(words(1) != words(5))
    }

    @Test func theTooltipCarriesTheTranslatedLastFailure() {
        let template = L10n.string(Self.lastFailureKey, Self.sentinel)
        #expect(template != Self.sentinel)
        let state = TunnelState.active(
            connections: 1, failedConnections: 5, lastFailure: .connectFailed)
        let tooltip = TunnelProfilesSheet.stateTooltip(state)
        #expect(tooltip.hasPrefix(TunnelProfilesSheet.stateLabel(state)))
        #expect(
            tooltip.contains(
                String(format: template, TunnelProfilesSheet.failureLabel(.connectFailed))))
    }

    /// All four surfaces that show a forwarding's state as a tooltip read
    /// `stateTooltip`, so the last failure reaches every one of them.
    /// Spelled per file because the profiles sheet DECLARES the function:
    /// a bare `stateTooltip(` would find the declaration there and pass.
    @Test(arguments: [
        ("TunnelProfilesSheet.swift", ".help(Self.stateTooltip("),
        ("TunnelAutostartSheet.swift", ".help(TunnelProfilesSheet.stateTooltip("),
        ("TunnelDockPresence.swift", "toolTip = TunnelProfilesSheet.stateTooltip("),
        ("SessionSidebar.swift", "TunnelProfilesSheet.stateTooltip("),
    ])
    func everyStateSurfaceReadsTheTooltip(_ file: String, _ use: String) throws {
        let raw = try String(
            contentsOf: Self.appKitRoot.appendingPathComponent(file), encoding: .utf8)
        let code = try SwiftSource.blankingCommentsAndStrings(raw)
        #expect(code.contains(use), "\(file) does not show the state's tooltip")
    }
}
