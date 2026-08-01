import Foundation

/// The expiry duration offered for a presigned S3 share link (M14). The
/// share-link sheet pre-fills `SettingsStore.presignedDefaultExpiry`; the
/// sheet itself lets the user override it per link.
public enum PresignedExpiry: String, Codable, CaseIterable, Sendable {
    case fifteenMinutes
    case oneHour
    case oneDay
    case sevenDays

    public var seconds: TimeInterval {
        switch self {
        case .fifteenMinutes: return 900
        case .oneHour: return 3600
        case .oneDay: return 86_400
        case .sevenDays: return 604_800
        }
    }
}
