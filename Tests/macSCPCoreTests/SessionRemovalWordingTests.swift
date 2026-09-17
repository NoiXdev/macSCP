import Foundation
import Testing

@testable import macSCPCore

/// The words `sessions rm` uses for a session's forwardings. The question is
/// asked only on a terminal, which no subprocess test has, so its text is
/// read here; the `--verbose` summary is also read end to end in
/// `CLISessionsEditingTests`.
@Suite("Session removal wording")
struct SessionRemovalWordingTests {

    @Test func aKnownCountIsNamed() {
        #expect(SessionRemovalWording.questionSubject(forwardings: 3) == "3 forwardings")
        #expect(SessionRemovalWording.questionSubject(forwardings: 0) == "0 forwardings")
        #expect(
            SessionRemovalWording.summary(sessionName: "web", forwardings: 2)
                == "Deleted web and 2 forwardings; keychain entry left in place.")
    }

    /// A count that could not be read says so, and says no number at all —
    /// "0" was what the lenient reader made of an unreadable file.
    @Test func anUnreadableCountIsUnknownNotZero() {
        let subject = SessionRemovalWording.questionSubject(forwardings: nil)
        #expect(subject.contains("unknown"), "\(subject)")
        #expect(subject.contains("could not be read"), "\(subject)")
        let subjectHasDigits = subject.contains { $0.isNumber }
        #expect(subjectHasDigits == false, "\(subject)")

        let summary = SessionRemovalWording.summary(sessionName: "web", forwardings: nil)
        #expect(summary.contains("unknown"), "\(summary)")
        #expect(summary.hasPrefix("Deleted web;"), "\(summary)")
        let summaryHasDigits = summary.contains { $0.isNumber }
        #expect(summaryHasDigits == false, "\(summary)")
        // It does not claim the forwardings were deleted: over an unreadable
        // file they were not.
        #expect(!summary.contains("and"), "\(summary)")
        #expect(summary.hasSuffix("keychain entry left in place."), "\(summary)")
    }
}
