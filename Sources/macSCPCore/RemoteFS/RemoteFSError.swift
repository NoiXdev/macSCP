public enum RemoteFSError: Error, Equatable, Sendable {
    case connectionFailed(reason: String)
    case authenticationFailed
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
