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
///
/// **Every wait is a `pollUntil`, never `await task.value`.** A `Task<Void,
/// Never>`'s `value` ignores its awaiter's cancellation, so a bridge that
/// failed to resume an asker would HANG this suite rather than fail it — the
/// suite's `.timeLimit` could not end it. Measured while probing this round:
/// planting an `invalidate()` that forgets to resume made the first version
/// of these tests hang until the probe was killed by hand, with no verdict
/// at all. Polling for the recorded answer is cancellable, so the same plant
/// is red instead.
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

        // Discarded handles: an unstructured task runs whether or not
        // anyone holds it, and nothing here waits on one — see the suite's
        // header for why `await task.value` is not a wait this project can
        // afford.
        _ = Task { @MainActor in
            answers.record("first", await bridge.ask(Self.candidate("first")))
        }
        try await pollUntil("the first question is on screen") {
            bridge.currentCandidate?.host == "first"
        }
        _ = Task { @MainActor in
            answers.record("second", await bridge.ask(Self.candidate("second")))
        }
        try await pollUntil("the second question is queued") { bridge.pendingCount == 2 }

        // The second question must NOT have taken the screen, and must not
        // have been answered to make room for itself — the round-1 defect.
        #expect(bridge.currentCandidate?.host == "first")
        #expect(answers.byHost["first"] == nil, "the first question was answered by the second one")

        bridge.resolve(trust: true)
        try await pollUntil("the first asker was resumed") { answers.byHost["first"] != nil }
        #expect(answers.byHost["first"] == true)
        try await pollUntil("the second question takes the screen") {
            bridge.currentCandidate?.host == "second" && bridge.pendingCount == 1
        }

        bridge.resolve(trust: false)
        try await pollUntil("the second asker was resumed") { answers.byHost["second"] != nil }
        #expect(answers.byHost["second"] == false)
        #expect(bridge.currentCandidate == nil)
        #expect(bridge.pendingCount == 0)
    }

    /// A cancelled asker takes its OWN question out of the queue and leaves
    /// the one on screen alone — identity, not position.
    @Test func aCancelledAskerDoesNotConsumeTheAnswerOnScreen() async throws {
        let bridge = TunnelHostKeyPromptBridge()
        let answers = Answers()

        _ = Task { @MainActor in
            answers.record("first", await bridge.ask(Self.candidate("first")))
        }
        try await pollUntil("the first question is on screen") {
            bridge.currentCandidate?.host == "first"
        }
        // The one handle this suite keeps: this test cancels it.
        let second = Task { @MainActor in
            answers.record("second", await bridge.ask(Self.candidate("second")))
        }
        try await pollUntil("the second question is queued") { bridge.pendingCount == 2 }

        second.cancel()
        try await pollUntil("the cancelled asker was resumed") { answers.byHost["second"] != nil }
        #expect(answers.byHost["second"] == false, "a cancelled dial must be refused, not left")
        try await pollUntil("the cancelled question left the queue") { bridge.pendingCount == 1 }
        #expect(bridge.currentCandidate?.host == "first", "the cancelled asker took the screen")

        bridge.resolve(trust: true)
        try await pollUntil("the first asker was resumed") { answers.byHost["first"] != nil }
        #expect(answers.byHost["first"] == true)
    }

    // MARK: - The views have to be told

    /// The property the sheets read is OBSERVED — the whole point of the
    /// bridge being `@Observable`.
    ///
    /// This is the round-2 critical, and it is invisible to every other test
    /// here: a computed `currentCandidate` over the `@ObservationIgnored`
    /// queue answers correctly when asked, so the queue tests above stayed
    /// green while no presenter was ever invalidated — the prompt never
    /// appeared and the dial parked. What is measured here is the
    /// notification, not the value.
    @Test func theBridgeNotifiesItsObserverWhenAQuestionArrives() async throws {
        let bridge = TunnelHostKeyPromptBridge()
        let fired = Fired()
        // Exactly what a SwiftUI presenter does: read the property inside a
        // tracked closure, and be told when that read is invalidated.
        withObservationTracking {
            _ = bridge.currentCandidate
        } onChange: {
            Task { @MainActor in fired.record() }
        }

        _ = Task { @MainActor in _ = await bridge.ask(Self.candidate("first")) }

        try await pollUntil("the observer was told a question arrived") { fired.count == 1 }
        #expect(bridge.currentCandidate?.host == "first")
        bridge.invalidate()
    }

    /// Counts the invalidations an observer received.
    @MainActor
    private final class Fired {
        private(set) var count = 0
        func record() { count += 1 }
    }

    // MARK: - After the window is gone

    @Test func invalidateRefusesWhatIsPendingAndWhatComesLater() async throws {
        let bridge = TunnelHostKeyPromptBridge()
        let answers = Answers()

        _ = Task { @MainActor in
            answers.record("pending", await bridge.ask(Self.candidate("pending")))
        }
        try await pollUntil("the question is on screen") { bridge.currentCandidate != nil }

        bridge.invalidate()
        try await pollUntil("the pending asker was resumed") { answers.byHost["pending"] != nil }

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

    /// A window that disappears and comes back can prompt again.
    ///
    /// `onDisappear`/`onAppear` are not "the window closed"/"a new window":
    /// SwiftUI sends the pair for its own reasons, and round 1 closed the
    /// bridge on the first of them and never reopened it — every later
    /// question refused, every hand-started forwarding coming to rest in
    /// `.needsConfirmation` with nothing shown.
    @Test func revalidateLetsTheBridgeAskAgain() async throws {
        let bridge = TunnelHostKeyPromptBridge()
        let answers = Answers()

        bridge.invalidate()
        #expect(await bridge.ask(Self.candidate("while closed")) == false)

        bridge.revalidate()
        #expect(bridge.isInvalidated == false)

        _ = Task { @MainActor in
            answers.record("reopened", await bridge.ask(Self.candidate("reopened")))
        }
        try await pollUntil("the reopened bridge takes a question") {
            bridge.currentCandidate?.host == "reopened"
        }
        bridge.resolve(trust: true)
        try await pollUntil("the asker was resumed") { answers.byHost["reopened"] != nil }
        #expect(answers.byHost["reopened"] == true)
    }
}
