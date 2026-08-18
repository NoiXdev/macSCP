import Foundation
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
/// - Comments are not stripped: a comment that spells `session.showsFiles`
///   is flagged too. That is deliberate — the wrong shape should not be
///   modelled anywhere in the target, least of all in prose someone copies.
/// - `visibility.showsFiles` and any other `PaneVisibility` read is
///   untouched; the receiver is not a session. `theScannerAcceptsAPaneVisibilityRead`
///   pins that this is deliberate rather than a gap.
@Suite("Pane visibility ownership guard")
struct PaneVisibilityOwnershipGuardTests {
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let appSources = repoRoot.appendingPathComponent("Sources/MacSCPAppKit")

    /// The guard: `SessionTab.swift` owns this property, nobody else touches
    /// it.
    @Test func onlySessionTabReadsShowsFilesOffTheSession() throws {
        let files = try FileManager.default
            .contentsOfDirectory(at: Self.appSources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "SessionTab.swift" }
        #expect(files.count > 1, "re-anchor: no App sources found to scan")

        var offenders: [String] = []
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() where Self.readsShowsFilesOffASession(line) {
                offenders.append("\(file.lastPathComponent):\(index + 1)")
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
        let characters = Array(line)
        let needle = Array("showsFiles")
        guard characters.count >= needle.count else { return false }
        for index in 0...(characters.count - needle.count) {
            guard Array(characters[index..<(index + needle.count)]) == needle else { continue }
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
