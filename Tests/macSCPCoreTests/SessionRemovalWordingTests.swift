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
        #expect(
            SessionRemovalWording.question(sessionName: "web", forwardings: 3)
                == "Delete session web and 3 forwardings?")
        #expect(
            SessionRemovalWording.question(sessionName: "web", forwardings: 0)
                == "Delete session web and 0 forwardings?")
        #expect(
            SessionRemovalWording.summary(sessionName: "web", forwardings: 2)
                == "Deleted web and 2 forwardings; keychain entry left in place.")
    }

    /// A count that could not be read is not "0", and neither text promises
    /// to delete forwardings that an unreadable file keeps: `sessions rm`
    /// warns past that file and leaves them in it.
    @Test func anUnreadableCountIsUnknownAndNothingPromisesToDeleteThem() {
        #expect(
            SessionRemovalWording.question(sessionName: "web", forwardings: nil)
                == "Delete session web? Its forwardings could not be read "
                + "and will be left in the forwarding list.")
        #expect(
            SessionRemovalWording.summary(sessionName: "web", forwardings: nil)
                == "Deleted web; the number of its forwardings is unknown "
                + "(the forwarding list could not be read); keychain entry left in place.")
    }
}
