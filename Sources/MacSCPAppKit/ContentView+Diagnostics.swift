import Foundation
import SwiftUI
import macSCPCore

/// The window's one way onto the diagnostics panel (design §1).
///
/// Three doors reach it — the tab (its toolbar while connected, and the
/// failed-connect surface), the session context menu, and the connect-error
/// dialog — and all of them land here. One entry rather than one per door,
/// because what a door has to get right is not the button: it is WHERE the
/// secret is resolved from, WHICH backend's descriptor answers, and which
/// field values the probes read. A second entry beside this one would be a
/// second place for that to drift, and `DiagnosticsDoorsGuardTests` derives
/// this function by finding the only one that builds a `DiagnosticsTarget` —
/// so a second one makes the derivation ambiguous and the guard fail rather
/// than quietly cover half the doors.
///
/// Opening the panel measures NOTHING. It presents a sheet whose view model
/// has run nothing; the diagnosis starts when the user presses the button
/// inside it (decision of 2026-09-02).
extension ContentView {
    /// Which connection a door is asking about.
    ///
    /// A tab carries the form the user actually dialled with — including a
    /// password typed but never saved — while a sidebar row carries only what
    /// was stored. Both collapse to the same three facts below, which is why
    /// the entry takes this and not two overloads.
    enum DiagnosticsSource {
        case tab(SessionTab)
        case stored(StoredSession)

        /// Which tab's teardown is allowed to stop this diagnosis. A panel
        /// opened from the sidebar names no tab, and no teardown claims it.
        var tabID: UUID? {
            switch self {
            case .tab(let tab): return tab.id
            case .stored: return nil
            }
        }
    }

    func showDiagnostics(for source: DiagnosticsSource) {
        let target: DiagnosticsTarget
        switch source {
        case .tab(let tab):
            let stored = sessionListViewModel.sessions.first {
                $0.id == tab.activeStoredSessionID
            }
            target = DiagnosticsTarget(
                name: tab.displayTitle,
                kind: tab.connectionViewModel.kind,
                values: tab.connectionViewModel.values,
                sessionID: stored?.secretSlot ?? tab.activeStoredSessionID)
        case .stored(let stored):
            let descriptor = BackendDescriptor.descriptor(for: stored.kind)
            // `editBaseline` then `sessionValues`, the same pair
            // `prefillForm(from:)` merges — the baseline leaves every secret
            // field blank, and the stored record fills in what it holds. The
            // secret is not merged in from anywhere: the dial resolves it
            // through `sessionID` below, which is the resolver the connect
            // uses (design §3).
            var values = descriptor.editBaseline
            values.merge(descriptor.sessionValues(stored))
            target = DiagnosticsTarget(
                name: stored.name,
                kind: stored.kind,
                values: values,
                sessionID: stored.secretSlot)
        }
        diagnostics.present(
            DiagnosticsViewModel(target: target, secrets: diagnosticsSecrets),
            for: source.tabID)
    }

    /// Closes the panel and stops whatever it was measuring.
    ///
    /// The one way out, shared by the sheet's binding, its Close button and
    /// the tab's teardown, so no dismissal path can forget the half that
    /// cancels. `DiagnosticsPresenter.end()` is where the order lives —
    /// cancel, then forget.
    func endDiagnostics() {
        diagnostics.end()
    }

    /// Stops a diagnosis of `tab`, and leaves its rows on screen.
    ///
    /// Called from `teardown(_:reason:)` — see `DiagnosticsPresenter
    /// .stopRun(openedFor:)` for why stopping and dismissing are two
    /// different decisions, and why only one of them belongs on a path that
    /// runs for a liveness give-up nobody asked for.
    func stopDiagnostics(of tab: SessionTab) {
        diagnostics.stopRun(openedFor: tab.id)
    }

    /// The secret source the diagnosis authenticates through: the window's
    /// own `SecretStore`, adapted — the same store the connect path reads
    /// (`ContentView.secretStore`), never a second copy of a credential.
    var diagnosticsSecrets: any SecretSource {
        KeychainSecretSource(store: secretStore)
    }
}
