import Foundation
import Testing

/// Guards the one property the value tests cannot reach: **a name macSCP
/// invents steps aside, and a name that IS a session's own does not.**
///
/// `SessionNameCollisionTests` and `SessionNameConflictTests` prove what the
/// two rules answer. Both stay green if nothing calls them, and both stay
/// green if the wrong call site calls them — and the wrong one is the
/// expensive one: `freeName` on the form that edits a stored session would
/// show the user a renamed copy of the session they opened, silently, with
/// every suite still passing. This project has no SwiftUI rendering harness
/// (the boundary its other wiring guards document), so the only way to see
/// which call site got which rule is to read the source.
///
/// Where the property could be violated from, which is what picked the
/// checks below:
///
/// - **V1** "Save as Session" goes back to assigning the tab title raw, so
///   saving replaces whatever stored session happens to carry that title.
/// - **V2** The ssh-config import goes back to assigning the alias raw —
///   the older of the two holes.
/// - **V3** The stored-session fill starts stepping aside, renaming the
///   session it is showing.
/// - **V4** A third invented-name path appears and nobody wires it, or one
///   of the two loses its call while the other keeps it.
/// - **V5** The warning grows into a refusal — a `.disabled` on the save
///   buttons — which the design rejects outright: saving onto an existing
///   name stays possible, the warning only makes it visible.
///
/// Read as text, and fail-closed: a reformat that renames one of the three
/// functions reads as a missing wire rather than a compliant one. Comment
/// lines are stripped before every scan, so a comment that MENTIONS the
/// rule cannot stand in for a call to it — which is exactly what the
/// stored-session fill carries.
@Suite("Session name prefill wiring guard")
struct SessionNamePrefillWiringGuardTests {
    /// `#filePath` is
    /// `<repoRoot>/Tests/macSCPAppKitTests/SessionNamePrefillWiringGuardTests.swift`.
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static func source(_ path: String) throws -> String {
        try String(
            contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    private static let contentViewPath = "Sources/MacSCPAppKit/ContentView.swift"
    private static let lifecyclePath = "Sources/MacSCPAppKit/ContentView+Lifecycle.swift"
    private static let formPath = "Sources/MacSCPAppKit/ConnectionFormView.swift"

    /// Drops whole-line comments. A comment naming the rule is not a call to
    /// it, and one of the three functions guarded here deliberately explains
    /// in prose why it does NOT step aside.
    private static func withoutComments(_ source: String) -> String {
        source
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// One long line per body: whitespace collapsed, so a check does not
    /// depend on where the formatter chose to break a call.
    private static func collapsed(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// The body of the function called `name`, from its declaration to the
    /// first line that is its own closing brace at member indentation —
    /// the delimiter this project's other wiring guards use.
    private static func functionBody(_ name: String, in source: String) -> String? {
        let lines = withoutComments(source).components(separatedBy: "\n")
        guard let index = lines.firstIndex(where: { $0.contains("func \(name)(") })
        else { return nil }
        return collapsed(
            lines[index...].prefix { !$0.hasPrefix("    }") }.joined(separator: "\n"))
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    /// **V1** — the tab title reaches the form through the rule, never raw.
    @Test func saveAsSessionStepsAsideFromATakenTitle() throws {
        guard let body = try Self.functionBody(
            "saveAsSession", in: Self.source(Self.lifecyclePath))
        else {
            Issue.record("No `saveAsSession` in ContentView+Lifecycle.swift to read.")
            return
        }
        #expect(body.contains("SessionNameCollision.freeName("), """
            "Save as Session" no longer asks `SessionNameCollision.freeName` — the tab's \
            title would replace a stored session that happens to carry it.
            """)
        #expect(!body.contains("= tab.displayTitle"), """
            "Save as Session" assigns `tab.displayTitle` raw again.
            """)
    }

    /// **V2** — same for the ssh-config alias.
    @Test func theSSHConfigImportStepsAsideFromATakenAlias() throws {
        guard let body = try Self.functionBody(
            "fillFromImported", in: Self.source(Self.contentViewPath))
        else {
            Issue.record("No `fillFromImported` in ContentView.swift to read.")
            return
        }
        #expect(body.contains("SessionNameCollision.freeName("), """
            The ssh-config import no longer asks `SessionNameCollision.freeName` — an alias \
            would replace a stored session of that name.
            """)
        #expect(!body.contains("saveName = host.alias"), """
            The ssh-config import assigns `host.alias` raw again.
            """)
    }

    /// **V3** — and the stored-session fill does NOT, which is the arm that
    /// would break without a symptom.
    @Test func theStoredSessionFillDoesNotStepAside() throws {
        guard let body = try Self.functionBody(
            "fillForm", in: Self.source(Self.contentViewPath))
        else {
            Issue.record("No `fillForm` in ContentView.swift to read.")
            return
        }
        #expect(body.contains("saveName = stored.name"), """
            The form filled from a stored session no longer shows that session's own name.
            """)
        #expect(!body.contains("SessionNameCollision."), """
            The form filled from a stored session steps aside from its OWN name — it would \
            rename the session instead of updating it, and nothing else would notice.
            """)
    }

    /// **V4** — exactly the invented-name paths ask the rule, counted over
    /// both files rather than written down here.
    @Test func onlyTheInventedNamesAskTheRule() throws {
        let sources = try [Self.contentViewPath, Self.lifecyclePath].map {
            Self.withoutComments(try Self.source($0))
        }
        let asks = sources.reduce(0) {
            $0 + Self.occurrences(of: "SessionNameCollision.freeName(", in: $1)
        }
        let assignments = sources.reduce(0) {
            $0 + Self.occurrences(of: "saveName = ", in: $1)
        }
        #expect(asks == 2, """
            \(asks) call sites ask `SessionNameCollision.freeName` across ContentView.swift and \
            ContentView+Lifecycle.swift; the invented names are "Save as Session" and the \
            ssh-config import, and they are two.
            """)
        #expect(assignments == 3, """
            \(assignments) assignments to `saveName` across those two files — counted in the \
            pass that wrote this number: the stored-session fill and the ssh-config import in \
            ContentView.swift, and "Save as Session" in ContentView+Lifecycle.swift. A fourth \
            is a prefilled name nobody has decided about.
            """)
    }

    /// **V5** — the warning names a session and does not block saving.
    @Test func theWarningIsShownAndBlocksNothing() throws {
        let source = try Self.withoutComments(Self.source(Self.formPath))
        #expect(source.contains("\"connection.saveName.replaces %@\""), """
            The connection form no longer draws the collision warning at all.
            """)
        #expect(source.contains("SessionNameConflict.replacedSession("), """
            The form decides for itself whether a name collides instead of asking \
            `SessionNameConflict`, where a test can reach the answer.
            """)
        let blocking = source
            .components(separatedBy: "\n")
            .filter { $0.contains(".disabled(") && $0.contains("replacedSession") }
        #expect(blocking.isEmpty, """
            A collision disables a control: \(blocking). The warning makes the overwrite \
            visible; it does not forbid it.
            """)
    }
}
