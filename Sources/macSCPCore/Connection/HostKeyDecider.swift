import Foundation

/// The answer to "this host key is UNKNOWN — trust it?".
///
/// A type rather than a closure, and that is the whole point. As a bare
/// `@Sendable (HostKeyCandidate) async -> Bool`, any call site could pass
/// `{ _ in true }` and answer the question on the user's behalf — which is
/// exactly what a source guard caught six times in six different spellings,
/// each looking complete from inside the previous round. What a caller can
/// write now is a factory with a name.
///
/// Never asked on a MISMATCH: `HostKeyValidation` stops that before any
/// decider is consulted, and no factory here can change that.
///
/// Lives in `Connection/` rather than on `ConnectionViewModel` because non-UI
/// callers need it too: the command-line tool has no view model but still has
/// to answer this question.
public struct HostKeyDecider: Sendable {
    private let answer: @Sendable (HostKeyCandidate) async -> Bool

    private init(_ answer: @escaping @Sendable (HostKeyCandidate) async -> Bool) {
        self.answer = answer
    }

    public func callAsFunction(_ candidate: HostKeyCandidate) async -> Bool {
        await answer(candidate)
    }

    /// Puts the question to someone who answers it — the app's prompt, the
    /// CLI's policy and its terminal. The closure PRESENTS; it is not meant
    /// to decide on its own.
    ///
    /// Who builds one, checked while writing this: `ConnectionViewModel
    /// .connect`, which wraps its own host-key prompt, and the command-line
    /// tool's `makeDecider`, which wraps its policy and its terminal. The App
    /// layer builds none at all — its connector closure RECEIVES the view
    /// model's decider and passes it along. Nothing scans for an `asking`
    /// that answers by itself; the factory's name is what a reader gets
    /// instead, which is already more than a bare closure gave them.
    public static func asking(
        _ present: @escaping @Sendable (HostKeyCandidate) async -> Bool
    ) -> HostKeyDecider {
        HostKeyDecider(present)
    }

    /// Answers no without asking anyone. For callers with nobody to ask.
    public static let refusing = HostKeyDecider { _ in false }
}
