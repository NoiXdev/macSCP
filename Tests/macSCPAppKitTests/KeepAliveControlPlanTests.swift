import Foundation
import Testing
@testable import MacSCPAppKit
import macSCPCore

/// Direct tests over `KeepAliveControlPlan` (Settings UI, Task 9) — the
/// plain, testable mapping the Keep-Alive toggle and interval stepper draw
/// from. `SettingsStore.keepAliveIntervalSeconds` is a SINGLE stored
/// integer where `0` means "off"; Task 9 added no second persisted setting,
/// so the toggle's on/off state, the stepper's displayed value, and which
/// value gets persisted when the toggle flips are all derived here instead
/// of bound straight to the store. No SwiftUI rendering harness exists in
/// this project, so nothing here can prove what actually lands on screen;
/// what it CAN prove, and does, is that mapping — same rationale as
/// `LivenessDotPlanTests`.
@Suite("Keep-alive control plan")
struct KeepAliveControlPlanTests {
    @Test func aZeroStoredValueReadsAsDisabled() {
        #expect(KeepAliveControlPlan.isEnabled(storedSeconds: 0) == false)
    }

    @Test func anyNonZeroStoredValueReadsAsEnabled() {
        #expect(KeepAliveControlPlan.isEnabled(storedSeconds: 15) == true)
        #expect(KeepAliveControlPlan.isEnabled(storedSeconds: 600) == true)
    }

    /// While enabled, the stepper shows the stored value itself — the
    /// remembered fallback is not consulted at all.
    @Test func whileEnabledTheStepperShowsTheStoredValue() {
        #expect(
            KeepAliveControlPlan.displayedInterval(storedSeconds: 90, lastKnownInterval: 60) == 90)
    }

    /// While disabled, the stored value IS the `0` sentinel — showing that
    /// in a "every N seconds" field would read as a broken stepper, not
    /// "no probe" — so the view's remembered on-value is shown instead.
    @Test func whileDisabledTheStepperShowsTheRememberedValue() {
        #expect(
            KeepAliveControlPlan.displayedInterval(storedSeconds: 0, lastKnownInterval: 120) == 120)
    }

    /// Turning the toggle off writes the sentinel directly, regardless of
    /// what the remembered value is — off always means `0`.
    @Test func togglingOffAlwaysStoresTheSentinel() {
        #expect(KeepAliveControlPlan.storedValue(togglingTo: false, lastKnownInterval: 300) == 0)
        #expect(KeepAliveControlPlan.storedValue(togglingTo: false, lastKnownInterval: 15) == 0)
    }

    /// Turning the toggle on restores the REMEMBERED value, not
    /// `SettingsStore`'s own clamp default — a user who set 300s, turned
    /// probing off, then back on, gets 300s back, not 60.
    @Test func togglingOnRestoresTheRememberedValueNotTheStoreDefault() {
        #expect(KeepAliveControlPlan.storedValue(togglingTo: true, lastKnownInterval: 300) == 300)
        #expect(
            KeepAliveControlPlan.storedValue(togglingTo: true, lastKnownInterval: 300)
                != SettingsStore.defaultKeepAliveIntervalSeconds)
    }

    // MARK: - storedValue(forIntervalChangeTo:isEnabled:) (fix round 1)
    //
    // Added when review found the interval stepper's `set` closure wrote
    // `store.keepAliveIntervalSeconds` straight from the committed value,
    // never calling into this plan — safe only because the Stepper's own
    // `15...600` range and `.disabled` state kept `0` out, not because
    // anything here said so. These two tests are what makes THAT call
    // site's own behavior provable by mutating a tested function, once
    // `KeepAliveStepperWiringGuardTests` (source-scan) confirms the real
    // call site actually reaches it.

    @Test func aCommitWhileEnabledPassesThroughUnchanged() {
        #expect(
            KeepAliveControlPlan.storedValue(forIntervalChangeTo: 200, isEnabled: true) == 200)
    }

    /// A commit that somehow still fires while disabled must not leak a
    /// stray interval into the store — it clamps to the `0` sentinel, the
    /// same value `storedValue(togglingTo: false, ...)` writes.
    @Test func aCommitWhileDisabledClampsToTheSentinel() {
        #expect(
            KeepAliveControlPlan.storedValue(forIntervalChangeTo: 200, isEnabled: false) == 0)
    }
}
