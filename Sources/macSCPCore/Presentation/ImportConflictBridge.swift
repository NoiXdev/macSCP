import Foundation
import Observation

/// Sheet item wrapper giving `ImportConflict` `Identifiable` conformance
/// without extending the conflict type itself — same reason the transfer
/// side's `ConflictPromptItem` exists. The id is what makes a dismissal
/// ATTRIBUTABLE: it names which question a late-arriving "the sheet went
/// away" refers to (see `ImportConflictBridge.dismiss(promptID:)`).
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
/// `resolve(_:)` is the ONLY place a continuation is ever resumed, and it
/// takes `self.continuation` out before resuming. Everything else — the
/// buttons, the cancellation handler, the presenter's safety net — funnels
/// through it, so the guarantee is a property of one five-line function
/// rather than of the call sites:
///
/// - **At most once.** A second call (double click, or a dismissal racing a
///   button tap) finds `continuation == nil` and returns without resuming.
/// - **At least once.** `ask` hands the continuation out only after storing
///   it, and every route out of the sheet ends in `resolve`: the four
///   buttons directly; a task cancelled mid-prompt through
///   `withTaskCancellationHandler`; and a sheet that vanishes for a reason
///   outside its own buttons through `dismiss(promptID:)`. The sheet itself
///   is `.interactiveDismissDisabled(true)`, so Escape and click-outside
///   cannot answer behind the bridge's back.
/// - **The right question.** This is what `promptID` is for. An import's
///   planner is pure computation: between two conflicts there is no I/O at
///   all, so it is back inside `ask` with a NEW continuation microseconds
///   after the first one resumes — long before the UI framework gets around
///   to reporting that the first sheet closed. A safety net that resolves
///   "whatever is current" therefore answers the SECOND question with the
///   FIRST sheet's dismissal, cancelling an import the user never cancelled.
///   (The transfer twin only survives this because real network I/O sits
///   between two transfer conflicts.) So the net names the prompt it is
///   about, and fires only while that prompt is still the open one.
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
        currentPrompt = ImportConflictPromptItem(conflict: conflict)
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
            Task { @MainActor [weak self] in
                self?.resolve(nil)
            }
        }
    }

    /// Called from the sheet's buttons. The single resume site; a second
    /// resolution is ignored (see the type's doc comment).
    public func resolve(_ result: (resolution: ImportConflictResolution, applyToAll: Bool)?) {
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
        guard currentPrompt?.id == promptID else { return }
        resolve(nil)
    }
}
