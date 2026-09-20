import Foundation
import MacSCPTestSupport
import Testing

/// Guards the invariant `ConnectionViewModel.fillJumpPassphrase(_:)`'s doc
/// comment states: every jump fill goes through that one door, so the value
/// in `jumpPassword` is either something a person typed or something the form
/// remembers having put there (re-review of fix round 1).
///
/// The save guard for a hop's own Keychain slot is that comparison and
/// nothing else (`SessionListViewModel.save`/`updateSession`,
/// `jumpSecret != filledJumpPassphrase`). A fill that writes the field
/// directly leaves a managed key's passphrase in it with nothing remembering
/// the fill, and the next save copies that secret into the hop's slot — which
/// `ExportedSession.jumpPassword` reads. One such fill existed
/// (`SessionListViewModel+Submit.resolveJumpSession`) while the doc comment
/// already claimed otherwise; it is routed now, and this is what keeps the
/// claim true.
///
/// The rule the scan enforces, outside `ConnectionViewModel.swift` itself:
/// **a write to some form's `jumpPassword` may only clear it.** Anything else
/// is a fill, and a fill belongs in `fillJumpPassphrase(_:)`. `self
/// .jumpPassword` is exempt — the export and import payload types have a
/// `jumpPassword` of their own, and it is not a form's.
///
/// The negative ("no other writer") stands beside two positives: the scan
/// finds the door being used, and it finds the clears it permits. Without
/// them a scan that matched nothing at all would read exactly like a scan
/// that is satisfied.
@Suite("Jump passphrase fill guard")
struct JumpPassphraseFillGuardTests {
    private static let door = "fillJumpPassphrase("
    /// The one file the rule does not apply to: the field is declared there,
    /// and `fillJumpPassphrase` and the clears are its own body.
    private static let declaringFile = "ConnectionViewModel.swift"

    /// One `x.jumpPassword = …` assignment: the file it sits in, and the
    /// right-hand side up to the end of its line.
    private struct Write {
        let file: String
        let assigned: String
    }

    @Test func everyJumpPassphraseFillGoesThroughTheOneDoor() throws {
        let scanned = try Self.scan()

        #expect(scanned.usesTheDoor.isEmpty == false, """
            no file under Sources/ calls `\(Self.door)` — the scan is pointed at a tree where \
            the fill door does not exist, so the check below could not find a violation of it.
            """)
        #expect(scanned.writes.isEmpty == false, """
            no file under Sources/ assigns a form's `jumpPassword` at all — not even the clears \
            that exist, so this scan is reading nothing.
            """)

        let fills = scanned.writes.filter { $0.assigned != "\"\"" }
        let named = fills.map { "\($0.file): \($0.assigned)" }.sorted()
        #expect(fills.isEmpty, """
            these write a form's `jumpPassword` without going through `\(Self.door)`, so the \
            value lands in the field with nothing remembering that a fill put it there, and the \
            next save copies it into the hop's own Keychain slot: \(named)
            """)
    }

    // MARK: - Scanner self-tests

    @Test func aClearIsAllowedAndAFillIsNot() {
        let found = Self.writes(inCommentFree: """
            form.jumpPassword = ""
            form.jumpPassword = resolved.login.secret ?? ""
            self.jumpPassword = jumpPassword
            let jumpPassword = planned.jumpPassword
            """, file: "fixture")
        #expect(found.map(\.assigned) == ["\"\"", "resolved.login.secret ?? \"\""])
    }

    @Test func aScanOfATreeWithoutTheDoorIsNotRead() throws {
        // The positive above, exercised: `usesTheDoor` is what tells a tree
        // where the door was renamed from one where nothing violates the rule.
        let found = Self.writes(inCommentFree: "form.jumpPassword = \"\"", file: "fixture")
        #expect(found.count == 1)
        #expect("nothing here".contains(Self.door) == false)
    }

    // MARK: - Scanner

    private static func scan() throws -> (writes: [Write], usesTheDoor: [String]) {
        var writes: [Write] = []
        var usesTheDoor: [String] = []
        for url in try SourceCorpus.files(under: SourceCorpus.url(of: .sources))
        where url.pathExtension == "swift" {
            let name = url.lastPathComponent
            // `commentFree`, not `code`: string LITERALS must survive, since
            // the one permitted right-hand side is `""`. Comments must not —
            // this project writes explanatory comments that quote the code
            // they describe, and a scanner reads them as code.
            let source = try SourceCorpus.commentFree(of: url)
            if source.contains(door) { usesTheDoor.append(name) }
            guard name != declaringFile else { continue }
            writes += self.writes(inCommentFree: source, file: name)
        }
        return (writes, usesTheDoor)
    }

    /// Every `.jumpPassword = …` in `source` whose receiver is not `self`,
    /// with the right-hand side trimmed to the end of its line.
    private static func writes(inCommentFree source: String, file: String) -> [Write] {
        var result: [Write] = []
        var searchStart = source.startIndex
        while let found = source.range(of: ".jumpPassword = ", range: searchStart..<source.endIndex) {
            searchStart = found.upperBound
            let before = source[source.startIndex..<found.lowerBound]
            guard before.hasSuffix("self") == false else { continue }
            let rest = source[found.upperBound...]
            let line = rest.prefix { $0 != "\n" }
            result.append(Write(
                file: file,
                assigned: line.trimmingCharacters(in: .whitespaces)))
        }
        return result
    }
}
