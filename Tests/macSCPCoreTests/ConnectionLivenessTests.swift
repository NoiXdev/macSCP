import Testing
@testable import macSCPCore

@Suite("ConnectionLiveness")
struct ConnectionLivenessTests {
    @Test func theProbeTimeoutIsHalfTheIntervalCappedAtTen() {
        #expect(LivenessProbePolicy.probeTimeout(forInterval: 60) == 10)
        #expect(LivenessProbePolicy.probeTimeout(forInterval: 20) == 10)
        #expect(LivenessProbePolicy.probeTimeout(forInterval: 12) == 6)
        // Never zero, never longer than the interval: a probe that outlives its
        // own tick would overlap the next one.
        #expect(LivenessProbePolicy.probeTimeout(forInterval: 1) == 1)
    }

    @Test func aBusyQueueProvesLivenessBetterThanAProbe() {
        #expect(LivenessProbePolicy.decide(queueIsBusy: true, consecutiveFailures: 0) == .skip)
    }

    @Test func theFirstFailureDegradesAndRetriesTheSecondGivesUp() {
        #expect(LivenessProbePolicy.decide(queueIsBusy: false, consecutiveFailures: 0) == .probe)
        #expect(LivenessProbePolicy.decide(queueIsBusy: false, consecutiveFailures: 1) == .probeAgainNow)
        #expect(LivenessProbePolicy.decide(queueIsBusy: false, consecutiveFailures: 2) == .giveUp)
    }

    @Test func theBackoffDoublesFromFiveAndStopsAtSixty() {
        #expect(ReconnectBackoff.delay(forAttempt: 1) == 5)
        #expect(ReconnectBackoff.delay(forAttempt: 2) == 10)
        #expect(ReconnectBackoff.delay(forAttempt: 3) == 20)
        #expect(ReconnectBackoff.delay(forAttempt: 4) == 40)
        #expect(ReconnectBackoff.delay(forAttempt: 5) == 60)
        #expect(ReconnectBackoff.delay(forAttempt: 99) == 60)
    }
}
