import Foundation
import Testing
@testable import macSCPCore

/// Läuft nur mit MACSCP_KEYCHAIN=1 (lokal) — CI-Runner-Keychains sind unzuverlässig.
@Suite(
    "KeychainSecretStore",
    .enabled(if: ProcessInfo.processInfo.environment["MACSCP_KEYCHAIN"] == "1"),
    .serialized
)
struct KeychainSecretStoreTests {
    private let store = KeychainSecretStore(service: "dev.noidee.macSCP.test")

    @Test func roundtripSaveReadUpdate() throws {
        let id = UUID()
        defer { try? store.deletePassword(for: id) }

        #expect(try store.password(for: id) == nil)
        try store.savePassword("geheim1", for: id)
        #expect(try store.password(for: id) == "geheim1")
        try store.savePassword("geheim2", for: id)   // Update-Pfad
        #expect(try store.password(for: id) == "geheim2")
    }

    @Test func deleteRemovesAndIsIdempotent() throws {
        let id = UUID()
        try store.savePassword("weg", for: id)
        try store.deletePassword(for: id)
        #expect(try store.password(for: id) == nil)
        try store.deletePassword(for: id)   // No-op, wirft nicht
    }
}
