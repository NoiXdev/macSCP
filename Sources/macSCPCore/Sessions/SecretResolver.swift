import Foundation

/// One place a secret can come from. Kept tiny so tests can substitute fakes
/// and pin the ORDER, which is the part that matters.
public protocol SecretSource: Sendable {
    /// Named in diagnostics so `--verbose` can say which source answered.
    /// Without that, a wrong password in CI is undiagnosable.
    var label: String { get }
    func secret(for sessionID: UUID) throws -> String?
}

/// A secret value paired with its source label.
///
/// Conforms to `CustomStringConvertible` and `CustomDebugStringConvertible` to
/// prevent accidental disclosure: when printed, interpolated into strings, or
/// inspected in a debugger, only the source label appears, never the credential
/// value itself. This protects against leaks via `print()`, string interpolation,
/// log statements, and crash dumps.
public struct ResolvedSecret: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let value: String
    public let sourceLabel: String

    public init(value: String, sourceLabel: String) {
        self.value = value
        self.sourceLabel = sourceLabel
    }

    public var description: String {
        "[redacted from \(sourceLabel)]"
    }

    public var debugDescription: String {
        "[redacted from \(sourceLabel)]"
    }
}

public struct SecretSourceFailure: Error, Equatable, Sendable {
    public let label: String
    public init(label: String) { self.label = label }
}

/// Walks its sources in order, explicit before implicit. The order is a
/// decision, not a detail: an explicitly passed `--password-command` must beat
/// whatever happens to sit in the keychain.
public struct SecretResolver: Sendable {
    private let sources: [any SecretSource]

    public init(sources: [any SecretSource]) { self.sources = sources }

    /// Returns the first non-empty secret. A source that THROWS stops the
    /// walk rather than yielding to the next one — a broken vault call must
    /// not silently fall through to a stale entry.
    public func resolve(for sessionID: UUID) throws -> ResolvedSecret? {
        for source in sources {
            guard let value = try source.secret(for: sessionID), !value.isEmpty else { continue }
            return ResolvedSecret(value: value, sourceLabel: source.label)
        }
        return nil
    }
}
