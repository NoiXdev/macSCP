import Foundation
import Testing

@testable import MacSCPAppKit
@testable import macSCPCore

/// Pins `SessionNameConflict.replacedSession(byName:mode:in:)`: whether the
/// connection form has something to warn about.
///
/// `SessionNameCollisionTests` already proves what `collides` answers when
/// it is told which session to leave out. What it cannot see is the step
/// this value adds — reading that id off `ConnectionViewModel.FormMode` —
/// and that step is the one with no symptom. Both ways of getting it wrong
/// compile and render: an `.edit` that excludes nothing warns on every
/// stored session the user opens, and a `.new` that excludes something
/// warns on none.
@Suite("Session name conflict")
struct SessionNameConflictTests {
    private func session(_ name: String) -> StoredSession {
        StoredSession(id: UUID(), name: name, kind: .ssh)
    }

    @Test func aNewConnectionIsToldWhichSessionItWouldReplace() {
        let target = session("web")
        let found = SessionNameConflict.replacedSession(
            byName: "web", mode: .new, in: [session("other"), target])
        #expect(found?.id == target.id)
    }

    @Test func aFreeNameWarnsAboutNothing() {
        #expect(SessionNameConflict.replacedSession(
            byName: "web", mode: .new, in: [session("other")]) == nil)
    }

    @Test func editingASessionDoesNotWarnAboutThatSessionItself() {
        // The form shows the edited session's own name, so this is the
        // case that would make the warning permanent.
        let editing = session("web")
        #expect(SessionNameConflict.replacedSession(
            byName: "web", mode: .edit(sessionID: editing.id), in: [editing]) == nil)
    }

    @Test func editingStillWarnsAboutADifferentSessionOfThatName() {
        let editing = session("old")
        let other = session("web")
        let found = SessionNameConflict.replacedSession(
            byName: "web", mode: .edit(sessionID: editing.id), in: [editing, other])
        #expect(found?.id == other.id)
    }

    @Test func theNameIsTrimmedBecauseSavingTrims() {
        // Both save paths store the trimmed name, so a trailing space is
        // not an escape from the collision — and must not be an escape
        // from the warning either.
        let target = session("web")
        let found = SessionNameConflict.replacedSession(
            byName: "  web ", mode: .new, in: [target])
        #expect(found?.id == target.id)
    }

    @Test func theComparisonStaysExactAsSaveIsExact() {
        // Inherited from `SessionNameCollision`, asserted here because this
        // is the value the form actually asks: a warning under different
        // rules than `save` compares by is a warning about the wrong thing.
        #expect(SessionNameConflict.replacedSession(
            byName: "web", mode: .new, in: [session("Web")]) == nil)
    }
}
