import Foundation
import MacSCPTestSupport
import Testing

@testable import MacSCPAppKit

/// Holds `BoundedViewRegistry` to the `BoundedView` conformances in
/// `Sources/MacSCPAppKit`.
///
/// `BoundedViewLayoutGuardTests` measures every entry of the registry in every
/// language, but it can only measure what the registry lists: a view that
/// declares a bound and is never added there is not measured, and nothing in
/// that suite would say so. This is the other half of the coverage claim — the
/// registry's `typeName`s against the conforming types the source declares.
///
/// **Set equality, not a count.** A count that happens to match hides a swap:
/// one type added to `Sources/` and another dropped from the registry leaves
/// the number right and the coverage wrong. The failure message names the two
/// directions as separate lists, so a red says which way the gap runs.
///
/// **The scan reads the comment-and-string-blanked view**, so a doc comment
/// that quotes a conformance is not counted as one. A conformance declared in
/// an `extension`, and one listed among others, count as well.
@Suite("Bounded view coverage")
struct BoundedViewCoverageTests {
    /// The names of the types `Sources/MacSCPAppKit` declares to conform to
    /// `BoundedView`, read off the blanked source.
    static func boundedViewTypeNamesInSources() throws -> Set<String> {
        let tree = SourceCorpus.url(of: .sources).appendingPathComponent("MacSCPAppKit")
        // The protocol's own declaration has no type keyword from this list in
        // front of its name, so it is not matched.
        let declaration = #/\b(?:struct|class|enum|extension)\s+(\w+)\s*(?:<[^>{]*>)?\s*:[^{]*\bBoundedView\b/#
        var names: Set<String> = []
        for file in try SourceCorpus.files(under: tree) where file.pathExtension == "swift" {
            let code = try SourceCorpus.code(of: file)
            for match in code.matches(of: declaration) {
                names.insert(String(match.output.1))
            }
        }
        return names
    }

    @Test @MainActor func everyConformerIsInTheRegistry() throws {
        let declared = try Self.boundedViewTypeNamesInSources()
        let measured = Set(BoundedViewRegistry.all.map(\.typeName))
        let onlyInSources = declared.subtracting(measured).sorted()
        let onlyInRegistry = measured.subtracting(declared).sorted()
        #expect(
            declared == measured,
            "only in Sources: \(onlyInSources); only in the registry: \(onlyInRegistry)")
    }

    /// The positive beside the check above: a scan that silently stopped
    /// matching anything would leave `declared` empty, which reads exactly
    /// like a scan that is satisfied.
    @Test func theScanFindsTheConformancesAtAll() throws {
        let declared = try Self.boundedViewTypeNamesInSources()
        #expect(declared.count >= 33, "the scan found \(declared.count) names")
        #expect(declared.contains(String(describing: FileActionEditor.self)))
    }
}
