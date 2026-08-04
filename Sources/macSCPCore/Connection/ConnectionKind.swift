/// The protocol a connection speaks (M12). The single discriminator threaded
/// through config, session persistence, the connector dispatcher and the UI.
/// Open for future protocols (webdav/ftp/smb).
public enum ConnectionKind: String, Codable, CaseIterable, Sendable {
    case ssh
    case s3
    case webdav
}
