import Foundation
import Testing
@testable import macSCPCore

/// The continuation bridge behind the transfer conflict sheet (M5b/T4), driven
/// through the REAL `TransferQueueViewModel` over a folder transfer whose files
/// all collide. What is proven here is the resumption contract the app cannot
/// test for itself: every prompt is asked, every prompt is answered exactly
/// once, and an event that arrives late — a button tap as much as a dismissal —
/// answers the question it belongs to, or nothing at all.
///
/// The twin suite for the import side is `ImportConflictBridgeTests`; the two
/// bridges have the same shape and the same hazards.
@Suite("Conflict prompt bridge")
@MainActor
struct ConflictPromptBridgeTests {
    private typealias TestFS = TransferQueueViewModelTests.QueueTestFS

    /// A two-file folder (`dir/{a.txt, sub/b.txt}`) whose every destination
    /// path is already taken, so the queue hits a conflict on both files and
    /// prompts twice — with nothing but an in-memory `stat` in between, which
    /// is what a real remote `stat` over an already-open channel amounts to.
    private func collidingTree() -> (source: TestFS, destination: TestFS) {
        let source = TestFS(
            reads: [
                "/dir/a.txt": .init(content: Data("new a".utf8)),
                "/dir/sub/b.txt": .init(content: Data("new b".utf8)),
            ],
            listings: [
                "/dir": [
                    RemoteFileItem(name: "a.txt", path: "/dir/a.txt", kind: .file, size: 1),
                    RemoteFileItem(name: "sub", path: "/dir/sub", kind: .directory),
                ],
                "/dir/sub": [
                    RemoteFileItem(name: "b.txt", path: "/dir/sub/b.txt", kind: .file, size: 1),
                ],
            ])
        let destination = TestFS(reads: [
            "/ziel/dir/a.txt": .init(content: Data("old a".utf8)),
            "/ziel/dir/sub/b.txt": .init(content: Data("old b".utf8)),
        ])
        return (source, destination)
    }

    /// Starts the colliding folder transfer with `bridge` as the decider.
    /// `maxConcurrent = 1` so the two conflicts are strictly sequential — the
    /// prompts are gated FIFO either way, but this keeps the item order
    /// assertable.
    private func startCollidingTree(
        bridge: ConflictPromptBridge
    ) -> (queue: TransferQueueViewModel, destination: TestFS) {
        let (source, destination) = collidingTree()
        let queue = TransferQueueViewModel()
        queue.maxConcurrent = 1
        queue.conflictDecider = { conflict in await bridge.ask(conflict) }
        queue.enqueueTree(
            directoryName: "dir", direction: .download,
            source: source, sourceDirectory: "/dir",
            destination: destination, destinationDirectory: "/ziel",
            onCompleted: nil)
        return (queue, destination)
    }

    /// Waits for a prompt other than `after` to open, yielding to let the queue
    /// run. Bounded so a bridge that never asks fails the test instead of
    /// hanging the suite.
    private func awaitPrompt(
        _ bridge: ConflictPromptBridge, after: UUID? = nil
    ) async -> ConflictPromptItem? {
        for _ in 0..<10_000 {
            if let prompt = bridge.currentPrompt, prompt.id != after { return prompt }
            await Task.yield()
        }
        return nil
    }

    private func settle(_ queue: TransferQueueViewModel) async {
        for _ in 0..<10_000 where queue.isActive { await Task.yield() }
    }

    private func status(
        _ queue: TransferQueueViewModel, _ name: String
    ) -> TransferQueueViewModel.Item.Status? {
        queue.items.first(where: { $0.fileName == name })?.status
    }

