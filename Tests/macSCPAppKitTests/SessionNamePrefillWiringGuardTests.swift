import Foundation
import Testing

@testable import macSCPCore

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
/// - **V6** The rule is called with the wrong arguments and answers
///   nothing: `freeName(basedOn: tab.displayTitle, avoiding: [])` avoids an
///   empty world, so every name is free. The call is right there in the
///   source and the property is gone. Found by review, which got it past
///   the first version of this suite — and then got a second one past the
///   fix, `avoiding: sessionListViewModel.sessions.filter { _ in false }`,
///   which a substring check reads as compliant. The argument list is
///   therefore compared WHOLE, which makes these two checks
///   spelling-exact: a reformat of the call fails them, deliberately, and
///   is fixed by updating the expected text once.
/// - **V7** The rule is called and its answer thrown away — the call reads
///   as wired while the raw name goes into the field. The most plausible
///   edit of the lot, so it is followed rather than matched: the guard
///   reads what the call's result is bound to and requires THAT to be what
///   reaches `saveName`, written exactly once. The "once" is the second
///   half, and review had to point it out: `var proposed = freeName(…)`
///   followed by `proposed = host.alias` satisfies every other check here.
/// - **V9** A check in this suite names a symbol in the code it guards,
///   and a rename switches it off in silence. That is not hypothetical: V5
///   filtered on a property name, the property was renamed in a later fix,
///   and the check went on passing with `.disabled(…)` sitting on the Save
///   button. Nothing below spells a symbol it could instead read — the
///   conflict property's name comes off the source, the two catalogue keys
///   come off `SessionNameConflict`.
/// - **V8** The form spells a catalogue key itself, so the sentence it
///   shows stops following the case Core decided. Which text belongs to
///   which save path is the whole of N1, and it is not the view's to
///   choose.
///
/// **Scope.** The checks below read `ContentView.swift`,
/// `ContentView+Lifecycle.swift` and `ConnectionFormView.swift` as source
/// text, plus `en.lproj/Localizable.strings` for the two sentences a
/// conflict can name. The fourth place a form's name is prefilled —
/// `ConnectionViewModel.beginEditing`, in Core — is outside that, and
/// deliberately so: a guard that scanned Core for an App-layer rule would
/// be asserting that Core knows about one. That site is an identity fill
/// like `fillForm`, and what holds it is `ConnectionViewModelTests`'
/// existing expectation that beginning an edit puts the stored name in the
/// field, which would fail if it ever started stepping aside. Weaker than
/// the checks here, and named rather than left to be discovered.
///
/// Fail-closed: a reformat that renames one of the scanned functions, or
/// that respells a checked call, reads as a missing wire rather than a
/// compliant one. Comment
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

    /// The argument list of the first `call` in `text`, brace-counted to its
    /// matching `)`. `nil` when the call is absent or unbalanced — the
    /// fail-closed direction, since an unreadable call is not a wired one.
    ///
    /// Bounded on purpose. Checking that the enclosing FUNCTION mentions
    /// `avoiding: sessionListViewModel.sessions` somewhere would pass a
    /// function that mentions it in an unrelated line and hands the rule an
    /// empty array — which is the whole of V6.
    private static func arguments(of call: String, in text: String) -> String? {
        guard let start = text.range(of: call) else { return nil }
        var depth = 1
        var index = start.upperBound
        while index < text.endIndex {
            let character = text[index]
            if character == "(" { depth += 1 }
            if character == ")" {
                depth -= 1
                if depth == 0 {
                    return String(text[start.upperBound..<index])
                        .trimmingCharacters(in: .whitespaces)
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// The V6 failure message, built rather than written inline: a
    /// `Comment` takes a literal, and both call sites want the argument
    /// list the scan actually read in the text.
    private static func wrongArguments(_ site: String, _ read: String) -> Comment {
        Comment(rawValue: "\(site) asks `freeName` with `\(read)` — the name has to be the one "
            + "about to go in the field, and the sessions have to be the stored ones. A rule "
            + "handed anything else finds every name free.")
    }

    /// The name of the property whose body asks `SessionNameConflict.build`
    /// — the form's own word for "there is a conflict", whatever it is
    /// currently called. Walks back from the call to the nearest enclosing
    /// computed-property declaration.
    private static func conflictPropertyName(in source: String) -> String? {
        let lines = source.components(separatedBy: "\n")
        guard let call = lines.firstIndex(where: { $0.contains("SessionNameConflict.build(") })
        else { return nil }
        for line in lines[...call].reversed() {
            guard let keyword = line.range(of: "var "), line.hasSuffix("{") else { continue }
            let name = line[keyword.upperBound...]
                .components(separatedBy: CharacterSet(charactersIn: ": "))
                .first ?? ""
            return name.isEmpty ? nil : String(name)
        }
        return nil
    }

    /// Whether the answer `SessionNameCollision.freeName` gives inside
    /// `body` is what ends up in the name field.
    ///
    /// Follows the binding rather than matching a spelling, because the two
    /// call sites bind differently: the import assigns the call straight to
    /// `form.saveName`, "Save as Session" binds it to a local first (it has
    /// a `guard` between) and assigns that. Reading the left-hand side and
    /// then requiring the SAME name to reach `saveName` covers both, and
    /// covers V7 in either.
    private static func freeNameReachesTheNameField(in body: String) -> Bool {
        guard let call = body.range(of: "SessionNameCollision.freeName(") else { return false }
        let before = body[body.startIndex..<call.lowerBound]
            .trimmingCharacters(in: .whitespaces)
        guard before.hasSuffix("=") else { return false }
        let target = String(before.dropLast())
            .trimmingCharacters(in: .whitespaces)
            .components(separatedBy: " ").last ?? ""
        guard !target.isEmpty else { return false }
        // Written once, so a second assignment cannot overwrite the answer
        // on its way to the field: `var proposed = freeName(…)` followed by
        // `proposed = host.alias` reads as wired and saves the raw name.
        // Spaces on both sides so `saveName` is not seen inside `form.saveName`.
        guard occurrences(of: " \(target) = ", in: body) == 1 else { return false }
        if target.hasSuffix("saveName") { return true }
        return body.contains("saveName = \(target)")
    }

    /// The arguments `SessionNameCollision.freeName` is called with inside
    /// `function`, or `nil` if it is not called there at all.
    private static func freeNameArguments(
        inFunction function: String, ofFile path: String
    ) throws -> String? {
        guard let body = try functionBody(function, in: source(path)) else { return nil }
        return arguments(of: "SessionNameCollision.freeName(", in: body)
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

        // **V6** — and asks it about the title, against the sessions that
        // exist. A call with either argument replaced answers nothing and
        // still reads as wired.
        let arguments = try Self.freeNameArguments(
            inFunction: "saveAsSession", ofFile: Self.lifecyclePath)
        let read = arguments ?? "nothing this guard could read"
        #expect(arguments == "basedOn: tab.displayTitle, avoiding: sessionListViewModel.sessions",
                Self.wrongArguments("\"Save as Session\"", read))

        // **V7** — and the answer is what reaches the field.
        #expect(Self.freeNameReachesTheNameField(in: body), """
            "Save as Session" calls `freeName` and does not put its answer in the name field — \
            the call reads as wired and the raw title is what gets saved.
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

        // **V6**, the import's half.
        let arguments = try Self.freeNameArguments(
            inFunction: "fillFromImported", ofFile: Self.contentViewPath)
        let read = arguments ?? "nothing this guard could read"
        #expect(arguments == "basedOn: host.alias, avoiding: sessionListViewModel.sessions",
                Self.wrongArguments("The ssh-config import", read))

        // **V7**, the import's half.
        #expect(Self.freeNameReachesTheNameField(in: body), """
            The ssh-config import calls `freeName` and does not put its answer in the name \
            field — the call reads as wired and the raw alias is what gets saved.
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
            \(assignments) assignments to `saveName` in these two files — counted in the pass \
            that wrote this number: the stored-session fill and the ssh-config import in \
            ContentView.swift, and "Save as Session" in ContentView+Lifecycle.swift. A fourth \
            IN THESE FILES is a prefilled name nobody has decided about; project-wide there is \
            already a fourth, `ConnectionViewModel.beginEditing` in Core, which this suite does \
            not read (see the note on this type).
            """)
    }

    /// **V5** and **V8** — the warning is drawn, says what the conflict
    /// says, and blocks nothing.
    @Test func theWarningIsShownAndBlocksNothing() throws {
        let source = try Self.withoutComments(Self.source(Self.formPath))
        #expect(source.contains("SessionNameConflict.build("), """
            The form decides for itself whether a name collides instead of asking \
            `SessionNameConflict`, where a test can reach the answer.
            """)
        #expect(source.contains("conflict.messageKey") && source.contains("conflict.messageDefault"), """
            The form no longer renders the conflict's own sentence — which text is true \
            depends on which save path runs, and that is the conflict's decision.
            """)
        // Derived from `SessionNameConflict`, not spelled here: a check
        // that names a key can be silenced by renaming the key, which is
        // the failure this whole test learned the hard way one line down.
        let session = StoredSession(id: UUID(), name: "web", kind: .ssh)
        for conflict in [SessionNameConflict.replaces(session), .duplicates(session)] {
            #expect(!source.contains("\"\(conflict.messageKey)\""),
                    Comment(rawValue: "The form spells `\(conflict.messageKey)` itself. Saving "
                        + "replaces on the new path and duplicates on the edit path; a key "
                        + "chosen in the view is a sentence nothing holds to the path it "
                        + "describes."))
        }

        // **V5** — and nothing is disabled on account of it.
        //
        // The property's NAME is read off the source rather than written
        // here. Written here, it silently stopped matching the day the
        // property was renamed — this check went on passing while
        // `.disabled(nameConflict != nil)` sat on the Save button, which is
        // exactly what it exists to catch. A guard that names a symbol is a
        // guard a rename can switch off without touching its line.
        guard let property = Self.conflictPropertyName(in: source) else {
            Issue.record("""
                No property in ConnectionFormView.swift asks `SessionNameConflict.build` — \
                this check has nothing to look for and would pass for the wrong reason.
                """)
            return
        }
        let blocking = source
            .components(separatedBy: "\n")
            .filter { $0.contains(".disabled(") && $0.contains(property) }
        #expect(blocking.isEmpty,
                Comment(rawValue: "A name collision disables a control via `\(property)`: "
                    + "\(blocking). The warning makes the overwrite visible; it does not "
                    + "forbid it."))
    }

    /// **V8**'s other half — every sentence a conflict can name is actually
    /// in the catalogue.
    ///
    /// The key lives in Core and the text lives in the App bundle, so
    /// nothing but this connects them: a key Core returns that no catalogue
    /// carries renders to the user as the raw key, in every language at
    /// once. English is enough to check here — `LocalizationParityTests`
    /// holds the other three to English's key set.
    @Test func bothConflictSentencesExistInTheCatalogue() throws {
        let session = StoredSession(id: UUID(), name: "web", kind: .ssh)
        let catalogue = try Self.source(
            "Sources/MacSCPAppKit/Resources/en.lproj/Localizable.strings")
        for conflict in [SessionNameConflict.replaces(session), .duplicates(session)] {
            #expect(catalogue.contains("\"\(conflict.messageKey)\" = "),
                    Comment(rawValue: "`\(conflict.messageKey)` is what `SessionNameConflict` "
                        + "returns for this case and the English catalogue does not declare it."))
        }
    }
}
