import Foundation
import Testing
@testable import macSCPCore

@Suite("SecretResolver")
struct SecretResolverTests {
    private struct Fixed: SecretSource {
        let label: String
        let value: String?
        func secret(for sessionID: UUID) throws -> String? { value }
    }

    private struct Broken: SecretSource {
        let label: String
        func secret(for sessionID: UUID) throws -> String? {
            throw SecretSourceFailure(label: label)
        }
    }

    @Test func takesTheFirstSourceThatDelivers() throws {
        let resolver = SecretResolver(sources: [
            Fixed(label: "command", value: nil),
            Fixed(label: "env", value: "from-env"),
            Fixed(label: "keychain", value: "from-keychain"),
        ])
        let resolved = try resolver.resolve(for: UUID())
        #expect(resolved?.value == "from-env")
        #expect(resolved?.sourceLabel == "env")
    }

    /// An empty string is "did not deliver", not "the password is empty".
    /// Otherwise an unset variable would silently authenticate as blank.
    @Test func anEmptyValueCountsAsNoValue() throws {
        let resolver = SecretResolver(sources: [
            Fixed(label: "env", value: ""),
            Fixed(label: "keychain", value: "real"),
        ])
        #expect(try resolver.resolve(for: UUID())?.sourceLabel == "keychain")
    }

    /// A source that FAILS is different from one that has nothing: a broken
    /// vault call must not fall through to a stale keychain entry.
    @Test func aFailingSourceAbortsInsteadOfFallingThrough() {
        let resolver = SecretResolver(sources: [
            Broken(label: "command"),
            Fixed(label: "keychain", value: "stale"),
        ])
        #expect(throws: SecretSourceFailure(label: "command")) {
            try resolver.resolve(for: UUID())
        }
    }

    @Test func returnsNilWhenNoSourceHasAnything() throws {
        let resolver = SecretResolver(sources: [Fixed(label: "env", value: nil)])
        #expect(try resolver.resolve(for: UUID()) == nil)
    }

    @Test func anEmptyChainReturnsNil() throws {
        #expect(try SecretResolver(sources: []).resolve(for: UUID()) == nil)
    }

    @Test func resolvedSecretDoesNotLeakValueInStringInterpolation() throws {
        let secret = ResolvedSecret(value: "supersecret123", sourceLabel: "keychain")
        let interpolated = "\(secret)"
        let debugDescription = String(reflecting: secret)

        #expect(!interpolated.contains("supersecret123"), "value must not leak in string interpolation")
        #expect(!debugDescription.contains("supersecret123"), "value must not leak in debug description")
        #expect(interpolated.contains("keychain"), "source label must be present in string description")
        #expect(debugDescription.contains("keychain"), "source label must be present in debug description")
    }
}