    /// THE regression (M19 import twin, critical — the same defect on the
    /// transfer side): the presenter's "the sheet went away" net resolved
    /// whatever prompt was current at the moment it ran. Between two transfer
    /// conflicts there is a single remote `stat` over an already-open channel —
    /// sub-millisecond — whereas the dismissal fires only at the END of the
    /// sheet's ~250 ms close animation. So the queue is already asking the
    /// SECOND question when the FIRST sheet's dismissal lands, the net answers
    /// it with `nil`, and `nil` means cancel: a cancelled item cancels its
    /// whole group, so the entire folder transfer dies without the user ever
    /// having cancelled anything.
    @Test func aLateDismissalDoesNotCancelTheRestOfTheFolderTransfer() async {
        let bridge = ConflictPromptBridge()
        let (queue, destination) = startCollidingTree(bridge: bridge)

        guard let first = await awaitPrompt(bridge) else {
            Issue.record("the queue never prompted")
            return
        }
        #expect(first.conflict.fileName == "a.txt")
        #expect(first.conflict.isPartOfFolderTransfer)
        // The user picks "Skip" on the first sheet…
        bridge.resolve(promptID: first.id, (resolution: .skip, applyToAll: false))
        // …and the queue, with only a `stat` to do, is asking about the second
        // file long before that sheet has finished animating out.
        guard let second = await awaitPrompt(bridge, after: first.id) else {
            Issue.record("the queue did not prompt a second time")
            return
        }
        #expect(second.conflict.fileName == "b.txt")

        // NOW the first sheet's dismissal is delivered. It must be dropped:
        // "b.txt" is the open, unanswered question and the user has said
        // nothing about it.
        bridge.dismiss(promptID: first.id)
        #expect(bridge.currentPrompt?.id == second.id)

        // The user answers the second sheet on its own terms.
        bridge.resolve(promptID: second.id, (resolution: .skip, applyToAll: false))
        await settle(queue)

        #expect(status(queue, "a.txt") == .skipped)
        #expect(status(queue, "b.txt") == .skipped)   // NOT .cancelled
        // A cancelled item takes its whole group down — nothing else in the
        // folder may have been cancelled either.
        #expect(queue.items.allSatisfy { $0.status != .cancelled })
        // Skipping wrote nothing; both destinations keep their old content.
        #expect(await destination.writtenData(at: "/ziel/dir/a.txt") == nil)
        #expect(await destination.writtenData(at: "/ziel/dir/sub/b.txt") == nil)
    }

    /// The mirror of the above on the BUTTON path: a tap belonging to the first
    /// sheet must not answer the second question. The same sub-millisecond gap
    /// makes it real — the queue installs the next continuation while the
    /// answered sheet is still animating out and a double click, or a repeated
    /// press of `Overwrite`'s `.defaultAction` shortcut, is still being
    /// delivered. `Overwrite` is the destructive choice and `applyToAll` would
    /// spread it across the rest of the folder, so the wrong question getting
    /// it is the worst case.
    @Test func aStaleButtonTapDoesNotAnswerTheNextPrompt() async {
        let bridge = ConflictPromptBridge()
        let (queue, destination) = startCollidingTree(bridge: bridge)

        guard let first = await awaitPrompt(bridge) else {
            Issue.record("the queue never prompted")
            return
        }
        #expect(first.conflict.fileName == "a.txt")
        bridge.resolve(promptID: first.id, (resolution: .skip, applyToAll: false))
        guard let second = await awaitPrompt(bridge, after: first.id) else {
            Issue.record("the queue did not prompt a second time")
            return
        }
        #expect(second.conflict.fileName == "b.txt")

        // A second tap on the FIRST sheet's "Overwrite", with "apply to all".
        bridge.resolve(promptID: first.id, (resolution: .overwrite, applyToAll: true))
        #expect(bridge.currentPrompt?.id == second.id)

        // The user then actually answers "b.txt" — the stale tap consumed
        // nothing, and set no queue-wide overwrite rule behind their back.
        bridge.resolve(promptID: second.id, (resolution: .skip, applyToAll: false))
        await settle(queue)

        #expect(status(queue, "b.txt") == .skipped)
        #expect(await destination.writtenData(at: "/ziel/dir/sub/b.txt") == nil)
    }

    /// The net still does its job: a sheet that disappears WITHOUT an answer
    /// (the prompt it names is still the open one) cancels the transfer instead
    /// of leaving the queue suspended forever.
    @Test func anUnansweredDismissalStillCancelsTheTransfer() async {
        let bridge = ConflictPromptBridge()
        let (queue, _) = startCollidingTree(bridge: bridge)

        guard let prompt = await awaitPrompt(bridge) else {
            Issue.record("the queue never prompted")
            return
        }
        bridge.dismiss(promptID: prompt.id)
        await settle(queue)

        #expect(bridge.currentPrompt == nil)
        #expect(status(queue, "a.txt") == .cancelled)
    }

