import Foundation
import Testing
@testable import macSCPCore

/// The continuation bridge behind the shared import conflict sheet (M19/T8).
/// What is proven here is the resumption contract the app cannot test for
/// itself: every prompt is asked, every prompt is answered exactly once, and
/// an event that arrives late — a button tap as much as a dismissal — answers
/// the question it belongs to, or nothing at all.
@Suite("Import conflict bridge")
@MainActor
struct ImportConflictBridgeTests {
    /// Two incoming sets whose names both collide with the store, so the
    /// planner asks twice with nothing in between (no I/O — the loop is pure
    /// computation, which is exactly what makes the timing hazard below real).
    private func collidingPayload() -> ([LoginSet], LoginSetExportPayload) {
        let existing = [
            LoginSet(name: "alpha", username: "u"),
            LoginSet(name: "beta", username: "u"),
        ]
        let payload = LoginSetExportPayload(
            includesSecrets: false, includesKeyFiles: false,
            sets: ["alpha", "beta"].map { name in
                ExportedLoginSet(
                    id: UUID(), name: name, kind: .ssh, username: "u", authKind: .password,
                    keyPath: nil, accessKeyID: nil, secret: nil, embeddedKey: nil)
            })
        return (existing, payload)
    }

    /// Waits for the next prompt to appear, yielding to let the planner run.
    /// Bounded so a bridge that never asks fails the test instead of hanging
    /// the suite.
    private func awaitPrompt(_ bridge: ImportConflictBridge) async -> ImportConflictPromptItem? {
        for _ in 0..<10_000 {
            if let prompt = bridge.currentPrompt { return prompt }
            await Task.yield()
        }
        return nil
    }

    /// THE regression (M19/T8 review, critical): the presenter's "the sheet
    /// went away" net used to resolve whatever prompt was current at the
    /// moment it ran. Because an import planner does no I/O between two
    /// conflicts, it is already asking the SECOND question by the time the
    /// FIRST sheet's dismissal is delivered — so the net cancelled an import
    /// the user had just answered, and the applier then wrote nothing while
    /// (a cancelled import deliberately reporting nothing) saying nothing.
    @Test func aLateDismissalDoesNotCancelTheNextPrompt() async {
        let (existing, payload) = collidingPayload()
        let bridge = ImportConflictBridge()
        let arbiter = ImportConflictArbiter { conflict in await bridge.ask(conflict) }
        let planning = Task {
            await LoginSetImportPlanner.plan(
                existing: existing, incoming: payload, arbiter: arbiter)
        }

        var asked: [String] = []
        for _ in 0..<2 {
            guard let prompt = await awaitPrompt(bridge) else { break }
            asked.append(prompt.conflict.itemName)
            // The user answers: the button resolves the prompt…
            bridge.resolve(promptID: prompt.id, (resolution: .skip, applyToAll: false))
            // …and the framework reports the sheet's disappearance only
            // afterwards — a later main-actor turn, after the dismissal
            // animation. Modelled by yielding until the planner has had every
            // chance to run: it needs a handful of hops (continuation →
            // planner → arbiter actor → decider → `ask`) to reach the next
            // conflict, and it has no I/O to slow it down.
            for _ in 0..<50 { await Task.yield() }
            bridge.dismiss(promptID: prompt.id)
        }

        let plan = await planning.value
        #expect(asked == ["alpha", "beta"])
        #expect(plan.cancelled == false)
        #expect(plan.skipped == ["alpha", "beta"])
    }

    /// The mirror of the above, on the BUTTON path: a tap that belongs to the
    /// first sheet must not answer the second question. The same absence of
    /// I/O that made the dismissal case real makes this one real — the
    /// planner installs the next continuation microseconds after the first
    /// resumes, while the answered sheet is still animating out and a double
    /// click or a repeated press of `Replace`'s default-action shortcut is
    /// still being delivered. Replace is the destructive choice (it also
    /// overwrites stored secrets) and `applyToAll` would spread it across the
    /// rest of the run, so the wrong question getting it is the worst case.
    @Test func aStaleButtonTapDoesNotAnswerTheNextPrompt() async {
        let (existing, payload) = collidingPayload()
        let bridge = ImportConflictBridge()
        let arbiter = ImportConflictArbiter { conflict in await bridge.ask(conflict) }
        let planning = Task {
            await LoginSetImportPlanner.plan(
                existing: existing, incoming: payload, arbiter: arbiter)
        }

        guard let first = await awaitPrompt(bridge) else {
            Issue.record("no prompt")
            return
        }
        #expect(first.conflict.itemName == "alpha")
        // The user taps "Skip" on the first sheet…
        bridge.resolve(promptID: first.id, (resolution: .skip, applyToAll: false))
        // …and the planner, having no I/O to wait on, is already asking about
        // "beta" before the first sheet has finished going away.
        for _ in 0..<50 { await Task.yield() }
        guard let second = bridge.currentPrompt else {
            Issue.record("the planner did not ask a second time")
            return
        }
        #expect(second.conflict.itemName == "beta")

        // A second tap on the FIRST sheet's "Replace" lands now. It must be
        // dropped: "beta" is still the open, unanswered question.
        bridge.resolve(promptID: first.id, (resolution: .replace, applyToAll: true))
        #expect(bridge.currentPrompt?.id == second.id)

        // The user then actually answers "beta" on ITS sheet, which still
        // works — the stale tap consumed nothing.
        bridge.resolve(promptID: second.id, (resolution: .skip, applyToAll: false))

        let plan = await planning.value
        #expect(plan.replaced.isEmpty)
        #expect(plan.skipped == ["alpha", "beta"])
        #expect(plan.cancelled == false)
    }

