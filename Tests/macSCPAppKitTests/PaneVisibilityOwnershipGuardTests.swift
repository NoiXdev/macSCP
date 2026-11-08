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

    /// Collapses runs of spaces and tabs, the way `ReconnectWiringGuardTests`
    /// normalizes a sanctioned line, so the declared reads below are
    /// indentation-independent.
    private static func normalized(_ line: String) -> String {
        line.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
    }

    /// One sanctioned READ, not one exempted file.
    private struct SanctionedRead {
        /// Path relative to the App target, as `relativePath(of:)` prints it
        /// — a path and not a bare file name, see below.
        let file: String
        /// The line as it must read after comments are blanked and
        /// whitespace normalized.
        let code: String
        /// How many times that exact line may appear in that file, so a
        /// SECOND line spelled identically cannot ride on the allowance.
        let occurrences: Int
        let reason: String
    }

    /// The reads that own this property. Two lines, in two files.
    ///
    /// (Withdrawn: this used to exempt whole FILES —
    /// `private static let exemptedOwners: Set<String> = ["SessionTab.swift",
    /// "SessionInstallation.swift"]` — with the reason, verbatim: "Bare file
    /// names on purpose, for the reason the guard's own doc comment gives: a
    /// second file of either name under this target cannot exist, and the bare
    /// name keeps exempting an owner that moves into a subdirectory where a
    /// relative path would go red for no violation." Both halves are
    /// withdrawn. The exemption admitted everything in both files: the
    /// re-review of fix round 2 planted `let zzSession = built` plus
    /// `_ = zzSession.showsFiles` inside BOTH of them and the suite was
    /// **GREEN** against its 5 tests, while the same two lines in non-exempt
    /// `ContentView.swift` were **RED** — both reproduced by fix round 3. And
    /// the bare name was matched with `lastPathComponent`, so a same-named
    /// file in a subdirectory would have been exempt with
    /// `theExemptedOwnersAreFilesTheWalkFinds` still passing. No duplicate
    /// basenames exist under this target today
    /// (`/usr/bin/find Sources/MacSCPAppKit -name '*.swift' -exec basename {}
    /// \; | sort | uniq -d` prints nothing, exit 0), which is why it was
    /// latent and not live.)
    ///
    /// What replaces it is the same instrument `ReconnectWiringGuardTests`
    /// uses for a sanctioned site: a path, a line, a count and a reason. The
    /// owning files are scanned like every other file.
    ///
    /// (Withdrawn, verbatim: "the two lines below are the only ones their
    /// scan may produce." The sentence is true, and a reader takes a
    /// stronger claim from it than the instrument supports — which is the
    /// half nobody supplies for themselves. What the instrument actually
    /// says is stated in Ruling T8.19 below.)
    ///
    /// **Ruling T8.19: the allowance is keyed on TEXT, and text can be
    /// transplanted. Stated, not closed.** An entry is a (path, normalized
    /// line, count) triple and says nothing about which DECLARATION owns the
    /// line, so the sanctioned text can be moved onto a genuine read of a
    /// struct copy in the same file while the count still comes back 1. The
    /// re-review of fix round 3 measured it, in `SessionTab.swift` alone and
    /// in prose here rather than in code: the owning getter was respelled so
    /// that the receiver of the property access became a closure argument —
    /// which the scanner below does not flag, because that receiver's name
    /// does not say "session" — and a new nested struct holding a stored
    /// optional `BrowserSession` carried a computed property whose getter was
    /// spelled byte-identically to the sanctioned line, so the count stayed
    /// 1 and the negative check had nothing to flag. Filter
    /// `PaneVisibilityOwnershipGuardTests`, control line
    /// `── control: 5 test(s) ran, 0 pre-existing failures`: GREEN. Filter
    /// `macSCPAppKitTests`, control line
    /// `── control: 3170 test(s) ran, 0 pre-existing failures`: GREEN, 3170
    /// tests and none of them noticed.
    ///
    /// Why it stays open, so the reasoning can be disagreed with rather than
    /// guessed at. It is NARROWER than what it replaced, where both files
    /// were exempt as wholes and any read in either was green, so it is a
    /// residual of the new instrument and not a regression. It needs the
    /// owning getter respelled in the same change — a deliberate edit to the
    /// one line this allowance names, which
    /// `everySanctionedShowsFilesReadStillExistsExactlyAsOftenAsDeclared`
    /// puts in front of a reviewer. And the fix for a text-keyed allowance
    /// being text-keyed is a structural boundary on `showsFiles` itself: a
    /// design change outside Task 8, and not one worth making for a
    /// pane-visibility read.
    private static let sanctionedReads: [SanctionedRead] = [
        SanctionedRead(
            file: "SessionTab.swift",
            code: "get { session?.showsFiles ?? true }",
            occurrences: 1,
            reason:
                "`SessionTab.showsFiles`'s getter — the one way IN, which is what the rest of the App layer is held to. It reads through the stored property on the installed session rather than off a struct copy, which is the property this guard is about."),
        SanctionedRead(
            file: "SessionInstallation.swift",
            code: "session?.showsFiles = value",
            occurrences: 1,
            reason:
                "`SessionInstallation.setShowsFiles(_:)` — the one way OUT, reached only through `SessionTab.showsFiles`'s setter. It moved here from `SessionTab` with the session storage in fix round 2 of Task 8 (Ruling T8.8); it writes THROUGH the stored property, so it is not a read of a copy either."),
    ]

    /// The positive check the allowance owes, in the shape
    /// `everySanctionedSiteStillExistsExactlyAsOftenAsDeclared` has: every
    /// declared read must still be in its file, exactly as often as claimed.
    ///
    /// A count of 0 means the line moved and the allowance has stopped
    /// describing the code; a count of 2 means a second line spelled
    /// identically is riding on it. A path that no longer resolves throws out
    /// of `commentFree(of:)`, which is a loud failure and not a silent
    /// widening — the failure mode the withdrawn
    /// `theExemptedOwnersAreFilesTheWalkFinds` existed for, now covered by the
    /// same check that covers the line.
    @Test func everySanctionedShowsFilesReadStillExistsExactlyAsOftenAsDeclared() throws {
        for read in Self.sanctionedReads {
            let url = Self.appSources.appendingPathComponent(read.file)
            let matches = try SourceCorpus.commentFree(of: url)
                .components(separatedBy: "\n")
                .filter { Self.normalized($0) == read.code }
                .count
            #expect(matches == read.occurrences, """
                `\(read.code)` appears \(matches) time(s) in \(read.file), expected \
                \(read.occurrences). Sanctioned for: \(read.reason)
                """)
        }
    }

    /// The guard: the two LINES on `sanctionedReads` own this property,
    /// nobody else touches it.
    ///
    /// Two since fix round 2 of Task 8 (Ruling T8.8), which moved the session
    /// storage itself out of `SessionTab` and behind `SessionInstallation`, a
    /// type in its own file whose `session` is `private(set)` so that a
    /// `BrowserSession` can reach a tab only through the call that asks. The
    /// write `session?.showsFiles = newValue` moved with the storage;
    /// `SessionTab.showsFiles` is still the only way in and out, and now
    /// forwards to `SessionInstallation.setShowsFiles(_:)`. Neither of those
    /// reads a struct COPY, which is what this guard is about: both write
    /// through the stored property.
    ///
    /// **Lines and not files, since fix round 3 of Task 8.** Round 2 exempted
    /// the two owning FILES, which exempted everything in them: a planted
    /// read of a copy inside either one was GREEN, measured twice. The
    /// allowance is now one entry per read, with a path, a count and a
    /// reason, and `everySanctionedShowsFilesReadStillExistsExactlyAsOftenAsDeclared`
    /// is the positive check beside it — an allowance that has stopped
    /// matching is red there, rather than quietly widening this negative
    /// check, which is CLAUDE.md's "only a NEGATIVE check can go stale in
    /// silence" arriving through an exclusion list rather than through a
    /// pattern.
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
    /// (Withdrawn, verbatim: "The exemption stays a bare file name on
    /// purpose. A second `SessionTab.swift` under this target — the case a
    /// relative path would guard against — cannot exist: with
    /// `--build-system native` SwiftPM maps both to one object path and the
    /// build fails with \"multiple producers\" (measured 2026-10-05; the
    /// default build system was not exercised, SwiftTerm's `Shaders.metal`
    /// breaks it here). The only case the two spellings part company on is
    /// the owner moving into a subdirectory, and there the bare name keeps
    /// exempting it, where a relative path would go red for no violation."
    /// The 2026-10-05 measurement is not withdrawn — it still says what it
    /// says about two same-named files. What is withdrawn is the preference
    /// read off it: an owner that moves into a subdirectory is now red HERE,
    /// in the positive check, which is where a moved allowance should be
    /// read, and the one-line fix for it is the new path. The bare name's
    /// cost was that it was matched with `lastPathComponent`, so it could
    /// not tell those two spellings apart at all.)
    @Test func onlySessionTabReadsShowsFilesOffTheSession() throws {
        let files = try Self.appSwiftFiles()
        #expect(files.count > 1, "re-anchor: no App sources found to scan")

        var offenders: [String] = []
        for file in files {
            let relative = Self.relativePath(of: file)
            let lines = try SourceCorpus.commentFree(of: file).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() where Self.readsShowsFilesOffASession(line) {
                let code = Self.normalized(line)
                let sanctioned = Self.sanctionedReads.contains {
                    $0.file == relative && $0.code == code
                }
                if !sanctioned { offenders.append("\(relative):\(index + 1): \(code)") }
            }
        }
        #expect(offenders.isEmpty, """
            \(offenders) read `showsFiles` off a `BrowserSession` value. That value is a \
            struct COPY, so the read sees a snapshot rather than the tab's current state — \
            go through `SessionTab.showsFiles`, which is the only way in and out. If one of \
            these really is a new owning read, add it to `sanctionedReads` WITH a reason; no \
            file is exempt as a whole.
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
