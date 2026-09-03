import Foundation
import Security
import os

/// Reads the Internet-password item Cyberduck stores in the login keychain
/// for a bookmark. Cyberduck writes one `kSecClassInternetPassword` item per
/// bookmark it has a credential for: `kSecAttrServer` is the host,
/// `kSecAttrAccount` the username (for S3, the access key), `kSecAttrPort`
/// the port when the bookmark has one, and `kSecAttrProtocol` is
/// `kSecAttrProtocolSSH` for an sftp bookmark or `kSecAttrProtocolHTTPS` for
/// an S3 one.
///
/// macSCP never writes to these items, never caches what it reads outside
/// the caller's own `SecretStore` slot, and reads only what one query
/// returns — never anything named in `ExternalBookmark` beyond host,
/// account, port and protocol.
public struct CyberduckSecretReader: Sendable {
    private static let logger = Logger(
        subsystem: "dev.noix.macscp", category: "CyberduckSecretReader")

    public init() {}

    /// `nil` when: the bookmark has no username (Cyberduck never stores an
    /// item without an account, so no query is made at all); the bookmark's
    /// protocol is one Cyberduck does not keep a keychain item for
    /// (`.unsupported`); the item does not exist; or the user cancels or is
    /// refused the macOS consent prompt. Any other `OSStatus` also resolves
    /// to `nil` here — only the status code is logged, never the query or
    /// the value.
    ///
    /// Runs on its own dispatch queue, awaited through a continuation: the
    /// macOS consent dialog for a not-yet-trusted item can block the calling
    /// thread on user interaction, and that must never be a thread this
    /// process needs for anything else. The prompt itself belongs to
    /// whatever UI moment the caller is in — this function does not attempt
    /// to time it out or dismiss it.
    public func secret(for bookmark: ExternalBookmark) async -> String? {
        guard let username = bookmark.username, !username.isEmpty else { return nil }
        guard let protocolName = Self.keychainProtocolName(for: bookmark.protocol) else { return nil }

        // Neither `[String: Any]` nor the `CFDictionary`/`CFString` it
        // bridges to is `Sendable`, so the query dictionary is built INSIDE
        // the queue closure below, from only plain `Sendable` values
        // (`String`/`Int`) captured here.
        let host = bookmark.host
        let port = bookmark.port

        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            DispatchQueue(label: "dev.noix.macSCP.cyberduck-secret-reader").async {
                var query: [String: Any] = [
                    kSecClass as String: kSecClassInternetPassword,
                    kSecAttrServer as String: host,
                    kSecAttrAccount as String: username,
                    kSecAttrProtocol as String: protocolName,
                    kSecReturnData as String: true,
                    kSecMatchLimit as String: kSecMatchLimitOne,
                ]
                if let port {
                    query[kSecAttrPort as String] = port
                }

                var result: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &result)
                switch status {
                case errSecSuccess:
                    guard let data = result as? Data,
                        let value = String(data: data, encoding: .utf8)
                    else {
                        continuation.resume(returning: nil)
                        return
                    }
                    continuation.resume(returning: value)
                case errSecItemNotFound, errSecUserCanceled, errSecAuthFailed,
                    errSecInteractionNotAllowed:
                    continuation.resume(returning: nil)
                default:
                    Self.logger.debug("Cyberduck secret query failed, status \(status)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// The `kSecAttrProtocol` value, as the plain `String` it bridges
    /// to — kept `Sendable` so it can be captured across the queue
    /// boundary and turned back into the matching `CFString` constant only
    /// once already inside the closure that runs the query.
    private static func keychainProtocolName(for protocolValue: ExternalProtocol) -> String? {
        switch protocolValue {
        case .sftp: return kSecAttrProtocolSSH as String
        case .s3: return kSecAttrProtocolHTTPS as String
        case .unsupported: return nil
        }
    }
}
