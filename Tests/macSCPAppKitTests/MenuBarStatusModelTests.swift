import Foundation
import Testing
@testable import MacSCPAppKit
@testable import macSCPCore

@Suite("MenuBarStatusModel")
@MainActor
struct MenuBarStatusModelTests {
    private func makeTab() -> SessionTab {
        SessionTab(
            connectionViewModel: ConnectionViewModel(connector: { _, _ in
                // Never called: none of these tests connects. A throwing
                // stub is the smallest value that satisfies the signature.
                throw CancellationError()
            }),
            certificateBridge: CertificatePromptBridge(),
            limiter: BandwidthLimiter(),
            maxConcurrent: 2)
    }

    /// With no tabs the status item must read idle and count zero — not
    /// crash on an empty aggregation.
    @Test func anEmptyModelIsIdleAndCountsNothing() {
        let model = MenuBarStatusModel()

        #expect(model.anyTransferActive == false)
        #expect(model.connectedCount == 0)
    }

    /// Disconnected tabs must not be counted: the header counter says how
    /// many sessions are live, not how many tabs are open.
    @Test func disconnectedTabsDoNotCount() {
        let model = MenuBarStatusModel()
        model.tabs = [makeTab(), makeTab()]

        #expect(model.connectedCount == 0)
    }

    /// A tab with no running transfer must not light the active icon. This
    /// is the state the icon spends most of its life in, and an aggregation
    /// that defaulted to "active" would make it useless.
    @Test func tabsWithoutRunningTransfersLeaveTheIconIdle() {
        let model = MenuBarStatusModel()
        model.tabs = [makeTab()]

        #expect(model.anyTransferActive == false)
    }

    /// The closures must be callable defaults, so a status item built before
    /// `ContentView` wires them does not trap when clicked.
    @Test func theDefaultClosuresAreSafeToCall() {
        let model = MenuBarStatusModel()

        model.showMainWindow()
        model.focusTab(UUID())
    }
}
