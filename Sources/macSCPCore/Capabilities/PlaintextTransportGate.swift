import Foundation

/// Decides whether a connection would send credentials in the clear and must
/// therefore be confirmed by the user.
///
/// This is the FIRST reader of `ProtocolCapabilities.transport` (M21). Until
/// now the axis was declared and set on every backend but consulted nowhere —
/// decoration. The rule lives here, once, and reads the capability rather than
/// the kind, so a fourth backend is covered by construction.
public enum PlaintextTransportGate {
    public static func requiresConfirmation(for config: ConnectionConfig) -> Bool {
        let capabilities = BackendDescriptor.descriptor(for: config.kind).capabilities
        // The capability decides WHETHER the question applies; the config
        // decides whether this particular endpoint is plaintext.
        guard capabilities.transport == .optionalTLS else { return false }
        return isPlaintext(config)
    }

    private static func isPlaintext(_ config: ConnectionConfig) -> Bool {
        switch config {
        case .ssh:
            return false
        case .s3(let s3):
            return s3.endpoint.lowercased().hasPrefix("http://")
        case .webdav(let webdav):
            // Reuses the config's own property rather than re-deriving the
            // rule — two copies of "is this plaintext?" would drift.
            return webdav.isPlaintextTransport
        }
    }
}
