import Foundation
import Observation

/// Sheet item wrapper: gives `TransferConflict` `Identifiable` conformance
/// without extending the conflict type via extension (binding requirement
/// M5b/T4). The id is what makes an event from the sheet ATTRIBUTABLE: it
/// names which question a late-arriving button tap or "the sheet went away"
/// refers to (see `ConflictPromptBridge.resolve(promptID:_:)` and
/// `dismiss(promptID:)`).
public struct ConflictPromptItem: Identifiable, Sendable {
    public let id = UUID()
    public let conflict: TransferConflict

    public init(conflict: TransferConflict) {
        self.conflict = conflict
    }
}

/// Holds the continuation for the transfer queue's `ConflictDecider` prompt —
/// the transfer twin of `ImportConflictBridge`, down to the cancellation
/// handler. A reference type (instead of a `@State` field directly on the
/// view) because `TransferQueueViewModel.conflictDecider` is a `@Sendable`
/// closure that outlives the `ContentView` struct. Owned per tab by
/// `SessionTab` (M8a/T3), so a background tab's prompt never presents on the
/// active tab.
///
/// Lives in Core (not next to the sheet in the app target) purely so it can be
/// tested: the app target has no test target, and the resumption rules below
/// are the kind of thing only a test driving two consecutive conflicts can
/// hold honest (`ConflictPromptBridgeTests`).
///
/// ## Exactly-once resumption
///
/// `finish(_:)` is the only place a STORED continuation is ever resumed, and
/// it takes `self.continuation` out before resuming. (The one other resume in
/// the file is `ask`'s `Task.isCancelled` fast path, which resumes the
/// continuation it was just handed without ever storing it — nothing else can
/// reach that one, so it cannot double-resume.) Everything else — the buttons,
/// the cancellation handler, the presenter's safety net, teardown — funnels
/// through `finish`, so the guarantee is a property of one short function
/// rather than of the call sites:
///
/// - **At most once.** `finish` finds `continuation == nil` on any second call
///   and returns without resuming. That alone is what makes a double
///   resumption (which would trap) impossible; it is NOT what makes a second
///   call harmless, see "the right question" below.
/// - **At least once.** `ask` hands the continuation out only after storing
///   it, and every route out of the sheet ends in `finish`: the four buttons
///   through `resolve(promptID:_:)`; a task cancelled mid-prompt through
///   `withTaskCancellationHandler`; a sheet that vanishes for a reason outside
///   its own buttons through `dismiss(promptID:)`; window teardown through
///   `cancelOpenPrompt()`; and a STRANDED continuation from a previous `ask`
///   that nothing ever resolved, which a new `ask` resolves (as `nil`) before
///   it stores its own. The sheet itself is
///   `.interactiveDismissDisabled(true)`, so Escape and click-outside cannot
///   answer behind the bridge's back.
/// - **The right question.** This is what `promptID` is for, and it is why a
///   second call is safe rather than merely non-trapping. Between two transfer
///   conflicts the queue does one remote `stat` over an already-open channel —
///   sub-millisecond, and on localhost or a LAN not even that — so it is back
///   inside `ask` with a NEW continuation long before the UI framework
///   reports that the first sheet closed, which it does only at the END of a
///   ~250 ms dismissal animation. The stale window here is WIDER than the
///   import twin's, not narrower. Anything that resolves "whatever is
///   current" therefore answers the SECOND question with the FIRST sheet's
///   event: a dismissal returns `nil`, which means cancel, and a cancelled
///   item cancels its whole group — the entire folder transfer dies although
///   the user only ever pressed "Skip" on one file. A stale tap on `Overwrite`
///   (the destructive choice, and with `applyToAll` a rule for the whole rest
///   of the queue) silently answers a question the user never saw. So BOTH
///   sheet-facing entry points name the prompt they are about and fire only
///   while that prompt is still the open one; `finish` itself is private, so
///   there is no unattributed way in from the UI.
@MainActor
@Observable
public final class ConflictPromptBridge {
    /// The open prompt — drives the presenter's `.sheet(item:)`.
    public private(set) var currentPrompt: ConflictPromptItem?
    private var continuation:
        CheckedContinuation<(resolution: ConflictResolution, applyToAll: Bool)?, Never>?

    public init() {}

