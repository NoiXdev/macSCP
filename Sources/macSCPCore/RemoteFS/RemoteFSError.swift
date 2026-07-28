public enum RemoteFSError: Error, Equatable, Sendable {
    case connectionFailed(reason: String)
    case authenticationFailed
    /// Stage-1 (jump host) authentication failure (M10c). Kept distinct from
    /// `.authenticationFailed` so the connect form can highlight the jump
    /// credentials instead of the target's. `isConnectionFailure` deliberately
    /// stays false so a mid-transfer classification can never mark it
    /// resumable.
    case jumpAuthenticationFailed
    case notFound(path: String)
    case permissionDenied(path: String)
    case protocolError(reason: String)

    /// True only for `.connectionFailed`. The transfer queue (M5d/T3) uses
    /// this — and ONLY this — to classify a mid-transfer error as
    /// `.interrupted` (resumable) rather than `.failed`.
    public var isConnectionFailure: Bool {
        if case .connectionFailed = self { return true }
        return false
    }
}
