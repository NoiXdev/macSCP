import Foundation
import macSCPCore

/// The secret chain a FORWARDING's dial resolves through.
///
/// **Not `secretSources(for:passwordCommand:)`.** That function is the
/// command line's chain and says so: it puts `EnvironmentSecretSource`
/// (`MACSCP_PASSWORD`) ahead of the Keychain, which is right for a cron job
/// and wrong for a GUI — a variable in the environment the app happened to
/// be launched from would silently outrank the password the user saved.
/// When this chain was written, that function also reached only
/// session-keyed Keychain slots, so a session using a MANAGED private key
/// resolved to nothing at all: the tab connected (the window's own path
/// resolves the key's passphrase) and the forwarding failed authentication.
/// Since Task 2 fix round 2 of the 2026-09-16 plan both chains end in the
/// same `ManagedKeyPassphraseSecretSource` (Core); the environment is still
/// the difference.
///
/// What the App's own connect path does, and what this reproduces:
/// `ContentView.fillForm(_:from:)` fills the secret from the session's
/// Keychain slot (`SessionListViewModel.password(for:)`, or the login set's
/// credentials where one is bound), and THEN, for private-key auth, runs
/// `ManagedKeyPassphrase.resolve(keyPath:typed:…)` with what it already has
/// as `typed` — so a typed/stored session secret wins and the key's own slot
/// answers only when that was empty. The order below is the same order, and
/// `SecretResolver`'s "first non-empty wins" is the same rule.
///
/// **A login set is not resolved here**, and does not need to be: a session
/// bound to one can carry no forwarding at all
/// (`SessionRowTunnelMenuPlan.build` never offers it, and
/// `StoredSessionConnectionConfig.build(for:secret:)` refuses it), so the
/// branch `fillForm` needs for `resolvedCredentials(for:)` has no reachable
/// case here. If forwardings are ever opened up to set-bound sessions, this
/// is the function that has to grow a `LoginResolver`.
enum TunnelSecretSources {
    /// - Parameters:
    ///   - keys: the managed-key store the App holds (`ContentView
    ///     .managedKeyStore` in production, a temp directory in tests).
    ///   - secrets: the Keychain, or a fake.
    static func chain(
        for session: StoredSession, keys: ManagedKeyStore, secrets: any SecretStore
    ) -> [any SecretSource] {
        let descriptor = BackendDescriptor.descriptor(for: session.kind)
        // The same question `secretSources(for:passwordCommand:)` asks first,
        // and for the same reason: an agent login needs no secret, so a
        // broken Keychain read must not be able to fail a dial that never
        // wanted one.
        guard descriptor.requiresSecret(descriptor.sessionValues(session)) else { return [] }

        var sources: [any SecretSource] = [KeychainSecretSource(store: secrets)]
        if session.ssh?.authKind == .privateKey, let keyPath = session.ssh?.keyPath,
            !keyPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            sources.append(
                ManagedKeyPassphraseSecretSource(
                    keyPath: keyPath.trimmingCharacters(in: .whitespacesAndNewlines),
                    keys: keys, secrets: secrets))
        }
        return sources
    }
}