    /// The net still does its job: a sheet that disappears WITHOUT an answer
    /// (the prompt it names is still the open one) cancels the import instead
    /// of leaving the planner suspended forever.
    @Test func anUnansweredDismissalStillCancels() async {
        let (existing, payload) = collidingPayload()
        let bridge = ImportConflictBridge()
        let arbiter = ImportConflictArbiter { conflict in await bridge.ask(conflict) }
        let planning = Task {
            await LoginSetImportPlanner.plan(
                existing: existing, incoming: payload, arbiter: arbiter)
        }

        let prompt = await awaitPrompt(bridge)
        #expect(prompt != nil)
        if let prompt { bridge.dismiss(promptID: prompt.id) }

        let plan = await planning.value
        #expect(plan.cancelled)
        #expect(bridge.currentPrompt == nil)
    }

    /// Exactly-once, from the other side: an answer followed by more
    /// answers/dismissals must not resume a continuation twice (which traps).
    @Test func repeatedAnswersResumeTheContinuationOnlyOnce() async {
        let (existing, payload) = collidingPayload()
        let bridge = ImportConflictBridge()
        let arbiter = ImportConflictArbiter { conflict in await bridge.ask(conflict) }
        let planning = Task {
            await LoginSetImportPlanner.plan(
                existing: existing, incoming: payload, arbiter: arbiter)
        }

        guard let first = await awaitPrompt(bridge) else {
            Issue.record("no prompt")
            return
        }
        // Double click on "Replace", then the dismissal, then a stale net for
        // a prompt that is long gone.
        bridge.resolve(promptID: first.id, (resolution: .skip, applyToAll: true))
        bridge.resolve(promptID: first.id, (resolution: .replace, applyToAll: false))
        bridge.dismiss(promptID: first.id)

        let plan = await planning.value
        // "Apply to all" answered the second collision without a second
        // prompt, and neither extra call turned the run into a cancellation.
        #expect(plan.cancelled == false)
        #expect(plan.skipped == ["alpha", "beta"])
    }

    /// M19/T8 review (leftover 1): calling `ask` a second time while a first
    /// `ask` is still pending must not silently overwrite `self.continuation`
    /// — that would leak the first continuation and hang whichever import is
    /// waiting on it forever. Unreachable through the real planners (both
    /// walk conflicts with a plain sequential `for` loop, never `TaskGroup`/
    /// `async let`), but nothing enforces that structurally, so the bridge
    /// itself must not depend on it.
    @Test func aSecondAskResolvesTheStrandedFirstContinuation() async {
        let bridge = ImportConflictBridge()
        let first = Task {
            await bridge.ask(ImportConflict(itemName: "first", kindLabel: "session"))
        }
        _ = await awaitPrompt(bridge)
        #expect(bridge.currentPrompt?.conflict.itemName == "first")

        let second = Task {
            await bridge.ask(ImportConflict(itemName: "second", kindLabel: "session"))
        }
        // Let the second `ask` run far enough to strand-resolve the first
        // and install its own prompt.
        for _ in 0..<50 { await Task.yield() }

        // The stranded first continuation was resolved (as `nil`) rather than
        // left hanging.
        let firstResult = await first.value
        #expect(firstResult == nil)
        // The second prompt is now the open one — its own continuation is
        // untouched and can still be answered normally.
        guard let secondPrompt = bridge.currentPrompt else {
            Issue.record("the second ask installed no prompt")
            return
        }
        #expect(secondPrompt.conflict.itemName == "second")
        bridge.resolve(promptID: secondPrompt.id, (resolution: .skip, applyToAll: false))
        let secondResult = await second.value
        #expect(secondResult?.resolution == .skip)
    }

    /// A cancelled planning task resolves an open prompt instead of leaving
    /// the continuation unfulfilled.
    @Test func cancellingThePlanningTaskResolvesTheOpenPrompt() async {
        let (existing, payload) = collidingPayload()
        let bridge = ImportConflictBridge()
        let arbiter = ImportConflictArbiter { conflict in await bridge.ask(conflict) }
        let planning = Task {
            await LoginSetImportPlanner.plan(
                existing: existing, incoming: payload, arbiter: arbiter)
        }

        _ = await awaitPrompt(bridge)
        planning.cancel()

        let plan = await planning.value
        #expect(plan.cancelled)
    }
}