    /// Exactly-once, from the other side: an answer followed by more
    /// answers/dismissals must not resume a continuation twice (which traps).
    @Test func repeatedAnswersResumeTheContinuationOnlyOnce() async {
        let bridge = ConflictPromptBridge()
        let (queue, _) = startCollidingTree(bridge: bridge)

        guard let first = await awaitPrompt(bridge) else {
            Issue.record("the queue never prompted")
            return
        }
        // Double click on "Skip" with "apply to all", then the dismissal, then
        // a stale net for a prompt that is long gone.
        bridge.resolve(promptID: first.id, (resolution: .skip, applyToAll: true))
        bridge.resolve(promptID: first.id, (resolution: .overwrite, applyToAll: false))
        bridge.dismiss(promptID: first.id)
        await settle(queue)

        // "Apply to all" answered the second collision without a second
        // prompt, and neither extra call turned the run into a cancellation.
        #expect(status(queue, "a.txt") == .skipped)
        #expect(status(queue, "b.txt") == .skipped)
        #expect(queue.items.allSatisfy { $0.status != .cancelled })
    }

    /// Teardown's deliberately unattributed entry point: it cancels whichever
    /// prompt is open, because the window going away invalidates every prompt
    /// there could be. It MUST resolve the continuation — `cancelAll` hangs on
    /// an open decider prompt, which is the disconnect deadlock this call
    /// exists to prevent.
    @Test func teardownCancelsWhicheverPromptIsOpen() async {
        let bridge = ConflictPromptBridge()
        let (queue, _) = startCollidingTree(bridge: bridge)

        guard await awaitPrompt(bridge) != nil else {
            Issue.record("the queue never prompted")
            return
        }
        bridge.cancelOpenPrompt()
        await settle(queue)

        #expect(bridge.currentPrompt == nil)
        #expect(status(queue, "a.txt") == .cancelled)
    }

    /// A cancelled transfer task resolves an open prompt instead of leaving the
    /// continuation unfulfilled — otherwise the queue's conflict gate never
    /// reopens.
    @Test func cancellingTheAskingTaskResolvesTheOpenPrompt() async {
        let bridge = ConflictPromptBridge()
        let asking = Task {
            await bridge.ask(TransferConflict(
                fileName: "a.txt", destinationDirectory: "/ziel", direction: .download))
        }
        _ = await awaitPrompt(bridge)
        asking.cancel()

        let result = await asking.value
        #expect(result == nil)
        for _ in 0..<50 { await Task.yield() }
        #expect(bridge.currentPrompt == nil)
    }

    /// Calling `ask` a second time while a first `ask` is still pending must
    /// not silently overwrite `self.continuation` — that would leak the first
    /// continuation and hang whichever transfer is waiting on it forever,
    /// taking the conflict gate (and with it the whole queue) down with it.
    /// Unreachable through the queue today, which gates its prompts FIFO, but
    /// nothing enforces that structurally, so the bridge must not depend on it.
    @Test func aSecondAskResolvesTheStrandedFirstContinuation() async {
        let bridge = ConflictPromptBridge()
        let first = Task {
            await bridge.ask(TransferConflict(
                fileName: "first.txt", destinationDirectory: "/ziel", direction: .download))
        }
        _ = await awaitPrompt(bridge)
        #expect(bridge.currentPrompt?.conflict.fileName == "first.txt")

        let second = Task {
            await bridge.ask(TransferConflict(
                fileName: "second.txt", destinationDirectory: "/ziel", direction: .download))
        }
        // Let the second `ask` run far enough to strand-resolve the first and
        // install its own prompt.
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
        #expect(secondPrompt.conflict.fileName == "second.txt")
        bridge.resolve(promptID: secondPrompt.id, (resolution: .skip, applyToAll: false))
        let secondResult = await second.value
        #expect(secondResult?.resolution == .skip)
    }
}
