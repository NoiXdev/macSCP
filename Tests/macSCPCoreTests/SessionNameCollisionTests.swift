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

    @Test func aNameIsJudgedAsSaveWillReceiveIt() {
        // The trap this whole rule exists for, one layer deeper than the
        // comparison. `save` never sees what the field holds: both save
        // paths hand it
        // `saveName.trimmingCharacters(in: .whitespacesAndNewlines)`. So a
        // rule that matches `==` but judges the UNTRIMMED text is comparing
        // a different operand than saving will, which is the same bug with
        // the same consequence — measured on a real path: an SSH host field
        // with a trailing space makes `SSHFieldSchema.displaySummary`
        // (which interpolates the host raw, unlike `apply`, which trims)
        // produce the tab title "tim@example.com ", "Save as Session" calls
        // it free, and saving then replaces the stored "tim@example.com".
        #expect(SessionNameCollision.freeName(
            basedOn: "web ", avoiding: [session("web")]) == "web 2")
        #expect(SessionNameCollision.collides(
            " web", with: [session("web")], excluding: nil)?.name == "web")
    }

    @Test func aFreeNameIsHandedBackInTheFormItWillBeSavedIn() {
        // Not merely "does it collide": the answer is written into the name
        // field, so returning the untrimmed text would put a name on screen
        // that saving silently turns into a different one.
        #expect(SessionNameCollision.freeName(
            basedOn: " web ", avoiding: [session("other")]) == "web")
    }

    @Test func onlyTheAskedNameIsTrimmed() {
        // `save` compares the trimmed candidate against the stored names as
        // they stand — it does not trim THOSE, and neither does this rule.
        // No known writer stores such a name (the import path trims on
        // purpose), so this pins a mirror of `save` rather than a case from
        // the field: were one to exist, it is a different name, and folding
        // the two together would step aside from a name saving would have
        // left alone.
        #expect(SessionNameCollision.freeName(
            basedOn: "web", avoiding: [session("web ")]) == "web")
        #expect(SessionNameCollision.collides(
            "web", with: [session("web ")], excluding: nil) == nil)
    }
}
