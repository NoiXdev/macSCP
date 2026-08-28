import Foundation
import Testing
@testable import macSCPCore

@Suite("Session name collision")
struct SessionNameCollisionTests {
    private func session(_ name: String) -> StoredSession {
        StoredSession(id: UUID(), name: name, kind: .ssh)
    }

    @Test func aFreeNameIsReturnedUnchanged() {
        #expect(SessionNameCollision.freeName(
            basedOn: "web", avoiding: [session("other")]) == "web")
    }

    @Test func aTakenNameStepsAsideToTheNextNumber() {
        #expect(SessionNameCollision.freeName(
            basedOn: "web", avoiding: [session("web")]) == "web 2")
    }

    @Test func itKeepsCountingWhileTheAlternativesAreAlsoTaken() {
        let taken = [session("web"), session("web 2"), session("web 3")]
        #expect(SessionNameCollision.freeName(basedOn: "web", avoiding: taken) == "web 4")
    }

    @Test func aNameThatAlreadyEndsInANumberIsNotReinterpreted() {
        // "web 2" is a name in its own right, not "web" at number two: the
        // rule appends, it does not parse what it was given.
        #expect(SessionNameCollision.freeName(
            basedOn: "web 2", avoiding: [session("web 2")]) == "web 2 2")
    }

    @Test func theComparisonIsExactBecauseSaveIsExact() {
        // `SessionListViewModel.save` matches with `==`. A rule that treated
        // "Web" as taken would step aside from a name that saving would have
        // left alone — and one that treated "web" as free when "Web" exists
        // would still overwrite. Both directions are wrong.
        #expect(SessionNameCollision.freeName(
            basedOn: "web", avoiding: [session("Web")]) == "web")
    }

    @Test func collisionReportsTheSessionThatWouldBeReplaced() {
        let target = session("web")
        let found = SessionNameCollision.collides(
            "web", with: [session("other"), target], excluding: nil)
        #expect(found?.id == target.id)
    }

    @Test func noCollisionIsReportedForAFreeName() {
        #expect(SessionNameCollision.collides(
            "web", with: [session("other")], excluding: nil) == nil)
    }

    @Test func theSessionBeingEditedIsNotACollisionWithItself() {
        let editing = session("web")
        #expect(SessionNameCollision.collides(
            "web", with: [editing], excluding: editing.id) == nil)
    }

    @Test func editingStillCollidesWithADifferentSessionOfThatName() {
        let editing = session("old")
        let other = session("web")
        let found = SessionNameCollision.collides(
            "web", with: [editing, other], excluding: editing.id)
        #expect(found?.id == other.id)
    }
}
