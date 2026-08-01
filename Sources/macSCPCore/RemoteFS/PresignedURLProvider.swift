import Foundation

/// The HTTP method a presigned URL is signed for: `.get` downloads the
/// object, `.put` uploads to it.
public enum PresignedMethod: String, Sendable {
    case get = "GET"
    case put = "PUT"
}

/// An OPTIONAL backend capability (queried via `as?`, like
/// `RemoteShellProvider`): produce a time-limited signed URL for a key.
/// `.get` downloads it, `.put` uploads to it. Pure — no network. `expiresIn`
/// is clamped to `[1s, 7 days]` (the SigV4 presigned-URL maximum).
public protocol PresignedURLProvider: Sendable {
    func presignedURL(method: PresignedMethod, key: String, expiresIn: TimeInterval) throws -> URL
}