    /// Decider side: awaited by `TransferQueueViewModel.conflictDecider`.
    /// Cancellation-safe: if the calling task is cancelled while the prompt is
    /// open, it resolves with `nil` (cancel) instead of hanging.
    public func ask(_ conflict: TransferConflict) async
        -> (resolution: ConflictResolution, applyToAll: Bool)?
    {
        // Guard against a stranded continuation: the queue gates its prompts
        // FIFO, so nothing today calls `ask` again while a first `ask` is
        // still pending — but nothing enforces that structurally either.
        // Without this, storing into `self.continuation` below would silently
        // overwrite a still-pending one, leaking it forever and hanging
        // whichever transfer is waiting on it (and with it the gate, and with
        // it the queue). Routes through `finish` — the one resume site — so
        // this stays "at least once" rather than a second ad hoc resumption
        // path.
        //
        // This is the one caller that names no prompt, deliberately: it is not
        // relaying a user event about some particular question (which is what
        // the id guard exists to attribute), it is tearing the previous prompt
        // down wholesale before replacing it. Whatever continuation is pending
        // at this instant is BY DEFINITION the stranded one — the caller of
        // this `ask` is the only thing that can still be resumed afterwards —
        // so there is nothing to attribute and nothing a guard could protect.
        finish(nil)
        let prompt = ConflictPromptItem(conflict: conflict)
        currentPrompt = prompt
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    currentPrompt = nil
                    continuation.resume(returning: nil)
                    return
                }
                self.continuation = continuation
            }
        } onCancel: {
            // Routes through `dismiss(promptID:)`, not `finish(nil)` directly
            // — "whatever is current" is exactly the ambiguous shape the
            // Critical fix (see the type's doc comment) removed from the
            // PRESENTER's dismissal net, and this net has the same hazard: the
            // queue can already be back inside `ask` for the NEXT conflict by
            // the time a cancellation from the FIRST one is delivered here.
            // It is harmless today only because a cancelled task's next `ask`
            // takes the `Task.isCancelled` fast path above and stores no
            // continuation for this to clobber — a coincidence of ordering,
            // not a guarantee. Naming the prompt keeps both nets symmetric.
            Task { @MainActor [weak self] in
                self?.dismiss(promptID: prompt.id)
            }
        }
    }

    /// Called from the sheet's four buttons: "the sheet showing prompt
    /// `promptID` was answered with `result`" — applied ONLY while that prompt
    /// is still the open one.
    ///
    /// The id is not ceremony. A button tap can be delivered twice (a double
    /// click, or a repeated press of the default action — `Overwrite` carries
    /// `.keyboardShortcut(.defaultAction)`) while the answered sheet is still
    /// animating out, and by then the queue has already installed the next
    /// conflict's continuation. Without the guard the second tap answers THAT
    /// conflict, with a resolution the user gave for a different file.
    public func resolve(
        promptID: UUID, _ result: (resolution: ConflictResolution, applyToAll: Bool)?
    ) {
        guard currentPrompt?.id == promptID else { return }
        finish(result)
    }

    /// Safety net for the presenter: "the sheet showing prompt `promptID` went
    /// away". Resolves as "cancel this transfer" — but ONLY while that prompt
    /// is still the open one.
    ///
    /// The guard is the whole point (see the type's doc comment). Both ways it
    /// can fail are exactly the cases where the sheet's disappearance carries
    /// no information: `currentPrompt` is nil because a button already
    /// answered, or it is a DIFFERENT prompt because the queue has since asked
    /// about the next file. Only an unanswered prompt still on screen matches
    /// — and that is the one case where somebody has to resume the
    /// continuation.
    public func dismiss(promptID: UUID) {
        resolve(promptID: promptID, nil)
    }

    /// Teardown entry point: cancels whichever prompt is open, if any. MUST
    /// run before `transferQueue.cancelAll()` — `cancelAll` blocks
    /// (documented) on an open decider prompt that would otherwise never be
    /// answered (deadlock on disconnect with an open sheet).
    ///
    /// Deliberately unattributed, and named so at the call site: unlike the
    /// two sheet-facing entry points above, this does not relay a user event
    /// about one particular question. It is the window going away, which
    /// invalidates every prompt there could be — there is nothing to
    /// attribute, and a guard here would only be able to skip work that must
    /// not be skipped.
    public func cancelOpenPrompt() {
        finish(nil)
    }

    /// The single resume site for a stored continuation: takes it out, then
    /// resumes it. Private on purpose — every route in from the UI names its
    /// prompt (see the type's doc comment); only `ask`'s stranded-continuation
    /// cleanup and `cancelOpenPrompt`, neither of which has a prompt to name,
    /// call it directly.
    private func finish(_ result: (resolution: ConflictResolution, applyToAll: Bool)?) {
        guard let continuation else {
            // No pending question — but a prompt may still be on screen from
            // the `Task.isCancelled` fast path above; make sure it goes away.
            currentPrompt = nil
            return
        }
        self.continuation = nil
        currentPrompt = nil
        continuation.resume(returning: result)
    }
}
