import Foundation
import macSCPCore

/// The secret source a DIAGNOSIS authenticates through.
///
/// The session's own Keychain slot first, and — for an SSH private-key
/// connection with a key path — the managed key's passphrase slot after it
/// (`ManagedKeyPassphraseSecretSource`, Core): the same two links, in the same
/// order, as a forwarding's chain (`TunnelSecretSources.chain`) and the tail
/// of the command line's (`secretSources(for:passwordCommand:…)`). Without
/// the second link a session whose own slot was dropped because the managed
/// key's slot holds the passphrase (`ContentView.convertedKeyImported(_:for:)`)
/// connects from its tab and diagnoses as "no secret" (final review of the
/// 2026-09-16 plan).
///
/// Read from the target's FIELD VALUES rather than a `StoredSession`: a
/// diagnosis opened from a tab carries the form it dialled with, and one from
/// the sidebar the stored values, and both reach here as `FieldValues`.
///
/// A pure builder, so the chain is tested without a window
/// (`DiagnosticsSecretSourcesTests`); `ContentView.showDiagnostics(for:)`
/// hands it the window's injected `managedKeyStore` and `secretStore`.
enum DiagnosticsSecretSources {
    /// The links, in order.
    static func chain(
        kind: ConnectionKind, values: FieldValues, keys: ManagedKeyStore, secrets: any SecretStore
    ) -> [any SecretSource] {
        var sources: [any SecretSource] = [KeychainSecretSource(store: secrets)]
        let keyPath = values[SSHField.keyPath].trimmingCharacters(in: .whitespacesAndNewlines)
        if kind == .ssh, values[SSHField.authKind] == StoredSession.AuthKind.privateKey.rawValue,
            !keyPath.isEmpty
        {
            sources.append(ManagedKeyPassphraseSecretSource(keyPath: keyPath, keys: keys, secrets: secrets))
        }
        return sources
    }

    /// The chain as the one `SecretSource` a `DiagnosticsViewModel` takes. A
    /// single link is handed over as itself, so a connection with no managed
    /// key resolves exactly as it did before the second link existed.
    static func source(
        kind: ConnectionKind, values: FieldValues, keys: ManagedKeyStore, secrets: any SecretStore
    ) -> any SecretSource {
        let links = chain(kind: kind, values: values, keys: keys, secrets: secrets)
        if links.count == 1, let only = links.first { return only }
        return ChainedSecretSource(links)
    }
}
