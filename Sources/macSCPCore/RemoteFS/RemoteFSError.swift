public enum RemoteFSError: Error, Equatable, Sendable {
    case connectionFailed(reason: String)
    case authenticationFailed
    case notFound(path: String)
    case permissionDenied(path: String)
    case protocolError(reason: String)
}
