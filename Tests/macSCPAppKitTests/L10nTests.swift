import Foundation
import Testing

@testable import MacSCPAppKit

@Suite("L10n")
struct L10nTests {
    /// The App layer's lookup falls back to `Bundle.main`, where the key is
    /// absent, so `NSLocalizedString` hands back the `defaultValue` — every
    /// string in English, with no crash and no failing test. Renaming the
    /// target's bundle would have re-armed exactly that.
    ///
    /// The fallback here is deliberately absurd: if the real catalog is
    /// found, no language can return this string, so the assertion holds in
    /// German, English, French and Polish alike.
    @Test func aKnownKeyResolvesInsteadOfFallingBackToTheDefault() {
        let resolved = L10n.string("tabs.newConnection", "ZZ-UNRESOLVED-ZZ")
        #expect(resolved != "ZZ-UNRESOLVED-ZZ")
    }

    /// The graceful-degradation half: an unknown key must return the
    /// supplied default rather than an empty string, so a typo shows up as
    /// readable English in the UI instead of a blank control.
    @Test func anUnknownKeyReturnsTheSuppliedDefault() {
        #expect(L10n.string("app.this.key.does.not.exist", "Readable default") == "Readable default")
    }

    /// The bundle the lookup settled on must not be `Bundle.main` — that is
    /// the silent-failure state itself, and the assertion above would still
    /// pass if some unrelated main-bundle key happened to match.
    @Test func theLookupDidNotSettleForTheMainBundle() {
        #expect(L10n.bundle != Bundle.main)
    }
}
