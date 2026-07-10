import Foundation
import Testing
@testable import macSCPCore

@Suite("TransferRateFormatting")
struct TransferRateFormattingTests {
    private let de = Locale(identifier: "de_DE")
    private let en = Locale(identifier: "en_US")

    // MARK: - rateString

    @Test func rateStringNilForNonPositiveOrMissingInput() {
        #expect(TransferRateFormatting.rateString(bytesPerSecond: nil) == nil)
        #expect(TransferRateFormatting.rateString(bytesPerSecond: 0) == nil)
        #expect(TransferRateFormatting.rateString(bytesPerSecond: -1) == nil)
        #expect(TransferRateFormatting.rateString(bytesPerSecond: .nan) == nil)
        #expect(TransferRateFormatting.rateString(bytesPerSecond: .infinity) == nil)
    }

    @Test func rateStringBelowOneKBHasNoDecimal() {
        #expect(TransferRateFormatting.rateString(bytesPerSecond: 512, locale: en) == "512 B/s")
    }

    @Test func rateStringPicksBinaryUnitByMagnitude() {
        #expect(TransferRateFormatting.rateString(bytesPerSecond: 1536, locale: en) == "1.5 KB/s")
        #expect(TransferRateFormatting.rateString(
            bytesPerSecond: 1.2 * Double(1 << 20), locale: en) == "1.2 MB/s")
        #expect(TransferRateFormatting.rateString(
            bytesPerSecond: 2 * Double(1 << 30), locale: en) == "2 GB/s")
    }

    @Test func rateStringUsesLocaleDecimalSeparator() {
        let rate = 1.2 * Double(1 << 20)
        #expect(TransferRateFormatting.rateString(bytesPerSecond: rate, locale: en) == "1.2 MB/s")
        #expect(TransferRateFormatting.rateString(bytesPerSecond: rate, locale: de) == "1,2 MB/s")
    }

    // MARK: - etaString

    @Test func etaStringNilForMissingOrInvalidInput() {
        #expect(TransferRateFormatting.etaString(seconds: nil) == nil)
        #expect(TransferRateFormatting.etaString(seconds: -1) == nil)
        #expect(TransferRateFormatting.etaString(seconds: .nan) == nil)
    }

    @Test func etaStringFormatsMinutesAndSeconds() {
        #expect(TransferRateFormatting.etaString(seconds: 0) == "0:00")
        #expect(TransferRateFormatting.etaString(seconds: 42) == "0:42")
        #expect(TransferRateFormatting.etaString(seconds: 62) == "1:02")
    }

    @Test func etaStringFormatsHoursPastOneHour() {
        #expect(TransferRateFormatting.etaString(seconds: 3723) == "1:02:03")
    }

    // MARK: - compactLabel

    @Test func compactLabelCombinesRateAndETA() {
        let rate = 1.2 * Double(1 << 20)
        #expect(
            TransferRateFormatting.compactLabel(bytesPerSecond: rate, etaSeconds: 42, locale: de)
                == "1,2 MB/s · 0:42")
    }

    @Test func compactLabelFallsBackToRateWithoutETA() {
        #expect(
            TransferRateFormatting.compactLabel(bytesPerSecond: 512, etaSeconds: nil, locale: en)
                == "512 B/s")
    }

    @Test func compactLabelNilWithoutRate() {
        #expect(TransferRateFormatting.compactLabel(bytesPerSecond: nil, etaSeconds: 42) == nil)
    }
}
