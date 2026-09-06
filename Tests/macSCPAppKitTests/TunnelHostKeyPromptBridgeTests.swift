import Foundation
import MacSCPTestSupport
import Testing

@testable import MacSCPAppKit
@testable import macSCPCore

/// The window's host-key bridge for forwardings: what happens when two
/// questions arrive at once, and what happens after the window is gone
/// (port-forwarding plan, Task 6, fix round 1).
///
/// Both properties were absent in round 1. A single continuation meant the
/// SECOND question of a "Start all" refused the first to make room for
/// itself — one prompt on screen, one profile in `.needsConfirmation` for no
/// visible reason. And a bridge nobody watches any more (the window closed,
/// the runner kept the decider across its reconnects) parked the dial
/// forever, which `TunnelRunner.stop()` then waits for, which the quit then
/// waits for.
///
/// Nothing here dials: a `HostKeyCandidate` is a value, and the bridge is
/// the whole system under test.
@Suite("Tunnel host-key prompt bridge", .timeLimit(.minutes(1)))
@MainActor
struct TunnelHostKeyPromptBridgeTests {

    /// Two distinguishable candidates. The base64 is empty in both — no key
    /// material anywhere in this suite — so they differ by host alone.
    private static func candidate(_ host: String) -> HostKeyCandidate {
        HostKeyCandidate(host: host, port: 22, keyType: "ssh-ed25519", publicKeyBase64: "")
    }

    /// Collects each asker's answer as it arrives.
    @MainActor
    private final class Answers {
        private(set) var byHost: [String: Bool] = [:]
        func record(_ host: String, _ answer: Bool) { byHost[host] = answer }
    }

    // MARK: - Two questions at once

    /// The head is on screen, the other waits, and each answer reaches its
    /// own asker.
    @Test func questionsQueueAndEachAnswerReachesItsOwnAsker() async throws {
        let bridge = TunnelHostKeyPromptBridge()
        let answers = Answers()

        let first = Task { @MainActor in
            answers.record("first", await bridge.ask(Self.candidate("first")))
        }
        try await pollUntil("the first question is on screen") {
            bridge.currentCandidate?.host == "first"
        }
        let second = Task { @MainActor in
            answers.record("second", await bridge.ask(Self.candidate("second")))
        }
        try await pollUntil("the second question is queued") { bridge.pendingCount == 2 }

        // The second question must NOT have taken the screen, and must not
        // have been answered to make room for itself — the round-1 defect.
        #expect(bridge.currentCandidate?.host == "first")
        #expect(answers.byHost["first"] == nil, "the first question was answered by the second one")

        bridge.resolve(trust: true)
        await first.value
        #expect(answers.byHost["first"] == true)
        try await pollUntil("the second question takes the screen") {
            bridge.currentCandidate?.host == "second" && bridge.pendingCount == 1
        }

        bridge.resolve(trust: false)
        await second.value
        #expect(answers.byHost["second"] == false)
        #expect(bridge.currentCandidate == nil)
        #expect(bridge.pendingCount == 0)
    }

    /// A cancelled asker takes its OWN question out of the queue and leaves
    /// the one on screen alone — identity, not position.
    @Test func aCancelledAskerDoesNotConsumeTheAnswerOnScreen() async throws {
        let bridge = TunnelHostKeyPromptBridge()
        let answers = Answers()

        let first = Task { @MainActor in
            answers.record("first", await bridge.ask(Self.candidate("first")))
        }
        try await pollUntil("the first question is on screen") {
            bridge.currentCandidate?.host == "first"
        }
        let second = Task { @MainActor in
            answers.record("second", await bridge.ask(Self.candidate("second")))
        }
        try await pollUntil("the second question is queued") { bridge.pendingCount == 2 }

        second.cancel()
        await second.value
        #expect(answers.byHost["second"] == false, "a cancelled dial must be refused, not left")
        try await pollUntil("the cancelled question left the queue") { bridge.pendingCount == 1 }
        #expect(bridge.currentCandidate?.host == "first", "the cancelled asker took the screen")

        bridge.resolve(trust: true)
        await first.value
        #expect(answers.byHost["first"] == true)
    }

    // MARK: - After the window is gone

    @Test func invalidateRefusesWhatIsPendingAndWhatComesLater() async throws {
        let bridge = TunnelHostKeyPromptBridge()
        let answers = Answers()

        let pending = Task { @MainActor in
            answers.record("pending", await bridge.ask(Self.candidate("pending")))
        }
        try await pollUntil("the question is on screen") { bridge.currentCandidate != nil }

        bridge.invalidate()
        await pending.value

        #expect(answers.byHost["pending"] == false, "a closed bridge left a dial waiting")
        #expect(bridge.currentCandidate == nil)
        #expect(bridge.pendingCount == 0)
        #expect(bridge.isInvalidated)

        // The half that matters for the quit: a question raised by a
        // reconnect AFTER the window closed is refused at once rather than
        // parked on a continuation no sheet is watching.
        let later = await bridge.ask(Self.candidate("later"))
        #expect(later == false)
        #expect(bridge.pendingCount == 0)
    }
}
