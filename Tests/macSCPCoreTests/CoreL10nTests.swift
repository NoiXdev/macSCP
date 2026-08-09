import Foundation
import Testing

@testable import macSCPCore

@Suite("CoreL10n")
struct CoreL10nTests {
    /// `CoreL10n.string` returns the KEY when the resource bundle cannot be
    /// found. Under `swift test` that was always the case. The existing
    /// `#expect(error == CoreL10n.string(key))` assertions were not thereby
    /// worthless — both sides reduced to key text, so a wrong key on either
    /// side still went red — but no test could tell a key that maps to real
    /// text from one that maps to nothing at all. This is the test that can.
    ///
    /// Deliberately not asserting a specific translation: the host's
    /// preferred language decides which one comes back, so any fixed text
    /// would pass on one machine and fail on another. "Resolved at all" is
    /// the property that matters and it is language-independent.
    @Test func aKnownKeyResolvesToSomethingOtherThanItself() {
        let key = "core.login.mergeConflictingSecrets"
        #expect(CoreL10n.string(key) != key)
    }

    /// A key that exists in no catalog must still come back as itself — the
    /// documented graceful degradation. Pins that the fix did not turn a
    /// missing key into a crash or an empty string.
    @Test func anUnknownKeyStillReturnsItself() {
        let key = "core.this.key.does.not.exist"
        #expect(CoreL10n.string(key) == key)
    }
}
