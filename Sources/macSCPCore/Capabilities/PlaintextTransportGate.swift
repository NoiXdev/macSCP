import Foundation

/// Decides whether a connection would send credentials in the clear and must
/// therefore be confirmed by the user.
///
/// This is the FIRST reader of `ProtocolCapabilities.transport` (M21). Until
/// now the axis was declared and set on every backend but consulted nowhere —
/// decoration. The rule lives here, once, and reads the capability rather than
/// the kind, so a fourth backend is covered by construction.
public enum PlaintextTransportGate {
    /// Which kind of plaintext a gated connection is, so the confirmation can
    /// name the remedy the user's protocol actually has: a web endpoint is
    /// told about the encrypted scheme, a plain FTP session about FTPS, which
    /// FTP has and the scheme does not.
    public enum Kind: Equatable, Sendable {
        /// WebDAV or S3 dialled over an unencrypted web scheme.
        case http
        /// FTP in its plain security mode.
        case plainFTP
    }

    /// Whether the user must confirm before credentials are sent. Defined
    /// through `kind(for:)`, so the question and the sentence under it cannot
    /// disagree.
    public static func requiresConfirmation(for config: ConnectionConfig) -> Bool {
        kind(for: config) != nil
    }

    /// The kind of plaintext this config is, or `nil` when it needs no
    /// confirmation. The ONE place the answer is computed.
    public static func kind(for config: ConnectionConfig) -> Kind? {
        let capabilities = BackendDescriptor.descriptor(for: config.kind).capabilities
        // The capability decides WHETHER the question applies; the config
        // decides whether this particular endpoint is plaintext.
        guard capabilities.transport == .optionalTLS else { return nil }
        return plaintextKind(config)
    }

    private static func plaintextKind(_ config: ConnectionConfig) -> Kind? {
        switch config {
        case .ssh:
            return nil
        case .s3(let s3):
            // The ONE endpoint parse, not a second reading of the string
            // (review 2026-09-04). A `hasPrefix("http://")` test of its own
            // answered "encrypted" for a pasted endpoint with a leading
            // space, and would answer the same for any spelling the parse
            // reads differently — the gate and the dial must never disagree
            // about the scheme. A schemeless endpoint is `https` here for
            // exactly that reason: it is what the dial will use.
            return S3FieldSchema.endpointComponents(s3.endpoint)?.scheme?.lowercased() == "http"
                ? .http : nil
        case .webdav(let webdav):
            // Reuses the config's own property rather than re-deriving the
            // rule — two copies of "is this plaintext?" would drift.
            return webdav.isPlaintextTransport ? .http : nil
        case .ftp(let ftp):
            // Only the plain mode: explicit FTPS upgrades before the login is
            // sent, and implicit FTPS is TLS from the first byte. The gate
            // asks two questions -- the capability (`.optionalTLS`) decides
            // whether the question applies at all, this decides whether THIS
            // endpoint is plaintext -- so three security modes need no
            // per-connection capability field.
            return ftp.security == .plain ? .plainFTP : nil
        }
    }
}
