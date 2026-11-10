import macSCPCore

/// The sentence under the "send credentials unencrypted?" question. The kind
/// comes from `PlaintextTransportGate.kind(for:)`, which is where the choice
/// is made; this type only turns it into a catalog key and its text, so a
/// plain FTP session is pointed at FTPS and a web endpoint at the encrypted
/// scheme. Each catalog key is spelled once, in `key(for:)`; the text is
/// looked up under that key.
enum PlaintextConfirmationBody {
    /// The catalog key of the sentence for this kind.
    static func key(for kind: PlaintextTransportGate.Kind) -> String {
        switch kind {
        case .http: "transport.plaintext.body"
        case .plainFTP: "transport.plaintext.body.ftp"
        }
    }

    /// The localized sentence for this kind, looked up under `key(for:)`.
    static func text(for kind: PlaintextTransportGate.Kind) -> String {
        L10n.string(key(for: kind), fallback(for: kind))
    }

    /// The English text shown when the catalog has no entry for the key.
    private static func fallback(for kind: PlaintextTransportGate.Kind) -> String {
        switch kind {
        case .http:
            "This connection uses http://, so the password travels in the clear. "
                + "Use https:// where the server offers it."
        case .plainFTP:
            "This connection uses plain FTP, so the password travels in the clear. "
                + "Use FTPS where the server offers it."
        }
    }
}
