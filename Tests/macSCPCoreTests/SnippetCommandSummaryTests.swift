import Testing
@testable import macSCPCore

@Suite("SnippetCommandSummary")
struct SnippetCommandSummaryTests {
    @Test("a single-line command is returned unchanged with no follow-up count")
    func singleLineIsUnchanged() {
        let summary = SnippetCommandSummary.firstLine(of: "docker ps -a")
        #expect(summary.text == "docker ps -a")
        #expect(summary.moreLines == 0)
    }

    @Test("a two-line command reports its first line and one follower")
    func twoLinesReportOneFollower() {
        let summary = SnippetCommandSummary.firstLine(of: "cd /srv\nmake all")
        #expect(summary.text == "cd /srv")
        #expect(summary.moreLines == 1)
    }

    /// `"\r\n"` is ONE `Character` in Swift — a split written against "\n"
    /// alone would see one line here, not two.
    @Test("CRLF separates lines like any other break")
    func crlfSeparatesLines() {
        let summary = SnippetCommandSummary.firstLine(of: "a\r\nb\r\nc")
        #expect(summary.text == "a")
        #expect(summary.moreLines == 2)
    }

    @Test("a trailing newline counts the empty line it creates")
    func trailingNewlineCounts() {
        let summary = SnippetCommandSummary.firstLine(of: "echo hi\n")
        #expect(summary.text == "echo hi")
        #expect(summary.moreLines == 1)
    }
}
