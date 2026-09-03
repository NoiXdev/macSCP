import Foundation
import Security
import os

/// What one keychain lookup answered (Cyberduck import, fix round 1).
///
/// Three states, not two, because "there is no item" and "no item could
/// exist, so nothing was asked" are different sentences and the caller
/// reports one of them to the user. Collapsed into a single `nil`, an import
/// of eight bookmarks — three of them written without a `Username`, which
/// Cyberduck stores no item for — told the user that three passwords "could
/// not be read from the keychain", about three items that do not exist and
/// were never looked for.
///
/// The precondition that decides `.notAttempted` lives HERE and only here:
/// a caller re-deriving it would hold a second copy of this reader's rule,
/// and the copies would part company the first time the reader learns about
/// another shape of bookmark.
///
/// Deliberately NOT `Equatable` and NOT `CustomStringConvertible`: the
/// secret lives inside `.found`, and both of those would give it a way onto
/// a screen or into a failure message. Callers pattern-match, which is also
/// what makes a fourth state a compile error at every call site rather than
/// a branch someone forgot.
public enum CyberduckSecretLookup: Sendable {
    /// The keychain returned an item. The associated value is the secret and
    /// goes straight into the caller's own `SecretStore` slot.
    case found(String)
    /// The query ran and matched nothing — the item is absent, or the user
    /// refused or cancelled the macOS consent prompt. This is the one state
    /// worth reporting to the user.
    case notFound
    /// No query was made, because the bookmark cannot have an item:
    /// Cyberduck stores none without an account, and none for a protocol it
    /// does not keep credentials for. Nothing failed, so nothing is reported.
    case notAttempted
}

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

    /// `.notAttempted` when the bookmark has no username (Cyberduck never
    /// stores an item without an account, so no query is made at all) or its
    /// protocol is one Cyberduck keeps no keychain item for
    /// (`.unsupported`). `.notFound` when the query ran and the item does not
    /// exist, or the user cancelled or was refused the macOS consent prompt;
    /// any other `OSStatus` resolves there too — only the status code is
    /// logged, never the query and never the value.
    ///
    /// Runs on its own dispatch queue, awaited through a continuation: the
    /// macOS consent dialog for a not-yet-trusted item can block the calling
    /// thread on user interaction, and that must never be a thread this
    /// process needs for anything else. The prompt itself belongs to
    /// whatever UI moment the caller is in — this function does not attempt
    /// to time it out or dismiss it.
    public func secret(for bookmark: ExternalBookmark) async -> CyberduckSecretLookup {
        guard let username = bookmark.username, !username.isEmpty else { return .notAttempted }
        guard let protocolName = Self.keychainProtocolName(for: bookmark.protocol)
        else { return .notAttempted }

        // Neither `[String: Any]` nor the `CFDictionary`/`CFString` it
        // bridges to is `Sendable`, so the query dictionary is built INSIDE
        // the queue closure below, from only plain `Sendable` values
        // (`String`/`Int`) captured here.
        let host = bookmark.host
        let port = bookmark.port

        return await withCheckedContinuation {
            (continuation: CheckedContinuation<CyberduckSecretLookup, Never>) in
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
                    // An item that came back without decodable data is a
                    // query that ran and produced no secret — `.notFound`,
                    // not `.notAttempted`: something was asked for.
                    guard let data = result as? Data,
                        let value = String(data: data, encoding: .utf8)
                    else {
                        continuation.resume(returning: .notFound)
                        return
                    }
                    continuation.resume(returning: .found(value))
                case errSecItemNotFound, errSecUserCanceled, errSecAuthFailed,
                    errSecInteractionNotAllowed:
                    continuation.resume(returning: .notFound)
                default:
                    Self.logger.debug("Cyberduck secret query failed, status \(status)")
                    continuation.resume(returning: .notFound)
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
