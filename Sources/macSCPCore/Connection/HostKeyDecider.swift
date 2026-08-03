import Foundation

/// Asked when a host key is UNKNOWN — never on a mismatch, which is a hard
/// stop with no override (M3c invariant). Lives in `Connection/` rather than
/// on `ConnectionViewModel` because non-UI callers need it too: the CLI has no
/// view model but still has to answer this question (M20).
public typealias HostKeyDecider = @Sendable (HostKeyCandidate) async -> Bool
