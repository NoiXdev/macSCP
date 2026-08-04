import Foundation

/// Thrown when a write to the target store reports success but the
/// immediate read-back disagrees with what was just written. Kept distinct
/// from `KeychainError` — a raw Security-framework call failure — so a
/// caller can tell "the keychain call failed" from "the keychain reported
/// success but the value disagrees". `errSecIO` is a status a real
/// `SecItemCopyMatching` call can genuinely return, so reusing it here would
/// have made the two indistinguishable.
public struct KeychainVerificationMismatch: Error, Equatable, Sendable {}

/// Moves secrets from one store to another — in principle from "no access
/// group" to "shared access group", so the CLI can read what the app wrote
/// (M20). The access group is an attribute set at creation time, so existing
/// entries have to be rewritten; without this, the CLI would fail on exactly
/// the sessions a user has had the longest.
///
/// - Warning: **This type has no production call site, and must not get one
///   while `KeychainSecretStore` talks to the legacy file-based keychain.**
///   On macOS, `kSecAttrAccessGroup` is honored only by the data-protection
///   keychain, which a query opts into with `kSecUseDataProtectionKeychain`.
///   `KeychainSecretStore.baseQuery` sets no such flag, so the group
///   attribute is silently dropped and `KeychainSecretStore(accessGroup:)`
///   and `KeychainSecretStore()` address the *same* item. `migrate` would
///   then read that item, overwrite it in place, "verify" the value it just
///   wrote, and delete it — destroying the secret rather than moving it.
///   Reproduced against the real keychain during the M20 final review.
///
///   Making this meaningful takes more than a call site: the store must move
///   to the data-protection keychain, which cannot see the existing
///   file-based items at all, so the migration becomes a genuine
///   cross-implementation copy whose delete is scoped to the legacy path and
///   can never match the copy just written. Until then, the CLI reads the
///   app's secrets through per-item keychain consent.
public struct KeychainMigration: Sendable {
    private let source: any SecretStore
    private let target: any SecretStore

    public init(reading source: any SecretStore, writing target: any SecretStore) {
        self.source = source
        self.target = target
    }

    /// Write first, verify, only then delete the original. Interrupted in the
    /// middle this leaves a duplicate — untidy but lossless. The reverse order
    /// would lose the secret outright, so it is not an option.
    ///
    /// Idempotent: entries already gone from the source are simply skipped,
    /// so this may run on every launch. Returns how many were moved.
    @discardableResult
    public func migrate(sessionIDs: [UUID]) throws -> Int {
        var moved = 0
        for id in sessionIDs {
            guard let secret = try source.password(for: id), !secret.isEmpty else { continue }
            try target.savePassword(secret, for: id)
            guard try target.password(for: id) == secret else {
                throw KeychainVerificationMismatch()
            }
            try source.deletePassword(for: id)
            moved += 1
        }
        return moved
    }
}
