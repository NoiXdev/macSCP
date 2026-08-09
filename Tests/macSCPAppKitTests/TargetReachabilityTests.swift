import Foundation
import Testing
@testable import MacSCPAppKit

@Suite("Target reachability")
struct TargetReachabilityTests {
    /// The whole point of P1: App-layer code that is not a SwiftUI view can
    /// be named from a test. Before the split this file could not compile —
    /// there was no test target that could import the app.
    ///
    /// `KeyboardShortcutsCatalog` is `internal`, so this also pins that
    /// `@testable import` reaches internal symbols, which every later App
    /// test depends on.
    @Test func internalAppSymbolsAreVisibleToTests() {
        #expect(KeyboardShortcutsCatalog.groups.isEmpty == false)
    }
}
