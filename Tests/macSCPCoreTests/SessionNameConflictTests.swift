import Foundation
import Testing

@testable import macSCPCore

/// Pins `SessionNameConflict.build(name:mode:in:)`: whether the connection
/// form has something to warn about, **and which of two different things it
/// has to say**.
///
/// `SessionNameCollisionTests` already proves what `collides` answers when
/// it is told which session to leave out. What it cannot see is the step
/// this value adds — reading `ConnectionViewModel.FormMode` — and that step
/// decides two things, both silent when wrong:
///
/// * Which session to exclude. An `.edit` that excludes nothing warns on
///   every stored session the user opens; a `.new` that excludes something
///   warns on none. Both compile and both render.
/// * **What saving will actually do**, which is not the same on the two
///   paths and was wrong in the first version of this feature. A new
///   connection is saved with `SessionListViewModel.save`, which upserts by
///   NAME and really does replace the session it lands on. An edit goes
///   through `updateSession`, which upserts by ID: the session whose name
///   was matched survives untouched and the store ends up holding two of
///   that name (`SessionListViewModelTests
///   .updateSessionUpsertsByIdSoARenameCanDuplicateAName`). Telling the
///   user "saving replaces it" there is not a wording problem, it names an
///   outcome that does not happen — and a warning nobody can trust is
///   worse than no warning, because this feature exists to be believed.
///
/// The trimming case below is deliberately asserted here as well as in
/// `SessionNameCollisionTests`, on the value the form actually asks: the
/// two rules trimming in step is what an earlier round got wrong, and a
/// property is worth pinning at the surface that would show it.
@Suite("Session name conflict")
struct SessionNameConflictTests {
    private func session(_ name: String) -> StoredSession {
        StoredSession(id: UUID(), name: name, kind: .ssh)
    }

    @Test func aNewConnectionIsToldTheSessionItWouldReplace() {
        let target = session("web")
        let conflict = SessionNameConflict.build(
            name: "web", mode: .new, in: [session("other"), target])
        #expect(conflict == .replaces(target))
    }

    @Test func aFreeNameWarnsAboutNothing() {
        #expect(SessionNameConflict.build(
            name: "web", mode: .new, in: [session("other")]) == nil)
    }

    @Test func editingASessionDoesNotWarnAboutThatSessionItself() {
        // The form shows the edited session's own name, so this is the
        // case that would make the warning permanent.
        let editing = session("web")
        #expect(SessionNameConflict.build(
            name: "web", mode: .edit(sessionID: editing.id), in: [editing]) == nil)
    }

    @Test func editingIsToldItWouldShareTheNameRatherThanReplaceIt() {
        // The case N1 was about: `updateSession` upserts by id, so nothing
        // is replaced here — both sessions survive, sharing a name.
        let editing = session("old")
        let other = session("web")
        let conflict = SessionNameConflict.build(
            name: "web", mode: .edit(sessionID: editing.id), in: [editing, other])
        #expect(conflict == .duplicates(other))
    }

    @Test func theTwoOutcomesDoNotShareTheirText() {
        // The whole point of the split: one path replaces and one does not,
        // so the two cases must not be able to render the same sentence.
        let target = session("web")
        let replacing = SessionNameConflict.replaces(target)
        let duplicating = SessionNameConflict.duplicates(target)
        #expect(replacing.messageKey != duplicating.messageKey)
        #expect(replacing.messageDefault != duplicating.messageDefault)
        // Each key carries the placeholder it is formatted with, as this
        // project's argument-bearing keys do.
        for conflict in [replacing, duplicating] {
            #expect(conflict.messageKey.hasSuffix(" %@"))
            #expect(conflict.messageDefault.contains("%@"))
            #expect(conflict.session.id == target.id)
        }
    }

    @Test func theNameIsTrimmedBecauseSavingTrims() {
        // Both save paths store the trimmed name, so a trailing space is
        // not an escape from the collision — and must not be an escape
        // from the warning either. Not trimmed here but in
        // `SessionNameCollision`, so the warning and the stepping-aside
        // rule are held to the same answer by the tests on both.
        let target = session("web")
        #expect(SessionNameConflict.build(
            name: "  web ", mode: .new, in: [target]) == .replaces(target))
    }

    @Test func theComparisonStaysExactAsSaveIsExact() {
        // Inherited from `SessionNameCollision`, asserted here because this
        // is the value the form actually asks: a warning under different
        // rules than `save` compares by is a warning about the wrong thing.
        #expect(SessionNameConflict.build(
            name: "web", mode: .new, in: [session("Web")]) == nil)
    }
}
