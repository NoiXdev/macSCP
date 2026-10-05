import Foundation
import MacSCPTestSupport
import Testing

/// Guards WHO may read `BrowserSession.showsFiles` (P2 terminal-chrome
/// milestone; whole-phase re-review, item 3).
///
/// `BrowserSession` is a struct, so every `if let session = tab.session` and
/// every `session` parameter is a COPY. Reading the flag off such a copy is
/// a read of a snapshot that a later write through `SessionTab.showsFiles`
/// does not update — the exact class of desync this phase spent a Critical
/// and an Important on. `SessionTab.showsFiles` is the one way in and out;
/// until now only a doc comment said so, while every other invariant in this
/// phase got a scanner.
///
/// Same boundary as the phase's other guards (`PaneRenderConditionGuardTests`,
/// `PaneVisibilityWiringGuardTests`, `TerminalPanelInsetTests`): a
/// SOURCE-TEXT scan, because this project has no view-instantiation tool and
/// `internal` is the narrowest access level Swift offers within one module —
/// `private` would put the property out of `SessionTab`'s reach too.
///
/// Known blind spots, stated up front:
/// - It recognizes a member access whose RECEIVER's name contains
///   "session" (`session.showsFiles`, `tab.session?.showsFiles`,
///   `browserSession.showsFiles`). A copy bound to a name that does not say
///   "session" (`let s = tab.session`, then `s.showsFiles`) slips past.
///   Aimed at the accidental read, not a hostile one.
/// - Comments are stripped, string literals are not. This bullet used to
///   read "Comments are not stripped: a comment that spells
///   `session.showsFiles` is flagged too. That is deliberate — the wrong
///   shape should not be modelled anywhere in the target, least of all in
///   prose someone copies." That is withdrawn: the guard reads
///   `commentFree(of:)`, so a comment spelling the property is no longer
///   flagged. A plain string literal spelling it still IS, because literals
///   survive that view — the price of keeping an interpolated read
///   (`"\(session.showsFiles)"`) visible, which the stricter `code(of:)`
///   view would blank along with its literal. The doc comment on
///   `onlySessionTabReadsShowsFilesOffTheSession` carries the measurements.
/// - `visibility.showsFiles` and any other `PaneVisibility` read is
///   untouched; the receiver is not a session. `theScannerAcceptsAPaneVisibilityRead`
///   pins that this is deliberate rather than a gap.
@Suite("Pane visibility ownership guard")
struct PaneVisibilityOwnershipGuardTests {
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let appSources = repoRoot.appendingPathComponent("Sources/MacSCPAppKit")

    /// Every Swift file of the App target, at ANY depth. Not
    /// `SourceCorpus.children(of:)`, which by construction does not descend:
    /// `Sources/MacSCPAppKit/Presentation/` then sits outside the one
    /// negative this suite exists for, while it still reads like a check
    /// that is satisfied (CLAUDE.md, "a negative check whose SPAN is wrong
    /// can never match"). Measured on 2026-09-27: a `session.showsFiles`
    /// read planted in that subdirectory was green 3 of 3 against the flat
    /// listing and red 3 of 3 against this walk.
    /// `theAppWalkDescendsIntoSubdirectories` is the positive beside it.
    private static func appSwiftFiles() throws -> [URL] {
        try SourceCorpus.files(under: appSources).filter { $0.pathExtension == "swift" }
    }

    /// A scanned file's path relative to the App target, so an offender in a
    /// subdirectory is named by where it is rather than by a bare file name
    /// two directories could share.
    private static func relativePath(of url: URL) -> String {
        let prefix = SourceCorpus.key(appSources) + "/"
        return String(SourceCorpus.key(url).dropFirst(prefix.count))
    }

    /// The span the negative below rests on: the walk descends. Both halves
    /// are DERIVED rather than spelled — the flat listing is asked for
    /// itself — so neither needs a recount when a file or a subdirectory
    /// appears.
    @Test func theAppWalkDescendsIntoSubdirectories() throws {
        let files = try Self.appSwiftFiles()
        let nested = files.filter { Self.relativePath(of: $0).contains("/") }
        #expect(nested.isEmpty == false, "the App walk no longer reaches any subdirectory")
        let flat = try SourceCorpus.children(of: Self.appSources)
            .filter { $0.pathExtension == "swift" }
            .count
        #expect(files.count > flat, "the App walk no longer descends")
    }

