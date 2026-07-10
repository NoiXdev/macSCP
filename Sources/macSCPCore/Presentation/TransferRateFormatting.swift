import Foundation

/// Formats the compact "<rate>/s [· <eta>]" label shown next to a running
/// transfer's progress bar (M5c/T5), e.g. "1,2 MB/s · 0:42".
///
/// A small dedicated helper rather than `ByteCountFormatter`/
/// `DateComponentsFormatter` directly: neither exposes a settable `locale`,
/// which tests need to pin down a specific decimal separator (`,` for
/// `de_DE`, `.` for `en_US`) instead of depending on the test runner's
/// system locale.
public enum TransferRateFormatting {
    /// Binary-unit thresholds, largest first — the first one the rate
    /// clears wins.
    private static let units: [(threshold: Double, divisor: Double, symbol: String)] = [
        (Double(1 << 30), Double(1 << 30), "GB"),
        (Double(1 << 20), Double(1 << 20), "MB"),
        (Double(1 << 10), Double(1 << 10), "KB"),
    ]

    /// "1,2 MB/s" (or "834 B/s" below 1 KB/s, no decimal there). `nil` or a
    /// non-positive/non-finite rate yields `nil` — the queue bar hides the
    /// label until a real rate is known.
    public static func rateString(bytesPerSecond: Double?, locale: Locale = .current) -> String? {
        guard let bytesPerSecond, bytesPerSecond.isFinite, bytesPerSecond > 0 else { return nil }

        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0

        for unit in units where bytesPerSecond >= unit.threshold {
            formatter.maximumFractionDigits = 1
            let value = bytesPerSecond / unit.divisor
            let formatted = formatter.string(from: NSNumber(value: value)) ?? "\(value)"
            return "\(formatted) \(unit.symbol)/s"
        }

        formatter.maximumFractionDigits = 0
        let formatted = formatter.string(from: NSNumber(value: bytesPerSecond)) ?? "\(Int(bytesPerSecond))"
        return "\(formatted) B/s"
    }

    /// "0:42" (or "1:02:03" past an hour). `nil`, negative, or non-finite
    /// input yields `nil`. Plain ASCII digits with a fixed `:` separator —
    /// deliberately not locale-varied (a time-remaining readout, not prose).
    public static func etaString(seconds: Double?) -> String? {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return nil }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    /// The combined queue-bar label. Falls back to just the rate (no
    /// separator) when the ETA is unavailable (unknown total size, or not
    /// enough samples yet), and to `nil` when even the rate can't be shown.
    public static func compactLabel(
        bytesPerSecond: Double?, etaSeconds: Double?, locale: Locale = .current
    ) -> String? {
        guard let rate = rateString(bytesPerSecond: bytesPerSecond, locale: locale) else { return nil }
        guard let eta = etaString(seconds: etaSeconds) else { return rate }
        return "\(rate) · \(eta)"
    }
}
