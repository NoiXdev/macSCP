import Foundation
import Testing

@testable import macSCPCore

@Suite("CoreL10n")
struct CoreL10nTests {
    /// `CoreL10n.string` returns the KEY when the resource bundle cannot be
    /// found. Under `swift test` that was always the case, which silently
    /// made dozens of `#expect(error == CoreL10n.string(…))` assertions
    /// compare a key against itself — they could not fail.
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
