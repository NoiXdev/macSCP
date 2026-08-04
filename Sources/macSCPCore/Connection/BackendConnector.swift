import Foundation

/// Routes a typed `ConnectionConfig` to the concrete backend (M12). SSH keeps
/// its TOFU host-key decider; S3 ignores the decider (no host keys); WebDAV
/// (M21) needs its OWN decider -- a server-certificate one, not a host-key
/// one -- since it authenticates over TLS rather than SSH.
public enum BackendConnector {
    /// `certificateDecider` defaults to refusing (`{ _ in false }`): a caller
    /// with no way to ask the user (e.g. a future non-interactive path) must
    /// not silently trust an unknown certificate. Added as a second,
    /// defaulted parameter (M21) so every existing call site -- none of
    /// which knows about WebDAV -- keeps compiling unchanged.
    public static func connect(
        _ config: ConnectionConfig,
        decider: @escaping ConnectionViewModel.HostKeyDecider,
        certificateDecider: @escaping WebDAVSessionDelegate.CertificateDecider = { _ in false }
    ) async throws -> any RemoteFileSystem {
        switch config {
        case .ssh(let ssh):
            return try await CitadelFileSystem.connect(
                config: ssh,
                knownHosts: KnownHostsStore(directory: SessionStore.defaultDirectory),
                onUnknownHostKey: decider)
        case .s3(let s3):
            return try await S3FileSystem.connect(s3)
        case .webdav(let webdav):
            return try await WebDAVFileSystem.connect(
                webdav,
                trustStore: TrustedCertificateStore(directory: SessionStore.defaultDirectory),
                decider: certificateDecider)
        }
    }
}
