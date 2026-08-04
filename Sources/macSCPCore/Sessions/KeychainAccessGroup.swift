import Foundation
import Security

/// Derives the keychain access group this PROCESS can actually use, by
/// reading its own code-signing information at runtime rather than
/// hardcoding a team identifier in source (M20 finding fix).
///
/// Why runtime detection instead of a literal string: `codesign
/// --entitlements <plist>` performs no build-setting substitution, so the
/// team identifier has to come from somewhere else entirely for a script
/// that signs directly (see `scripts/release`, which expands
/// `$(TeamIdentifierPrefix)` into a temporary plist before signing). But
/// even a correctly-expanded entitlements file only tells the OS what group
/// the binary is ALLOWED to use — it says nothing to the Swift code running
/// inside it. This type closes that gap by asking the OS what this process
/// was actually signed with, which has two properties a hardcoded constant
/// cannot have:
/// - it can never drift from the entitlements the binary actually carries
///   (there is only one source of truth: the code signature itself);
/// - it is correct unconditionally for ad-hoc/unsigned dev builds, which
///   have no team identifier — `current()` yields `nil` there, and every
///   call site already treats a `nil` access group as "use the group-less,
///   per-item-consent keychain path", exactly the pre-M20 behavior. Nothing
///   has to special-case "am I a dev build?" — the signature already
///   answers that.
public enum KeychainAccessGroup {
    /// The identifier suffix appended to the team identifier prefix. Matches
    /// `CFBundleIdentifier` in `scripts/package-app` (`dev.noix.macscp`,
    /// lowercase) and the `keychain-access-groups` entry in both
    /// entitlements plists — all three must agree for the group to resolve
    /// to the same string in every binary that claims it.
    static let identifierSuffix = "dev.noix.macscp"

    /// Reads this process's own code signature via `SecCode`/`SecStaticCode`
    /// and returns the access group it is entitled to, or `nil` when the
    /// process has no team identifier (unsigned, or ad-hoc signed — which is
    /// exactly what `swift build`/`swift test` and `scripts/package-app`
    /// produce) or when any Security-framework call fails. Never throws:
    /// "no access group" is always a safe, meaningful answer here, never an
    /// error condition a caller needs to handle specially.
    public static func current() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else { return nil }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode else { return nil }

        // kSecCSSigningInformation: the team identifier is only populated in
        // the signing-information dictionary when this flag is passed —
        // without it, the call still succeeds but silently omits the key.
        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess,
              let info = information as? [String: Any] else { return nil }

        guard let teamIdentifier = info[kSecCodeInfoTeamIdentifier as String] as? String else {
            return nil
        }
        return build(teamIdentifier: teamIdentifier)
    }

    /// Pure and separately testable: the string-assembly half of `current()`,
    /// split out so a unit test can cover "empty/blank team identifier"
    /// without needing a real signed-vs-unsigned process to exercise it.
    static func build(teamIdentifier: String) -> String? {
        let trimmed = teamIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return "\(trimmed).\(identifierSuffix)"
    }
}
