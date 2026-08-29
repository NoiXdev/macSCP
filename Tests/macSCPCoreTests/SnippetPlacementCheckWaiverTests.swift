import Foundation
import Testing
@testable import macSCPCore

/// The per-snippet exit from the placeholder PLACEMENT check
/// (`Snippet.skipsPlaceholderPlacementCheck`).
///
/// Three properties, and the third is the one the design is built around:
///
/// 1. **Both directions.** A template the check refuses is accepted with
///    the waiver and still refused without it. A suite that only asserted
///    the accepting direction would stay green over a waiver that is always
///    on.
/// 2. **It switches off the placement question and nothing else.** The name
///    rule, the unused-placeholder check, the single-quoting of every value
///    and `SnippetSendPlanner`'s refusal of a multi-line insert all behave
///    exactly as they do without it.
/// 3. **It cannot travel.** Its own suite is `SnippetExportCodecTests`,
///    where the export bytes are observed; here it is only stated that the
///    stored default is the check ON.
///
/// No expectation below puts a substituted value into a failure message of
/// its own. The values used are visibly non-secret test payloads, and the
/// one comparison that involves resolved text compares it as a whole rather
/// than reporting the value separately — a resolved value belongs on the
/// screen of whoever typed it and nowhere else, test output included.
@Suite("Snippet placement-check waiver")
struct SnippetPlacementCheckWaiverTests {
    private func placeholder(_ name: String) -> SnippetVariable {
        SnippetVariable(
            name: name, prompt: name, kind: .freeText, placement: .placeholder,
            defaultValue: "", remembersLastValue: false)
    }

    // MARK: - Both directions

    /// One template per refusal the placement question can produce: inside
    /// quotes, not a plain argument, an argument of a command that re-parses
    /// its own arguments, and a command the survey refuses to read at all.
    /// Four, counted against `SnippetVariableSubstitution.Problem`'s cases
    /// in the pass that writes this: the enum's other two members
    /// (`invalidName`, `unusedPlaceholder`) are not placement answers and
    /// have their own tests below.
    private static let refusedTemplates = [
        #"echo "{{X}}""#,
        "A={{X}} echo hi",
        "[ -f {{X}} ]",
        "cat <<EOF\n{{X}}\nEOF",
    ]