    /// The guard: `SessionTab.swift` owns this property, nobody else touches
    /// it.
    ///
    /// Reads `commentFree(of:)`, not `text(of:)` and not `code(of:)`. Not
    /// `text(of:)`: a doc comment spelling `session.showsFiles` is not a
    /// read of it, and this project scans source while writing long
    /// explanatory comments, which is exactly where the two collide
    /// (CLAUDE.md, "Source-scanning guards read comments too"). Not
    /// `code(of:)`: this guard is a NEGATIVE check, and
    /// `SwiftSource.blankingCommentsAndStrings` says of those that "a
    /// negative one must be read as 'not present outside a literal'" — an
    /// interpolated expression is blanked along with the literal carrying
    /// it, so `"\(session.showsFiles)"` is a real read that view cannot
    /// see. `commentFree(of:)` blanks comments and keeps literals.
    ///
    /// Measured 2026-10-05, each repeated to a count. A planted doc comment
    /// spelling the property: red 3 of 3 against `text(of:)`, green 3 of 3
    /// against `code(of:)`, green 3 of 3 against `commentFree(of:)`. A
    /// planted interpolated read, `"\(session.showsFiles)"`: green 3 of 3
    /// against `code(of:)` — the false negative — and red 3 of 3 against
    /// `commentFree(of:)`. What `commentFree(of:)` still gets wrong is a
    /// plain string literal that merely spells the property: a planted
    /// `"session.showsFiles is the property"` was red 3 of 3. Both views are
    /// the same length in `Character`s — `SourceCorpus.lengthCheckedView`
    /// refuses one that is not — so the offender line numbers are unchanged.
    ///
    /// The exemption stays a bare file name on purpose. A second
    /// `SessionTab.swift` under this target — the case a relative path
    /// would guard against — cannot exist: with `--build-system native`
    /// SwiftPM maps both to one object path and the build fails with
    /// "multiple producers" (measured 2026-10-05; the default build system
    /// was not exercised, SwiftTerm's `Shaders.metal` breaks it here). The
    /// only case the two spellings part company on is the owner moving into
    /// a subdirectory, and there the bare name keeps exempting it, where a
    /// relative path would go red for no violation.
    @Test func onlySessionTabReadsShowsFilesOffTheSession() throws {
        let files = try Self.appSwiftFiles()
            .filter { $0.lastPathComponent != "SessionTab.swift" }
        #expect(files.count > 1, "re-anchor: no App sources found to scan")

        var offenders: [String] = []
        for file in files {
            let lines = try SourceCorpus.commentFree(of: file).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() where Self.readsShowsFilesOffASession(line) {
                offenders.append("\(Self.relativePath(of: file)):\(index + 1)")
            }
        }
        #expect(offenders.isEmpty, """
            \(offenders) read `showsFiles` off a `BrowserSession` value. That value is a \
            struct COPY, so the read sees a snapshot rather than the tab's current state — \
            go through `SessionTab.showsFiles`, which is the only way in and out.
            """)
    }

    // MARK: - Scanner reacts (self-tests over synthetic lines)

    @Test func theScannerFlagsTheShapesItIsAbout() {
        #expect(Self.readsShowsFilesOffASession("        if session.showsFiles {"))
        #expect(Self.readsShowsFilesOffASession("        tab.session?.showsFiles = false"))
        #expect(Self.readsShowsFilesOffASession("let x = browserSession.showsFiles"))
    }

    /// The honesty check: a `PaneVisibility` read is the NORMAL shape (it is
    /// what `detail`'s render conditions do) and must never be flagged.
    @Test func theScannerAcceptsAPaneVisibilityRead() {
        #expect(Self.readsShowsFilesOffASession("                        if visibility.showsFiles {") == false)
        #expect(Self.readsShowsFilesOffASession("        showsFiles = saved.showsFiles") == false)
        #expect(Self.readsShowsFilesOffASession("    var showsFiles = true") == false)
    }

    // MARK: - Scanner

    /// Whether `line` accesses `showsFiles` on a receiver whose name says
    /// "session". Deliberately literal, like the phase's other scanners.
    private static func readsShowsFilesOffASession(_ line: String) -> Bool {
        // Every read found below starts at an occurrence of the needle, so a
        // line without one is answered before it is split into characters —
        // this runs over every line of the App target.
        guard line.contains("showsFiles") else { return false }
        let characters = Array(line)
        let needle = Array("showsFiles")
        guard characters.count >= needle.count else { return false }
        for index in 0...(characters.count - needle.count) {
            guard needle.isEmpty || characters[index] == needle[0],
                characters[index..<(index + needle.count)].elementsEqual(needle) else { continue }
            // A member access, not the property's own declaration.
            guard index > 0, characters[index - 1] == "." else { continue }
            var start = index - 1
            // An optional chain (`tab.session?.showsFiles`) belongs to the
            // receiver's name for this purpose.
            if start > 0, characters[start - 1] == "?" { start -= 1 }
            let receiverEnd = start
            while start > 0,
                  characters[start - 1].isLetter || characters[start - 1].isNumber
                    || characters[start - 1] == "_" {
                start -= 1
            }
            guard start < receiverEnd else { continue }
            if String(characters[start..<receiverEnd]).lowercased().contains("session") {
                return true
            }
        }
        return false
    }
}
