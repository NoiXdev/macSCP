import Foundation
import Testing
@testable import macSCPCore

/// Runs only with MACSCP_KEYCHAIN=1 (locally) — CI runner keychains are unreliable.
@Suite(
    "KeychainSecretStore",
    .enabled(if: ProcessInfo.processInfo.environment["MACSCP_KEYCHAIN"] == "1"),
    .serialized
)
struct KeychainSecretStoreTests {
    private let store = KeychainSecretStore(service: "dev.noix.macSCP.test")

    @Test func roundtripSaveReadUpdate() throws {
        let id = UUID()
        defer { try? store.deletePassword(for: id) }

        #expect(try store.password(for: id) == nil)
        try store.savePassword("geheim1", for: id)
        #expect(try store.password(for: id) == "geheim1")
        try store.savePassword("geheim2", for: id)   // Update path
        #expect(try store.password(for: id) == "geheim2")
    }

    @Test func deleteRemovesAndIsIdempotent() throws {
        let id = UUID()
        try store.savePassword("weg", for: id)
        try store.deletePassword(for: id)
        #expect(try store.password(for: id) == nil)
        try store.deletePassword(for: id)   // No-op, does not throw
    }
}
