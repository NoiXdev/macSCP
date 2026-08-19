import Testing
@testable import macSCPCore

/// The one place a value becomes a single shell word.
///
/// Single quotes are used rather than double, because inside single quotes a
/// POSIX shell expands nothing at all — no `$`, no backtick, no backslash.
/// The only character that cannot appear literally is `'` itself, which is
/// why it is closed, escaped and reopened.
@Suite("PosixQuoting")
struct PosixQuotingTests {
    @Test("a plain value is wrapped in single quotes")
    func plainValue() {
        #expect(PosixQuoting.singleQuoted("backup") == "'backup'")
    }

    @Test("a value with a space stays one word")
    func valueWithSpace() {
        #expect(PosixQuoting.singleQuoted("kunden db") == "'kunden db'")
    }

    @Test("an embedded single quote is closed, escaped and reopened")
    func embeddedQuote() {
        #expect(PosixQuoting.singleQuoted("it's") == #"'it'\''s'"#)
    }

    /// The characters that would otherwise let a value become code.
    @Test("expansion characters are inert inside the quotes")
    func expansionCharacters() {
        #expect(PosixQuoting.singleQuoted("$HOME") == "'$HOME'")
        #expect(PosixQuoting.singleQuoted("`id`") == "'`id`'")
        #expect(PosixQuoting.singleQuoted("a\\b") == "'a\\b'")
    }

    /// The case this whole primitive exists for.
    @Test("a value that tries to end the word and start a command cannot")
    func injectionAttempt() {
        #expect(PosixQuoting.singleQuoted("x; rm -rf /") == "'x; rm -rf /'")
    }

    @Test("an empty value is an explicit empty word, not nothing")
    func emptyValue() {
        #expect(PosixQuoting.singleQuoted("") == "''")
    }
}