    @Test(
        "without the waiver each of these templates is still refused",
        arguments: SnippetPlacementCheckWaiverTests.refusedTemplates)
    func theCheckStillRefusesWithoutTheWaiver(command: String) {
        #expect(
            SnippetVariableSubstitution.firstDeclarationProblem(
                command: command, variables: [placeholder("X")]) != nil)
    }

    @Test(
        "with the waiver each of these templates is accepted",
        arguments: SnippetPlacementCheckWaiverTests.refusedTemplates)
    func theWaiverAcceptsWhatTheCheckRefuses(command: String) {
        #expect(
            SnippetVariableSubstitution.firstDeclarationProblem(
                command: command, variables: [placeholder("X")],
                skipsPlacementCheck: true) == nil)
    }

    /// The waiver read off a stored snippet rather than passed as a literal
    /// — the shape both App call sites use. Without it the same snippet is
    /// refused, so the field is what decides and not the call.
    @Test("the field on the snippet is what decides")
    func theStoredFieldDecides() {
        let command = "[ -f {{PATH}} ]"
        let variables = [placeholder("PATH")]
        let waived = Snippet(
            name: "check", command: command, variables: variables,
            skipsPlaceholderPlacementCheck: true)
        let checked = Snippet(name: "check", command: command, variables: variables)

        #expect(
            SnippetVariableSubstitution.firstDeclarationProblem(
                command: waived.command, variables: waived.variables,
                skipsPlacementCheck: waived.skipsPlaceholderPlacementCheck) == nil)
        #expect(
            SnippetVariableSubstitution.firstDeclarationProblem(
                command: checked.command, variables: checked.variables,
                skipsPlacementCheck: checked.skipsPlaceholderPlacementCheck)
                == .placeholderIsReparsedByItsCommand(name: "PATH"))
    }

    /// A snippet built without saying anything about the waiver has the
    /// check ON. The default is stated here rather than only implied by the
    /// tests above, because it is the direction that must never drift.
    @Test("the default is the check on")
    func theDefaultIsTheCheckOn() {
        #expect(Snippet(name: "n", command: "c").skipsPlaceholderPlacementCheck == false)
    }

    // MARK: - It resolves what the check would have blocked

    /// The waived template actually produces a command, and the value in it
    /// is still `PosixQuoting.singleQuoted`: the waiver removes the
    /// POSITION question, not the quoting. `[ … ]` is precisely the case
    /// where quoting cannot make the value inert — that is why the check
    /// refuses it and why switching it off is a decision a person takes per
    /// snippet.
    @Test("a waived snippet resolves the placeholder, still single-quoted")
    func aWaivedSnippetResolves() {
        let resolved = SnippetVariableSubstitution.resolve(
            command: "[ -f {{PATH}} ]", variables: [placeholder("PATH")],
            values: ["PATH": "/srv/some file"])
        #expect(resolved == "[ -f '/srv/some file' ]")
    }

    // MARK: - What it does NOT switch off

    /// The name rule is not a placement question: a name that is not a
    /// POSIX shell identifier would be emitted as extra COMMANDS by
    /// `resolve`'s `export` branch, and nothing a user ticks in the editor
    /// may reach that.
    @Test("the waiver does not switch off the name rule")
    func theWaiverKeepsTheNameRule() {
        let hostile = SnippetVariable(
            name: "A;touch /tmp/m;B", prompt: "p", kind: .freeText, placement: .environment,
            defaultValue: "v", remembersLastValue: false)
        #expect(
            SnippetVariableSubstitution.firstDeclarationProblem(
                command: "echo hi", variables: [hostile], skipsPlacementCheck: true)
                == .invalidName(name: "A;touch /tmp/m;B"))
    }

    /// Nor the unused check: a declaration whose `{{NAME}}` appears nowhere
    /// asks the user for a value that reaches nothing, whatever the
    /// placement rules say.
    @Test("the waiver does not switch off the unused-placeholder check")
    func theWaiverKeepsTheUnusedCheck() {
        #expect(
            SnippetVariableSubstitution.firstDeclarationProblem(
                command: "echo hi", variables: [placeholder("X")], skipsPlacementCheck: true)
                == .unusedPlaceholder(name: "X"))
    }

    /// `SnippetSendPlanner`'s refusal of a multi-line insert is a different
    /// question — how bytes reach a shell, not where a value sits — and the
    /// waiver leaves it exactly where it was.
    ///
    /// Structurally it could not reach it anyway: `plan` takes a command,
    /// an `execute` flag and a bracketed-paste flag, and no `Snippet`. That
    /// is the reason there is nothing to pass here, and this test states
    /// the outcome so the sentence is not only prose.
    @Test("the waiver does not touch the multi-line insert refusal")
    func theWaiverLeavesTheSendPlanAlone() {
        let waived = Snippet(
            name: "deploy", command: "cd /srv\nmake all", skipsPlaceholderPlacementCheck: true)
        #expect(
            SnippetSendPlanner.plan(
                command: waived.command, execute: false, bracketedPaste: false)
                == .refusedMultilineInsert)
        #expect(
            SnippetSendPlanner.plan(
                command: waived.command, execute: false, bracketedPaste: false)
                == SnippetSendPlanner.plan(
                    command: "cd /srv\nmake all", execute: false, bracketedPaste: false))
    }

    /// And the audit line still carries the TEMPLATE. `SnippetAuditDetail`
    /// takes a `Snippet`, so the waiver is the kind of field that could
    /// have started appearing in a log line; it does not.
    @Test("the waiver changes nothing about the audit line")
    func theWaiverLeavesTheAuditLineAlone() {
        let command = "[ -f {{PATH}} ]"
        let waived = Snippet(
            name: "check", command: command, variables: [placeholder("PATH")],
            skipsPlaceholderPlacementCheck: true)
        #expect(SnippetAuditDetail.text(for: waived) == "ran snippet \u{201C}check\u{201D}: \(command)")
    }

    // MARK: - Decoding a file that predates the field

    /// The trap this project measured this week: `Codable` synthesizes no
    /// default for a MISSING key — it throws. So the absent-key path is
    /// proven against real JSON TEXT that lacks the key, not against a
    /// round trip through a value in memory, which would only prove that
    /// today's encoder and today's decoder agree with each other.
    @Test("a store file without the key decodes with the check on")
    func aFileWithoutTheKeyDecodesWithTheCheckOn() throws {
        let json = Data("""
            {"id":"44444444-4444-4444-4444-444444444444","name":"Check",
             "command":"[ -f {{PATH}} ]","tags":["ops"]}
            """.utf8)

        let snippet = try JSONDecoder().decode(Snippet.self, from: json)

        #expect(snippet.skipsPlaceholderPlacementCheck == false)
        #expect(snippet.command == "[ -f {{PATH}} ]")
        #expect(snippet.tags == ["ops"])
    }

    /// The other direction, also from literal JSON: a file that DOES carry
    /// the key is read, so the absent-key default above is a default and
    /// not a hard-wired `false`.
    @Test("a store file carrying the key decodes it")
    func aFileCarryingTheKeyDecodesIt() throws {
        let json = Data("""
            {"id":"55555555-5555-5555-5555-555555555555","name":"Check",
             "command":"[ -f {{PATH}} ]","skipsPlaceholderPlacementCheck":true}
            """.utf8)

        let snippet = try JSONDecoder().decode(Snippet.self, from: json)

        #expect(snippet.skipsPlaceholderPlacementCheck == true)
    }

    /// And a snippet saved with the waiver on comes back with it on — the
    /// store keeps it, which is what makes it a per-snippet setting rather
    /// than a per-session one.
    @Test("the waiver survives a store round trip")
    func theWaiverSurvivesAStoreRoundTrip() throws {
        let original = Snippet(
            name: "check", command: "[ -f {{PATH}} ]", skipsPlaceholderPlacementCheck: true)
        let decoded = try JSONDecoder().decode(
            Snippet.self, from: JSONEncoder().encode(original))
        #expect(decoded.skipsPlaceholderPlacementCheck == true)
        #expect(decoded == original)
    }
}
