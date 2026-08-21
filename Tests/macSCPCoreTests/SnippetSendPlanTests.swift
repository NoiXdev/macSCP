import Testing
@testable import macSCPCore

/// `SnippetSendPlanner` turns a command plus two flags into the bytes that
/// go to the shell — or into a refusal.
///
/// The bracketed-paste rule is not this project's invention: SwiftTerm's own
/// ⌘V path on macOS wraps a paste in these two sequences exactly when the
/// remote has enabled mode 2004, and sends the pasted text's raw UTF-8
/// between them with no line-ending translation of any kind
/// (`MacTerminalView.paste(_:)` → `insertText(_:replacementRange:isPaste:)`
/// → `send(txt:)` → `[UInt8](txt.utf8)`). macSCP follows that rule so a
/// snippet behaves like a paste the user performed themselves.
@Suite("SnippetSendPlanner")
struct SnippetSendPlanTests {
    private static let start: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]
    private static let end: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]
    private static let cr: UInt8 = 0x0D

    /// Compared against `SnippetKeystrokes` rather than against a byte
    /// literal written out here: the point is that the planner delegates
    /// for this case, not that someone transcribed the same bytes twice.
    /// Deliberately takes a plain `String` and never builds a `Snippet` —
    /// this suite must not care whether that initializer is failable, which
    /// is a thing Task 2 changes.
    @Test("a single line inserts exactly the bytes it always did")
    func singleLineInsertIsUnchanged() {
        let plan = SnippetSendPlanner.plan(
            command: "docker ps -a", execute: false, bracketedPaste: false)
        #expect(plan == .send(SnippetKeystrokes.bytes(forLine: "docker ps -a", execute: false)))
    }

    @Test("a single line executes exactly the bytes it always did")
    func singleLineExecuteIsUnchanged() {
        let plan = SnippetSendPlanner.plan(
            command: "docker ps -a", execute: true, bracketedPaste: true)
        #expect(plan == .send(SnippetKeystrokes.bytes(forLine: "docker ps -a", execute: true)))
    }

    @Test("a single line is never bracketed, even when the mode is on")
    func singleLineIsNeverBracketed() {
        let plan = SnippetSendPlanner.plan(
            command: "echo hi", execute: false, bracketedPaste: true)
        guard case .send(let bytes) = plan else {
            Issue.record("expected bytes, got \(plan)")
            return
        }
        #expect(!bytes.starts(with: Self.start))
    }

    @Test("multiple lines are bracketed verbatim when the mode is on")
    func multilineIsBracketed() {
        let plan = SnippetSendPlanner.plan(
            command: "cd /tmp\nls -la", execute: false, bracketedPaste: true)
        #expect(plan == .send(Self.start + Array("cd /tmp\nls -la".utf8) + Self.end))
    }

    @Test("a bracketed execute appends one carriage return after the closing sequence")
    func bracketedExecuteAppendsOneReturn() {
        let plan = SnippetSendPlanner.plan(
            command: "cd /tmp\nls -la", execute: true, bracketedPaste: true)
        #expect(plan == .send(Self.start + Array("cd /tmp\nls -la".utf8) + Self.end + [Self.cr]))
    }

    @Test("without bracketing, executing sends each line with its own return")
    func unbracketedExecuteIsLineByLine() {
        let plan = SnippetSendPlanner.plan(
            command: "cd /tmp\nls -la", execute: true, bracketedPaste: false)
        #expect(plan == .send(Array("cd /tmp".utf8) + [Self.cr] + Array("ls -la".utf8) + [Self.cr]))
    }

    @Test("without bracketing, inserting several lines is refused instead of executed")
    func unbracketedMultilineInsertIsRefused() {
        let plan = SnippetSendPlanner.plan(
            command: "cd /tmp\nls -la", execute: false, bracketedPaste: false)
        #expect(plan == .refusedMultilineInsert)
    }

    /// `"\r\n"` is ONE `Character` in Swift, so a rule written with
    /// `contains("\n")` does not see a CRLF command at all — the trap
    /// `Snippet.init?` was fixed for in P3e. A CRLF command must be treated
    /// as two lines here too, not as one line containing junk.
    @Test("a CRLF command counts as two lines")
    func crlfCountsAsALineBreak() {
        let plan = SnippetSendPlanner.plan(
            command: "cd /tmp\r\nls -la", execute: false, bracketedPaste: false)
        #expect(plan == .refusedMultilineInsert)
    }

    /// The line-by-line fallback normalizes: whatever separator the command
    /// carries, each line is terminated with the same CR a keypress sends.
    @Test("the line-by-line fallback normalizes CRLF to the terminator")
    func lineByLineNormalizesCRLF() {
        let plan = SnippetSendPlanner.plan(
            command: "a\r\nb", execute: true, bracketedPaste: false)
        #expect(plan == .send(Array("a".utf8) + [Self.cr] + Array("b".utf8) + [Self.cr]))
    }

    /// A trailing newline makes a final empty line, and it is NOT dropped:
    /// at a prompt an empty line is a harmless no-op, and silently trimming
    /// input the user typed is the larger surprise.
    @Test("a trailing newline produces a trailing empty line")
    func trailingNewlineKeepsItsEmptyLine() {
        let plan = SnippetSendPlanner.plan(
            command: "echo hi\n", execute: true, bracketedPaste: false)
        #expect(plan == .send(Array("echo hi".utf8) + [Self.cr] + [Self.cr]))
    }

    // MARK: - What a prepended `export` statement does to the plan

    /// An `.environment` variable is emitted as `export NAME='value'; ` in
    /// front of the body, and the separator is `; ` rather than a line break
    /// precisely so that THIS stays true: a single-line snippet with an
    /// environment variable is still one line, so it takes the single-line
    /// path and is neither bracketed nor refused.
    ///
    /// A line break would have moved every such snippet onto the multi-line
    /// path, where inserting without bracketed paste is refused outright.
    @Test("an environment variable keeps a single-line snippet on the single-line path")
    func aPrependedExportKeepsASingleLineSingle() {
        let resolved = SnippetVariableSubstitution.resolve(
            command: "./backup.sh",
            variables: [SnippetVariable(
                name: "DB", prompt: "DB", kind: .freeText, placement: .environment,
                defaultValue: "", remembersLastValue: false)],
            values: ["DB": "kunden db"])
        #expect(resolved == "export DB='kunden db'; ./backup.sh")
        #expect(
            SnippetSendPlanner.plan(command: resolved, execute: false, bracketedPaste: false)
                == .send(SnippetKeystrokes.bytes(forLine: resolved, execute: false)))
    }

    /// A multi-line body keeps every property it had: it is still multi-line
    /// after the statement is prepended, so bracketed paste still brackets
    /// it verbatim, and inserting it without bracketed paste is still
    /// refused. The one visible change is that the first line now carries
    /// the assignment ahead of the body's first command.
    @Test("a multi-line body keeps its plan, with the export on the first line")
    func aPrependedExportLeavesAMultiLineBodyMultiLine() {
        let resolved = SnippetVariableSubstitution.resolve(
            command: "cd /srv\nmake all",
            variables: [SnippetVariable(
                name: "DB", prompt: "DB", kind: .freeText, placement: .environment,
                defaultValue: "", remembersLastValue: false)],
            values: ["DB": "x"])
        #expect(resolved == "export DB='x'; cd /srv\nmake all")
        #expect(
            SnippetSendPlanner.plan(command: resolved, execute: false, bracketedPaste: true)
                == .send(Self.start + Array(resolved.utf8) + Self.end))
        #expect(
            SnippetSendPlanner.plan(command: resolved, execute: false, bracketedPaste: false)
                == .refusedMultilineInsert)
        // The line-by-line fallback sends the assignment and the body's
        // first command as ONE line, which is what keeps them one statement
        // list: a separate Return for the assignment would still export the
        // value, but the shell would echo a second prompt for it.
        #expect(
            SnippetSendPlanner.plan(command: resolved, execute: true, bracketedPaste: false)
                == .send(
                    Array("export DB='x'; cd /srv".utf8) + [Self.cr]
                        + Array("make all".utf8) + [Self.cr]))
    }
}
