import Foundation
import Testing
@testable import MacSCPAppKit
@testable import macSCPCore

/// `ContentView.CarriedFormState` — everything the tab menu's "Save as
/// Session…" moves from a RUNNING tab's form to the form that will save it.
///
/// Why this is a test and not another source scan: the bug it exists to
/// prevent is a value one. `ConnectionViewModel.values` is the form's
/// documented single source of truth, and copying it alone looks complete —
/// but several things the form reads live beside it as their own stored
/// properties. The dangerous one is `jumpEnabled`: every jump FIELD (host,
/// port, user name, secret, key path) is inside `values`, while the flag
/// that says the block is in use is not. Copy `values` alone, and
/// `buildJumpSpec()` answers `nil` — a session reachable only through its
/// bastion gets saved as a direct one, with nothing on screen to show it.
///
/// The target form is put through `exitEditMode()` first in every test
/// here, because that is what the real caller does and because it is
/// precisely what clears the jump block: a carry that happened to run
/// before it would pass while the real one still dropped the hop.
@Suite("Carried form state")
@MainActor
struct CarriedFormStateTests {
    private func makeForm() -> ConnectionViewModel {
        ConnectionViewModel(connector: { _, _ in
            fatalError("not exercised by these tests — nothing here dials")
        })
    }

    /// A source form standing in for a running ad-hoc SSH session reached
    /// through a bastion, with a group, tags and a login-set binding.
    private func makeRunningForm() -> ConnectionViewModel {
        let form = makeForm()
        form.host = "web.example.com"
        form.port = "22"
        form.username = "tim"
        form.password = "geheim"
        form.tags = ["prod", "eu"]
        form.selectedGroupID = UUID()
        form.loginMode = .set
        form.selectedLoginSetID = UUID()
        form.jumpEnabled = true
        form.jumpHost = "bastion.example.com"
        form.jumpPort = "2222"
        form.jumpUsername = "jump-tim"
        form.jumpPassword = "jump-geheim"
        return form
    }

    /// The finding this type was written for: the hop survives the carry.
    @Test func theBastionSurvivesTheCarry() {
        let source = makeRunningForm()
        let carried = ContentView.CarriedFormState(source)

        let target = makeForm()
        target.exitEditMode()
        #expect(!target.jumpEnabled, "precondition: exitEditMode clears the jump block")
        carried.apply(to: target)

        #expect(target.jumpEnabled)
        #expect(target.jumpHost == "bastion.example.com")
        #expect(target.jumpPort == "2222")
        #expect(target.jumpUsername == "jump-tim")
        let spec = target.buildJumpSpec()
        #expect(spec != nil, """
            the carried form builds no JumpSpec — a session only reachable through \
            its bastion would be saved as a direct one.
            """)
        #expect(spec?.host == "bastion.example.com")
        #expect(spec?.port == 2222)
    }

    /// Copying `values` alone is what the first draft did. Stated as a test
    /// so the reason `CarriedFormState` exists cannot be mistaken for
    /// ceremony: this is the exact failure, reproduced.
    @Test func copyingValuesAloneWouldHaveLostTheBastion() {
        let source = makeRunningForm()

        let target = makeForm()
        target.exitEditMode()
        target.kind = source.kind
        target.values = source.values

        #expect(target.jumpHost == "bastion.example.com", """
            precondition: the jump's FIELDS do ride along inside `values` — it is only \
            the flag that does not, which is what makes the loss silent.
            """)
        #expect(!target.jumpEnabled)
        #expect(target.buildJumpSpec() == nil)
    }

    /// The rest of what a saved session is built from and does not live in
    /// `values`.
    @Test func theGroupTagsAndLoginSetBindingSurvive() {
        let source = makeRunningForm()
        let carried = ContentView.CarriedFormState(source)

        let target = makeForm()
        target.exitEditMode()
        carried.apply(to: target)

        #expect(target.selectedGroupID == source.selectedGroupID)
        #expect(target.tags == ["prod", "eu"])
        #expect(target.loginMode == .set)
        #expect(target.selectedLoginSetID == source.selectedLoginSetID)
    }

    /// The jump's own mode switches, which decide what `buildJumpSpec()`
    /// writes into the spec.
    @Test func theJumpsOwnModeSwitchesSurvive() {
        let source = makeRunningForm()
        let referenced = UUID()
        source.jumpSourceMode = .session
        source.jumpSessionID = referenced
        let carried = ContentView.CarriedFormState(source)

        let target = makeForm()
        target.exitEditMode()
        carried.apply(to: target)

        #expect(target.jumpSourceMode == .session)
        #expect(target.jumpSessionID == referenced)
    }

    @Test func theJumpsOwnLoginSetBindingSurvives() {
        let source = makeRunningForm()
        let jumpSet = UUID()
        source.jumpLoginMode = .set
        source.jumpSelectedLoginSetID = jumpSet
        let carried = ContentView.CarriedFormState(source)

        let target = makeForm()
        target.exitEditMode()
        carried.apply(to: target)

        #expect(target.jumpLoginMode == .set)
        #expect(target.jumpSelectedLoginSetID == jumpSet)
    }

    /// The backend and its fields, the part that was already right — kept
    /// so a rewrite of `apply(to:)` cannot lose it while the jump tests
    /// stay green.
    @Test func theBackendAndItsFieldsSurvive() {
        let source = makeForm()
        source.kind = .s3
        source.values[S3Field.bucket] = "photos"
        let sourceValues = source.values
        let carried = ContentView.CarriedFormState(source)

        let target = makeForm()
        target.exitEditMode()
        #expect(target.kind == .ssh, "precondition: exitEditMode returns the form to SSH")
        carried.apply(to: target)

        #expect(target.kind == .s3)
        #expect(target.values[S3Field.bucket] == "photos", """
            `kind` must be assigned BEFORE `values` — its didSet resets `values` to the \
            backend's defaults, so the other order wipes what was just carried in.
            """)
        #expect(target.values == sourceValues)
    }

    /// An instruction about a DIFFERENT submission, deliberately not
    /// carried — and cleared on the target, so a stale tick left on the tab
    /// that happens to be reused cannot ride along either.
    @Test func theNewLoginSetIntentIsNotCarriedAndIsCleared() {
        let source = makeRunningForm()
        source.saveAsNewLoginSet = true
        source.newLoginSetName = "from the other form"
        let carried = ContentView.CarriedFormState(source)

        let target = makeForm()
        target.saveAsNewLoginSet = true
        target.newLoginSetName = "stale intent on the reused tab"
        target.exitEditMode()
        carried.apply(to: target)

        #expect(!target.saveAsNewLoginSet)
        #expect(target.newLoginSetName.isEmpty)
    }
}
