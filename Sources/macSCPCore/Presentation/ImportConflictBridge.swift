import Foundation
import Observation

/// Sheet item wrapper giving `ImportConflict` `Identifiable` conformance
/// without extending the conflict type itself — same reason the transfer
/// side's `ConflictPromptItem` exists. The id is what makes an event from
/// the sheet ATTRIBUTABLE: it names which question a late-arriving button
/// tap or "the sheet went away" refers to (see
/// `ImportConflictBridge.resolve(promptID:_:)` and `dismiss(promptID:)`).
public struct ImportConflictPromptItem: Identifiable, Sendable {
    public let id = UUID()
    public let conflict: ImportConflict

    public init(conflict: ImportConflict) {
        self.conflict = conflict
    }
}

/// Turns a conflict sheet's two callbacks into the `(resolution,
/// applyToAll)?` an `ImportConflictArbiter`'s decider must return — the
/// import twin of the transfer queue's `ConflictPromptBridge`, down to the
/// cancellation handler.
///
/// Lives in Core (not next to the sheet in the app target) purely so it can
/// be tested: the app target has no test target, and the resumption rules
/// below are the kind of thing that only a test driving two consecutive
/// conflicts can hold honest.
///
/// ## Exactly-once resumption
///
/// `finish(_:)` is the ONLY place a continuation is ever resumed, and it
/// takes `self.continuation` out before resuming. Everything else — the
/// buttons, the cancellation handler, the presenter's safety net — funnels
/// through it, so the guarantee is a property of one five-line function
/// rather than of the call sites:
///
/// - **At most once.** `finish` finds `continuation == nil` on any second
///   call and returns without resuming. That alone is what makes a double
///   resumption (which would trap) impossible; it is NOT what makes a second
///   call harmless, see "the right question" below.
/// - **At least once.** `ask` hands the continuation out only after storing
///   it, and every route out of the sheet ends in `finish`: the four buttons
///   through `resolve(promptID:_:)`; a task cancelled mid-prompt through
///   `withTaskCancellationHandler`; a sheet that vanishes for a reason
///   outside its own buttons through `dismiss(promptID:)`; and a STRANDED
///   continuation from a previous `ask` that nothing ever resolved, which a
///   new `ask` resolves (as `nil`) before it stores its own. The sheet itself
///   is `.interactiveDismissDisabled(true)`, so Escape and click-outside
///   cannot answer behind the bridge's back.
/// - **The right question.** This is what `promptID` is for, and it is why a
///   second call is safe rather than merely non-trapping. An import's planner
///   is pure computation: between two conflicts there is no I/O at all, so it
///   is back inside `ask` with a NEW continuation microseconds after the
///   first one resumes — long before the UI framework gets around to
///   reporting that the first sheet closed, and well within the window in
///   which a double click or a repeated default-action key press on the FIRST
///   sheet is still being delivered. Anything that resolves "whatever is
///   current" therefore answers the SECOND question with the FIRST sheet's
///   event: a dismissal cancels an import the user never cancelled, and a
///   stale tap on `Replace` (the destructive choice, which also overwrites
///   stored secrets — and with `applyToAll` spreads that across the rest of
///   the run) silently answers a question the user never saw. (The transfer
///   twin only survives this because real network I/O sits between two
///   transfer conflicts.) So BOTH sheet-facing entry points name the prompt
///   they are about and fire only while that prompt is still the open one;
///   `finish` itself is private, so there is no unattributed way in from the
///   UI.
@MainActor
@Observable
public final class ImportConflictBridge {
    /// The open prompt — drives the presenter's `.sheet(item:)`.
    public private(set) var currentPrompt: ImportConflictPromptItem?
    private var continuation:
        CheckedContinuation<(resolution: ImportConflictResolution, applyToAll: Bool)?, Never>?

    public init() {}

    /// Decider side: awaited by `ImportConflictArbiter`.
    public func ask(_ conflict: ImportConflict) async
        -> (resolution: ImportConflictResolution, applyToAll: Bool)?
    {
        // Guard against a stranded continuation: nothing today calls `ask`
        // twice without the first having resolved (one bridge per view, one
        // planning task each), but nothing enforces that structurally either.
        // Without this, storing into `self.continuation` below would silently
        // overwrite a still-pending one, leaking it forever and hanging
        // whichever import is waiting on it. Routes through `finish` — the
        // one resume site — so this stays "at least once" rather than a
        // second ad hoc resumption path.
        //
        // This is the one caller that names no prompt, deliberately: it is
        // not relaying a user event about some particular question (which is
        // what the id guard exists to attribute), it is tearing the previous
        // prompt down wholesale before replacing it. Whatever continuation is
        // pending at this instant is BY DEFINITION the stranded one — the
        // caller of this `ask` is the only thing that can still be resumed
        // afterwards — so there is nothing to attribute and nothing a guard
        // could protect. Going through `resolve(promptID:_:)` with
        // `currentPrompt?.id` would be the same call with extra steps when a
        // prompt is open, and would silently skip the cleanup when the
        // stranding left `currentPrompt` nil — exactly the case that must not
        // be skipped.
        finish(nil)
        let prompt = ImportConflictPromptItem(conflict: conflict)
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
            // Routes through `dismiss(promptID:)`, not `finish(nil)`
            // directly — "whatever is current" is exactly the ambiguous
            // shape the Critical fix (see the type's doc comment) removed
            // from the PRESENTER's dismissal net, and this net has the same
            // hazard: an import planner does no I/O between two conflicts, so
            // it can already be back inside `ask` for the NEXT question by
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
    /// `promptID` was answered with `result`" — applied ONLY while that
    /// prompt is still the open one.
    ///
    /// The id is not ceremony. A button tap can be delivered twice (a double
    /// click, or a repeated press of the default action — `Replace` carries
    /// `.keyboardShortcut(.defaultAction)`) while the answered sheet is still
    /// animating out, and by then the planner has already installed the next
    /// question's continuation. Without the guard the second tap answers THAT
    /// question, with a resolution the user gave for a different item.
    public func resolve(
        promptID: UUID, _ result: (resolution: ImportConflictResolution, applyToAll: Bool)?
    ) {
        guard currentPrompt?.id == promptID else { return }
        finish(result)
    }

    /// Safety net for the presenter: "the sheet showing prompt `promptID`
    /// went away". Resolves as "cancel the import" — but ONLY while that
    /// prompt is still the open one.
    ///
    /// The guard is the whole point (see the type's doc comment). Both ways
    /// it can fail are exactly the cases where the sheet's disappearance
    /// carries no information: `currentPrompt` is nil because a button
    /// already answered, or it is a DIFFERENT prompt because the planner has
    /// since asked the next question. Only an unanswered prompt still on
    /// screen matches — and that is the one case where somebody has to
    /// resume the continuation.
    public func dismiss(promptID: UUID) {
        resolve(promptID: promptID, nil)
    }

    /// The single resume site: takes the continuation out, then resumes it.
    /// Private on purpose — every route in from the UI names its prompt (see
    /// the type's doc comment), and only `ask`'s stranded-continuation
    /// cleanup, which has no prompt to name, calls this directly.
    private func finish(_ result: (resolution: ImportConflictResolution, applyToAll: Bool)?) {
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
