import AppKit
import Carbon
import Foundation
import ServiceManagement
import Testing

@testable import MacSCPAppKit

/// The login item, measured everywhere except at the service (port-forwarding
/// plan, Task 7).
///
/// **Nothing here registers anything.** `SMAppService.mainApp.register()`
/// writes a real login item for the account running `swift test`, and
/// `unregister()` would remove one the user may have set themselves — so the
/// whole of this suite drives `LoginItemModel` over a fake conforming to
/// `LoginItemRegistering`, and the only `SMAppService` symbol it names is the
/// `Status` enum whose cases the mapping is measured against. Reading
/// `SMAppService.Status.enabled` is reading a constant; it starts no service.
/// `TunnelPresenceWiringGuardTests` scans this target's sources to keep that
/// boundary from eroding.
///
/// The status cases are DERIVED from `SMAppService.Status` rather than spelt
/// as raw integers, which is this project's rule about second copies of a
/// name (CLAUDE.md, "Guards that name what they watch").
@Suite("Login item")
@MainActor
struct LoginItemTests {

    /// Records what it was asked and answers what a test told it to.
    @MainActor
    final class FakeLoginItem: LoginItemRegistering {
        var reported: LoginItemStatus
        /// What `register()`/`unregister()` leave the status at — the system's
        /// answer, which is not necessarily the one that was asked for.
        var afterRegister: LoginItemStatus = .enabled
        var afterUnregister: LoginItemStatus = .notRegistered
        var registerError: (any Error)?
        var unregisterError: (any Error)?
        private(set) var registerCount = 0
        private(set) var unregisterCount = 0
        private(set) var statusReads = 0

        init(reported: LoginItemStatus = .notRegistered) {
            self.reported = reported
        }

        func status() -> LoginItemStatus {
            statusReads += 1
            return reported
        }

        func register() throws {
            registerCount += 1
            if let registerError { throw registerError }
            reported = afterRegister
        }

        func unregister() throws {
            unregisterCount += 1
            if let unregisterError { throw unregisterError }
            reported = afterUnregister
        }
    }

    private struct Refused: LocalizedError {
        var errorDescription: String? { "the system refused the request" }
    }

    // MARK: - The mapping

    /// Every case `SMAppService.Status` declares maps to a distinct answer,
    /// and the four are named rather than folded into a `Bool`.
    @Test func everyServiceStatusMapsToItsOwnAnswer() {
        #expect(LoginItemStatusPlan.status(.enabled) == .enabled)
        #expect(LoginItemStatusPlan.status(.notRegistered) == .notRegistered)
        #expect(LoginItemStatusPlan.status(.requiresApproval) == .requiresApproval)
        #expect(LoginItemStatusPlan.status(.notFound) == .notFound)

        let mapped: [LoginItemStatus] = [
            .status(of: .enabled), .status(of: .notRegistered),
            .status(of: .requiresApproval), .status(of: .notFound),
        ]
        #expect(Set(mapped).count == 4, "two service statuses map to the same answer")
    }

    // MARK: - The model

    @Test func theModelStartsFromWhatTheServiceReports() {
        let fake = FakeLoginItem(reported: .enabled)
        let model = LoginItemModel(service: fake)
        #expect(model.status == .enabled)
        #expect(model.isOn)
        #expect(model.errorMessage == nil)
    }

    /// **The toggle follows the service, not the click.** A registration the
    /// system leaves at `.requiresApproval` reports exactly that — this is
    /// the ad-hoc-signed dev build's case, and a model that mirrored the
    /// click would show "on" while nothing at all happens at login.
    @Test func turningItOnShowsWhatTheSystemActuallyDid() {
        let fake = FakeLoginItem()
        fake.afterRegister = .requiresApproval
        let model = LoginItemModel(service: fake)

        model.setEnabled(true)

        #expect(fake.registerCount == 1)
        #expect(model.status == .requiresApproval)
        #expect(model.isOn, "an approval that is pending is still a request the app made")
        #expect(model.errorMessage == nil)
    }

