import Foundation
import Testing
@testable import MacSCPAppKit
@testable import macSCPCore

@Suite("SessionTab")
@MainActor
struct SessionTabTests {
    /// Builds a tab with the same collaborators `ContentView` hands it.
    /// Adjust only the initializer arguments if Core's signatures differ.
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

    /// A tab with no session is not connected, and shows the generic title
    /// rather than a stale name.
    @Test func aFreshTabIsNotConnectedAndUsesTheGenericTitle() {
        let tab = makeTab()

        #expect(tab.isConnected == false)
        #expect(tab.displayTitle.isEmpty == false)
        #expect(tab.displayTitle != "tabs.newConnection")
    }

    /// A named tab shows its own name.
    @Test func aNamedTabShowsItsName() {
        let tab = makeTab()
        tab.titleName = "prod-web"

        #expect(tab.displayTitle == "prod-web")
    }

    /// The confirmation suspends until answered, then reports the answer and
    /// clears the pending flag. A dialog that stayed "pending" after being
    /// answered would block every later connect on this tab.
    @Test func answeringTheConfirmationResumesItAndClearsThePendingFlag() async {
        let tab = makeTab()

        async let answer = tab.confirmPlaintext()
        while tab.plaintextConfirmationPending == false { await Task.yield() }
        tab.resolvePlaintextConfirmation(confirmed: true)

        #expect(await answer == true)
        #expect(tab.plaintextConfirmationPending == false)
    }

    /// A refusal must come back as `false`, not merely as "not true" — the
    /// connector treats the two identically only by accident today.
    @Test func refusingTheConfirmationReportsFalse() async {
        let tab = makeTab()

        async let answer = tab.confirmPlaintext()
        while tab.plaintextConfirmationPending == false { await Task.yield() }
        tab.resolvePlaintextConfirmation(confirmed: false)

        #expect(await answer == false)
    }

    /// Resolving twice must not resume the continuation twice — that traps
    /// at runtime. The second call is a no-op by design.
    @Test func resolvingTwiceIsHarmless() async {
        let tab = makeTab()

        async let answer = tab.confirmPlaintext()
        while tab.plaintextConfirmationPending == false { await Task.yield() }
        tab.resolvePlaintextConfirmation(confirmed: true)
        tab.resolvePlaintextConfirmation(confirmed: false)

        #expect(await answer == true)
    }

    /// Resolving without a pending prompt must not trap either — the UI can
    /// dismiss a sheet that was never asked for.
    @Test func resolvingWithNothingPendingIsHarmless() {
        let tab = makeTab()

        tab.resolvePlaintextConfirmation(confirmed: true)

        #expect(tab.plaintextConfirmationPending == false)
    }

    /// The audit flag must be resettable to false at the start of a connect:
    /// its whole purpose is that a previous connect's confirmation cannot
    /// leak into a later, unrelated connect's audit record.
    @Test func theConfirmationFlagCanBeSetAndCleared() {
        let tab = makeTab()

        tab.markPlaintextConfirmed()
        #expect(tab.pendingPlaintextConfirmation)

        tab.resetPendingPlaintextConfirmation()
        #expect(tab.pendingPlaintextConfirmation == false)
    }
}
