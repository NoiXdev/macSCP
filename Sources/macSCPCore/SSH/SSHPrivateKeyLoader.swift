import Citadel
import Crypto
import Foundation

/// Typisierte Fehler beim Laden privater SSH-Keys.
public enum SSHKeyError: Error, Equatable, Sendable {
    case fileNotFound(path: String)
    case passphraseRequired
    case wrongPassphrase
    case unsupportedFormat(reason: String)
}

/// Lädt private OpenSSH-Keys (M3b: ed25519, optional verschlüsselt) über
/// Citadels Parser. RSA/ecdsa und ssh-agent sind bewusst verschoben (YAGNI).
public enum SSHPrivateKeyLoader {
    public static func authentication(
        username: String, keyPath: String, passphrase: String?
    ) throws -> SSHAuthenticationMethod {
        let expanded = NSString(string: keyPath).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            throw SSHKeyError.fileNotFound(path: keyPath)
        }

        let contents: String
        do {
            contents = try String(contentsOfFile: expanded, encoding: .utf8)
        } catch {
            throw SSHKeyError.unsupportedFormat(reason: String(describing: error))
        }

        // Leere Passphrase == keine Passphrase (unverschlüsselter Key).
        let decryptionKey = passphrase.flatMap { $0.isEmpty ? nil : Data($0.utf8) }
        do {
            let key = try Curve25519.Signing.PrivateKey(
                sshEd25519: contents, decryptionKey: decryptionKey)
            return .ed25519(username: username, privateKey: key)
        } catch {
            throw Self.map(error, hadPassphrase: decryptionKey != nil)
        }
    }

    /// Übersetzt Citadels Parser-Fehler in `SSHKeyError`.
    ///
    /// Citadel wirft für den OpenSSH-Parser keine öffentlich unterscheidbaren
    /// Enum-Fälle: der interne `OpenSSH.KeyError` (u.a. `missingDecryptionKey`)
    /// ist `internal`, und `InvalidOpenSSHKey` ist zwar `public`, sein
    /// `reason`-Feld aber `internal`. Wir werten daher die stabilen, hart
    /// kodierten `reason`-Strings über `String(describing:)` aus:
    ///  - `missingDecryptionKey` → Key ist verschlüsselt, keine Passphrase.
    ///  - `invalidCheck`/`invalidPadding`/Krypto-Fehler bei gegebener Passphrase
    ///    → falsche Passphrase (Entschlüsselung ergab Müll).
    ///  - alles andere (`invalidOpenSSHBoundary`, `invalidBase64Payload`, …)
    ///    → nicht unterstütztes/kaputtes Format.
    private static func map(_ error: Error, hadPassphrase: Bool) -> SSHKeyError {
        let text = String(describing: error).lowercased()

        // Verschlüsselter Key, aber keine Passphrase geliefert.
        if text.contains("missingdecryptionkey") {
            return .passphraseRequired
        }

        // Entschlüsselungs-spezifische Fehler.
        if text.contains("invalidcheck") || text.contains("invalidpadding")
            || text.contains("crypto") || text.contains("decrypt")
            || text.contains("cipher") || text.contains("passphrase")
            || text.contains("encrypted") {
            return hadPassphrase ? .wrongPassphrase : .passphraseRequired
        }

        return .unsupportedFormat(reason: String(describing: error))
    }
}
