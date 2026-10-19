import Foundation

/// A bucket's versioning state, as the store reports it and as a caller may
/// ask it to become.
///
/// Three states, and the third is not writable. `.never` is what an ABSENT
/// `<Status>` element means: a bucket versioning has never been switched on
/// for. S3 has no request that returns a bucket to that state — once
/// versioning has been enabled the most a caller can do is `.suspended` — so
/// `.never` exists only as a READ result, and writing it is refused
/// (`S3SettingsXML.versioningBody`).
public enum BucketVersioning: String, Sendable, CaseIterable {
    case never, enabled, suspended
}

/// An OPTIONAL backend capability (queried via `as?`, like
/// `PresignedURLProvider` and `RemoteShellProvider`): the settings of a
/// bucket, as opposed to the objects in it.
///
/// Every method names its bucket. The connection's own bucket is a property
/// of how it was opened (`RootMode`), and a connection that starts at the
/// account's bucket list has no single bucket at all, so nothing here reads
/// one from the connection.
///
/// The bucket argument is NOT validated here: an empty or malformed name
/// goes into the request as given. Name validation belongs to
/// `S3BucketName.problem(with:)`, which the create-bucket task of the
/// bucket-settings plan introduces, and callers that take a name from a user
/// run it before calling.
///
/// One protocol for all of a bucket's settings rather than one per setting:
/// a backend either speaks bucket-level S3 or it does not, and a caller
/// asking `as? S3BucketSettings` is asking exactly that. Each setting adds
/// its methods here and its conformance in the extension at the bottom of
/// `S3FileSystem.swift`.
public protocol S3BucketSettings: Sendable {
    /// The versioning state of `bucket`. `.never` when the store reports no
    /// status at all.
    func versioning(ofBucket bucket: String) async throws -> BucketVersioning

    /// Switches versioning of `bucket` to `.enabled` or `.suspended`.
    /// `.never` is unrepresentable at the store and throws
    /// `RemoteFSError.finding(.operationNotSupported)` before any request.
    func setVersioning(_ state: BucketVersioning, ofBucket bucket: String) async throws

    /// The CORS rules of `bucket`, in the order the store returned them, or
    /// `nil` when none are configured at all (`NoSuchCORSConfiguration`).
    /// `nil` and `[]` are different answers: a bucket whose configuration
    /// exists and holds zero rules reads back as `[]`.
    func cors(ofBucket bucket: String) async throws -> [CORSRule]?

    /// Replaces `bucket`'s CORS configuration with `rules`. Every rule goes
    /// through `CORSRule.validate()` first, and a rule that fails throws
    /// `RemoteFSError.protocolError` naming the failure before any request is
    /// built — the store cannot be relied on to refuse what S3 refuses. A UI
    /// that wants to explain a refusal in the user's language calls
    /// `validate()` itself first; this error is the backstop, not the message.
    func setCORS(_ rules: [CORSRule], ofBucket bucket: String) async throws
}

/// One `<CORSRule>` of a bucket's CORS configuration.
///
/// `id` is the rule's own optional `<ID>` label. It satisfies `Identifiable`
/// because the interface asks for it, but it is NOT an identity: it is
/// optional, two rules may share one, and a store may drop it. A caller that
/// needs to tell rules apart (a list in a UI) must not lean on it.
public struct CORSRule: Sendable, Equatable, Identifiable {
    public let id: String?
    public var allowedOrigins: [String]
    public var allowedMethods: [String]
    public var allowedHeaders: [String]
    public var exposeHeaders: [String]
    public var maxAgeSeconds: Int?

    public init(
        id: String?, allowedOrigins: [String], allowedMethods: [String],
        allowedHeaders: [String], exposeHeaders: [String], maxAgeSeconds: Int?
    ) {
        self.id = id
        self.allowedOrigins = allowedOrigins
        self.allowedMethods = allowedMethods
        self.allowedHeaders = allowedHeaders
        self.exposeHeaders = exposeHeaders
        self.maxAgeSeconds = maxAgeSeconds
    }

    /// The methods S3 accepts in `<AllowedMethod>`, exactly. Case matters:
    /// S3 refuses `get`.
    public static let allowedMethodNames: [String] = ["GET", "PUT", "POST", "DELETE", "HEAD"]

    /// macSCP's own gate, run by `setCORS` before anything is sent.
    ///
    /// It exists because the store is not the gate: the Docker rig (RustFS)
    /// STORES a rule whose method is `FETCH` and reads it back unchanged,
    /// while AWS refuses it. It does check structure (a rule with no
    /// `AllowedOrigin` is a 400), so what it cannot be trusted with is the
    /// vocabulary. A test against the rig would pass either way, which is
    /// why the refusal is pinned in `S3CORSTests`, before the transport.
    ///
    /// Checked in this order: an origin, a method, then each method against
    /// `allowedMethodNames`; the first failure is the answer.
    public func validate() -> CORSValidation {
        if allowedOrigins.isEmpty { return .noOrigin }
        if allowedMethods.isEmpty { return .noMethod }
        for method in allowedMethods where !Self.allowedMethodNames.contains(method) {
            return .methodNotAllowed(method)
        }
        return .ok
    }
}

/// The answer of `CORSRule.validate()`.
public enum CORSValidation: Equatable, Sendable {
    case ok
    case methodNotAllowed(String)
    case noOrigin
    case noMethod
}
