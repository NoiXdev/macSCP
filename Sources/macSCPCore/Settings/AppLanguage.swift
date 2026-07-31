/// The app's UI language, chosen in Settings independent of the system
/// language (M11p). `.system` follows the OS (no `AppleLanguages` override);
/// the rest map to a locale code applied at launch in `MacSCPApp.init`.
public enum AppLanguage: String, Codable, CaseIterable, Sendable {
    case system
    case en
    case de
    case fr
    case pl

    /// The `AppleLanguages` code to apply, or `nil` for `.system` (no
    /// override — the app follows the OS language).
    public var localeCode: String? {
        switch self {
        case .system: return nil
        case .en: return "en"
        case .de: return "de"
        case .fr: return "fr"
        case .pl: return "pl"
        }
    }
}
