import Foundation
import Security
import os

/// Answers ONE question about a keychain slot: is something stored there.
///
/// The seam the session overview is built on. The overview shows a fact
/// about a stored session's credential — that one exists — and must never
/// hold the credential itself, so it is handed this instead of a
/// `SecretStore`. The difference is not a convention the view has to keep:
/// `Bool` has no way of carrying a password, so a view built on this
/// protocol cannot leak one however it is written.
///
/// Deliberately NOT an extension of `SecretStore`: that protocol's
/// `password(for:)` returns the value, and a type that offers both would
/// put the value back within reach of every caller that only wanted the
/// question answered.
///
/// Synchronous, unlike `CyberduckSecretReader.secret(for:)`, which awaits a
/// continuation because a not-yet-trusted item's macOS consent dialog can
/// block the calling thread on user interaction. A metadata-only query
/// raises no such dialog — see `KeychainSecretPresence.hasSecret(for:)`.
public protocol SecretPresence: Sendable {
    /// Whether a secret is stored in `slot`.
    ///
    /// The slot, not the session id: a session in a login set does not own
    /// its credential — the SET does, under the set's id. That distinction
    /// is `StoredSession.secretSlot`, and asking with the wrong one reports
    /// "no secret" for a session that has one.
    func hasSecret(for slot: UUID) -> Bool
}

/// The real answer, from the same login-keychain items `KeychainSecretStore`
/// writes: same `kSecClassGenericPassword` class, same service, same
/// account (the slot's UUID string).
///
/// **Metadata only.** The query below sets `kSecReturnAttributes` and NEVER
/// `kSecReturnData` — the shape `CyberduckSecretReader` uses, minus the one
/// line that returns the value. Two things follow, and both are the reason
/// this type exists rather than a `password(for:) != nil` call:
///
/// 1. The secret is never read into this process, so it cannot be logged,
///    interpolated, described or rendered. There is no value to be careful
///    with.
/// 2. An item's ACL governs its DATA. A query that asks only for attributes
///    does not raise the macOS consent dialog that a first read from a new
///    binary raises — so opening the overview for a session cannot put a
///    keychain prompt in front of a user who only clicked a row.
///
/// Never constructed by a test: this suite's tests hand the model a fake
/// (`SessionOverviewModelTests.FakeSecretPresence`). A test that touched
/// the real login keychain would belong behind `MACSCP_KEYCHAIN=1`, and
/// there is nothing here worth that — the query is four constants and a
/// status comparison.
public struct KeychainSecretPresence: SecretPresence {
    private static let logger = Logger(
        subsystem: "dev.noix.macscp", category: "KeychainSecretPresence")

    private let service: String

    /// The same default service `KeychainSecretStore` writes under — the two
    /// address one set of items, so a slot this reports on is a slot that
    /// store filled.
    public init(service: String = "dev.noix.macSCP") {
        self.service = service
    }

    public func hasSecret(for slot: UUID) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: slot.uuidString,
            // Attributes, never data. See this type's doc comment.
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return true
        case errSecItemNotFound:
            return false
        default:
            // Anything else is "this process could not find out", and the
            // safe direction is to report absence: the overview then shows
            // "no secret stored" for a session that may have one, which is a
            // wrong label. Reporting presence for a slot that could not be
            // read would be a wrong PROMISE — the connect that follows would
            // fail with a missing credential. Only the status code is
            // logged, never the query and never anything from the item.
            Self.logger.debug("keychain presence query failed, status \(status)")
            return false
        }
    }
}
