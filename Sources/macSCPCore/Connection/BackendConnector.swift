import Foundation

/// Routes a typed `ConnectionConfig` to the concrete backend (M12). SSH keeps
/// its TOFU host-key decider; S3 ignores the decider (no host keys).
public enum BackendConnector {
    public static func connect(
        _ config: ConnectionConfig,
        decider: @escaping ConnectionViewModel.HostKeyDecider
    ) async throws -> any RemoteFileSystem {
        switch config {
        case .ssh(let ssh):
            return try await CitadelFileSystem.connect(
                config: ssh,
                knownHosts: KnownHostsStore(directory: SessionStore.defaultDirectory),
                onUnknownHostKey: decider)
        case .s3(let s3):
            return try await S3FileSystem.connect(s3)
        }
    }
}