    /// And the case the same build hits when the system will not have it at
    /// all: the status comes back `.notFound` and the toggle is off, without
    /// anything having thrown.
    @Test func aRefusedRegistrationLeavesTheToggleOff() {
        let fake = FakeLoginItem()
        fake.afterRegister = .notFound
        let model = LoginItemModel(service: fake)

        model.setEnabled(true)

        #expect(model.status == .notFound)
        #expect(!model.isOn)
    }

    @Test func turningItOffUnregisters() {
        let fake = FakeLoginItem(reported: .enabled)
        let model = LoginItemModel(service: fake)

        model.setEnabled(false)

        #expect(fake.unregisterCount == 1)
        #expect(fake.registerCount == 0)
        #expect(model.status == .notRegistered)
        #expect(!model.isOn)
    }

    /// A thrown service error is DISPLAYED, not fatal — and the status is
    /// re-read afterwards, because a call that threw is exactly the case
    /// where what was asked for and what is true disagree.
    @Test func aThrownErrorIsShownAndTheStatusIsReadAgain() {
        let fake = FakeLoginItem(reported: .notRegistered)
        fake.registerError = Refused()
        let model = LoginItemModel(service: fake)
        let readsBefore = fake.statusReads

        model.setEnabled(true)

        #expect(model.errorMessage != nil)
        #expect(model.errorMessage?.contains("the system refused the request") == true)
        #expect(model.status == .notRegistered)
        #expect(fake.statusReads > readsBefore, "the status was not re-read after the failure")
    }

    /// A failure does not outlive the state it described: the next attempt
    /// clears it before it starts.
    @Test func aLaterSuccessClearsTheFailure() {
        let fake = FakeLoginItem()
        fake.registerError = Refused()
        let model = LoginItemModel(service: fake)
        model.setEnabled(true)
        #expect(model.errorMessage != nil)

        fake.registerError = nil
        model.setEnabled(true)

        #expect(model.errorMessage == nil)
        #expect(model.status == .enabled)
    }

    // MARK: - The launch flag

    /// No Apple event at all — which is what `swift test`, `swift run` and
    /// any launch that is not an `kAEOpenApplication` see — reads `false`.
    /// The conservative direction: a forwarding set to "At login" is not
    /// started by a launch this app cannot identify.
    @Test func noLaunchEventIsNotALoginLaunch() {
        #expect(!LoginLaunchDetector.launchedAtLogin(event: nil))
    }

    /// An ordinary open-application event, with no launch-reason parameter,
    /// is not a login launch either.
    @Test func aPlainOpenEventIsNotALoginLaunch() {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenApplication),
            targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID))
        #expect(!LoginLaunchDetector.launchedAtLogin(event: event))
    }

    /// The positive beside the two negatives: an event carrying the
    /// launch-as-login-item reason IS read as one. Without this the two
    /// checks above would be satisfied by a detector that answers `false`
    /// unconditionally — which is precisely the silent pass this project's
    /// rule about negative checks warns about.
    @Test func anEventCarryingTheLoginReasonIsALoginLaunch() {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenApplication),
            targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(
            NSAppleEventDescriptor(enumCode: UInt32(keyAELaunchedAsLogInItem)),
            forKeyword: keyAEPropData)
        #expect(LoginLaunchDetector.launchedAtLogin(event: event))
    }

    /// A DIFFERENT launch reason on the same parameter is not a login launch
    /// — the check reads the reason, not merely the presence of the
    /// parameter.
    @Test func anotherLaunchReasonIsNotALoginLaunch() {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenApplication),
            targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(
            NSAppleEventDescriptor(enumCode: UInt32(keyAELaunchedAsServiceItem)),
            forKeyword: keyAEPropData)
        #expect(!LoginLaunchDetector.launchedAtLogin(event: event))
    }
}

extension LoginItemStatus {
    /// A spelling of the mapping under test that reads as a value, used only
    /// to prove the four answers are distinct.
    fileprivate static func status(of raw: SMAppService.Status) -> LoginItemStatus {
        LoginItemStatusPlan.status(raw)
    }
}
