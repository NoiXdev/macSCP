import Foundation
import Testing
@testable import MacSCPAppKit
@testable import macSCPCore

/// The four plain decisions the lost-connection surface and its unattended
/// retry are built from (connection-liveness plan, Task 7). Nothing in this
/// project renders SwiftUI, so each of these was deliberately written as a
/// function over values rather than left inline in a view body — this suite
/// is what that buys.
///
/// Four guards on this branch were previously defeated by mutations that
/// kept the spelling and changed the behaviour (a label instead of a
/// threaded value, presence instead of placement, placement instead of
/// coverage, and a call satisfied by a comment). The answer here is the
/// same one Task 4/5/6 settled on: put the decidable thing in a value, test
/// the value, and let a separate source-scanning guard
/// (`ReconnectWiringGuardTests`) pin that the views still ASK it.
@Suite("Reconnect plan")
struct ReconnectPlanTests {
    private func lost(
        _ reason: LostConnectionReason = .probeGaveUp, attempts: Int = 0,
        target: UUID? = UUID()
    ) -> LostConnection {
        LostConnection(reason: reason, storedSessionID: target, automaticAttempts: attempts)
    }

    // MARK: - ReconnectPlan: is an attempt due, and when

    /// The default. Nothing happens without a click — the design spec's own
    /// reasoning: reconnecting re-authenticates, and a changed host key is
    /// a hard stop that needs a person.
    @Test func offerOnlyNeverSchedulesAnything() {
        #expect(
            ReconnectPlan.step(
                liveness: .lost, lost: lost(), targetIsKnown: true, behaviour: .offerOnly)
                == .stop)
    }

    @Test func onceThenAskSchedulesTheFirstAttemptAndThenStops() {
        #expect(
            ReconnectPlan.step(
                liveness: .lost, lost: lost(attempts: 0), targetIsKnown: true,
                behaviour: .onceThenAsk)
                == .wait(seconds: 5))
        #expect(
            ReconnectPlan.step(
                liveness: .lost, lost: lost(attempts: 1), targetIsKnown: true,
                behaviour: .onceThenAsk)
                == .stop)
    }

    /// The spacing is Core's `ReconnectBackoff.delay(forAttempt:)` — 5
    /// seconds, doubling, capped at 60, no give-up limit — and this suite
    /// checks that this plan actually paces itself by the attempt count
    /// rather than re-deriving a schedule of its own. `ConnectionLivenessTests`
    /// owns the sequence itself.
    @Test(arguments: [(0, 5), (1, 10), (2, 20), (3, 40), (4, 60), (40, 60)])
    func automaticWaitsTheBackoffForTheNextAttempt(attempts: Int, expected: Int) {
        #expect(
            ReconnectPlan.step(
                liveness: .lost, lost: lost(attempts: attempts), targetIsKnown: true,
                behaviour: .automatic)
                == .wait(seconds: expected))
    }

    @Test func automaticNeverGivesUpOnItsOwn() {
        #expect(
            ReconnectPlan.step(
                liveness: .lost, lost: lost(attempts: 5000), targetIsKnown: true,
                behaviour: .automatic)
                != .stop)
    }

    /// The design spec's explicit exception, and the one this task's brief
    /// calls out separately: an attempt that ran into a host-key decision
    /// or a key passphrase ends in the error view and is NOT repeated in
    /// the background — under `.automatic` just as much as under the other
    /// two behaviours.
    @Test(arguments: ReconnectBehaviour.allCases)
    func anAttemptThatNeedsAPersonIsNeverRepeatedUnattended(behaviour: ReconnectBehaviour) {
        #expect(
            ReconnectPlan.step(
                liveness: .lost, lost: lost(.needsPerson), targetIsKnown: true,
                behaviour: behaviour)
                == .stop)
    }

    /// The same episode with any other reason IS scheduled under
    /// `.automatic` — without this, the test above would pass just as well
    /// against a plan that never schedules anything at all.
    @Test(arguments: [LostConnectionReason.probeGaveUp, .reconnectFailed])
    func everyOtherReasonIsStillScheduledUnderAutomatic(reason: LostConnectionReason) {
        #expect(
            ReconnectPlan.step(
                liveness: .lost, lost: lost(reason), targetIsKnown: true, behaviour: .automatic)
                == .wait(seconds: 5))
    }

    /// An ad-hoc connection, or one whose stored session was deleted while
    /// its tab sat on this surface: there is nothing to redial, so nothing
    /// is scheduled.
    @Test func nothingIsScheduledWithoutARedialTarget() {
        #expect(
            ReconnectPlan.step(
                liveness: .lost, lost: lost(target: nil), targetIsKnown: false,
                behaviour: .automatic)
                == .stop)
    }

    /// The tab has to actually be on the lost surface. A tab mid-attempt,
    /// reconnected, or back at the form must not have a second attempt
    /// fired underneath it — `.connecting` in particular is the case that
    /// would otherwise start a second dial while the first is still open.
    @Test(arguments: [
        Optional<ConnectionLiveness>.none, .connecting, .connected, .degraded,
    ])
    func nothingIsScheduledWhileTheTabIsNotLost(liveness: ConnectionLiveness?) {
        #expect(
            ReconnectPlan.step(
                liveness: liveness, lost: lost(), targetIsKnown: true, behaviour: .automatic)
                == .stop)
    }

    @Test func nothingIsScheduledWithoutALostEpisodeAtAll() {
        #expect(
            ReconnectPlan.step(
                liveness: .lost, lost: nil, targetIsKnown: true, behaviour: .automatic)
                == .stop)
    }

    // MARK: - LostConnectionPlan: what the surface says

    /// The rule the design spec states for this surface (§10) and the
    /// task's own binding constraint: no secret, and no value the user
    /// typed. Checked structurally rather than by reading the strings —
    /// every message the plan can produce, across every input combination,
    /// must come from the fixed set of catalog keys enumerated here. A
    /// future edit that interpolated a host name, a server message, or a
    /// form field into any of them would have to invent a key that is not
    /// in this set, or change one of these strings, and either fails here.
    ///
    /// Eleven keys, counted while writing this sentence, and — since round
    /// 2 moved the two button labels into `LostConnectionContent` — this
    /// really is everything the surface renders, not everything that
    /// happened to live in the content type. `ReconnectWiringGuardTests`
    /// pins that the view is the only site that renders that content and
    /// the plan the only site that builds it, so there is no second place
    /// a string could be introduced.
    @Test func everyReachableMessageComesFromTheFixedCatalogKeySet() {
        let allowedKeys: Set<String> = [
            "connection.lost.title",
            "connection.lost.body.probe",
            "connection.lost.body.retryFailed",
            "connection.lost.body.needsPerson",
            "connection.lost.hint.noSavedSession",
            "connection.lost.hint.stopped",
            "connection.lost.hint.automatic",
            "connection.lost.hint.onceUpcoming",
            "connection.lost.hint.onceDone",
            "connection.lost.reconnect",
            "connection.lost.dismiss",
        ]
        var seen: Set<String> = []
        for reason in [LostConnectionReason.probeGaveUp, .reconnectFailed, .needsPerson] {
            for targetIsKnown in [true, false] {
                for behaviour in ReconnectBehaviour.allCases {
                    for attempts in [0, 1, 7] {
                        let content = LostConnectionPlan.content(
                            reason: reason, targetIsKnown: targetIsKnown,
                            behaviour: behaviour, attempts: attempts)
                        let messages = [content.title, content.body, content.dismissButton]
                            + [content.hint, content.reconnectButton].compactMap { $0 }
                        for message in messages {
                            #expect(allowedKeys.contains(message.key), """
                                `\(message.key)` is not one of the keys this surface is allowed \
                                to show. Every string on the lost-connection surface must be a \
                                fixed catalog entry — see the design spec's §10 rule.
                                """)
                            #expect(!message.fallback.isEmpty)
                            seen.insert(message.key)
                        }
                    }
                }
            }
        }
        #expect(seen == allowedKeys, """
            the enumerated key set and the keys actually reachable from \
            `LostConnectionPlan.content` have diverged: only \(seen.sorted()) were produced.
            """)
    }

    @Test(arguments: [
        (LostConnectionReason.probeGaveUp, "connection.lost.body.probe"),
        (.reconnectFailed, "connection.lost.body.retryFailed"),
        (.needsPerson, "connection.lost.body.needsPerson"),
    ])
    func eachReasonHasItsOwnBody(reason: LostConnectionReason, key: String) {
        let content = LostConnectionPlan.content(
            reason: reason, targetIsKnown: true, behaviour: .offerOnly, attempts: 0)
        #expect(content.body.key == key)
        #expect(content.title.key == "connection.lost.title")
    }

    @Test func reconnectIsOfferedOnlyWhenThereIsSomethingToRedial() {
        let stored = LostConnectionPlan.content(
            reason: .probeGaveUp, targetIsKnown: true, behaviour: .offerOnly, attempts: 0)
        #expect(stored.reconnectButton?.key == "connection.lost.reconnect")
        let adHoc = LostConnectionPlan.content(
            reason: .probeGaveUp, targetIsKnown: false, behaviour: .offerOnly, attempts: 0)
        #expect(adHoc.reconnectButton == nil)
        #expect(adHoc.hint?.key == "connection.lost.hint.noSavedSession")
        // Always a way off this surface, redial or not.
        #expect(stored.dismissButton.key == "connection.lost.dismiss")
        #expect(adHoc.dismissButton.key == "connection.lost.dismiss")
    }

    /// The surface must not promise something the policy does not do. Under
    /// `.automatic` it says macSCP keeps trying — except for the one reason
    /// where `ReconnectPlan.step` answers `.stop`, where it says the
    /// opposite.
    @Test func theHintAgreesWithWhatThePolicyActuallyDoes() {
        #expect(
            LostConnectionPlan.content(
                reason: .probeGaveUp, targetIsKnown: true, behaviour: .automatic, attempts: 0)
                .hint?.key == "connection.lost.hint.automatic")
        #expect(
            LostConnectionPlan.content(
                reason: .needsPerson, targetIsKnown: true, behaviour: .automatic, attempts: 0)
                .hint?.key == "connection.lost.hint.stopped")
        #expect(
            LostConnectionPlan.content(
                reason: .probeGaveUp, targetIsKnown: true, behaviour: .offerOnly, attempts: 0)
                .hint == nil)
    }

    /// `.onceThenAsk` waits the same first backoff as `.automatic` before
    /// its one attempt — a deliberate decision, since the instant after the
    /// probe gives up is the worst moment in the next minute to retry, and
    /// "once" is about count, not latency. What round 1 got wrong was
    /// leaving that behaviour with NO hint at all, so a user could not tell
    /// that macSCP was about to try by itself. The hint now says so before
    /// the attempt and afterwards, and this test crosses it with what
    /// `ReconnectPlan.step` actually does at the same attempt count.
    @Test func onceThenAskSaysWhatItIsAboutToDoAndWhatItHasDone() {
        let before = LostConnectionPlan.content(
            reason: .probeGaveUp, targetIsKnown: true, behaviour: .onceThenAsk, attempts: 0)
        #expect(before.hint?.key == "connection.lost.hint.onceUpcoming")
        #expect(
            ReconnectPlan.step(
                liveness: .lost, lost: lost(attempts: 0), targetIsKnown: true,
                behaviour: .onceThenAsk)
                != .stop,
            "the hint promises an attempt, so the schedule must actually have one due")

        let after = LostConnectionPlan.content(
            reason: .probeGaveUp, targetIsKnown: true, behaviour: .onceThenAsk, attempts: 1)
        #expect(after.hint?.key == "connection.lost.hint.onceDone")
        #expect(
            ReconnectPlan.step(
                liveness: .lost, lost: lost(attempts: 1), targetIsKnown: true,
                behaviour: .onceThenAsk)
                == .stop,
            "the hint says the one attempt has happened, so nothing more may be scheduled")
    }

    // MARK: - ConnectAttemptLivenessPlan: what a state change writes

    @Test func connectingAlwaysPublishesConnecting() {
        for hasSession in [true, false] {
            for describesLost in [true, false] {
                #expect(
                    ConnectAttemptLivenessPlan.write(
                        for: .connecting, hasSession: hasSession,
                        describesLostConnection: describesLost, failureKind: nil)
                        == .connecting)
            }
        }
    }

    /// The case Task 7 added, and the reason this decision moved out of the
    /// view: a failed attempt on a tab that is describing a lost connection
    /// goes BACK to the lost surface. Clearing to `nil` here (the pre-Task-7
    /// behaviour) dropped the user onto the connection form the moment an
    /// unattended retry failed.
    @Test func aFailedAttemptOnALostTabReturnsToTheLostSurface() {
        #expect(
            ConnectAttemptLivenessPlan.write(
                for: .failed(message: "nope", field: nil), hasSession: false,
                describesLostConnection: true, failureKind: .other)
                == .lost(.reconnectFailed))
    }

    /// The verdict comes from Core's own classification of the thrown
    /// error, never from the failure's message or form field — see
    /// `ConnectFailureKind`'s doc comment.
    @Test func aFailedAttemptThatNeedsAPersonSaysSo() {
        #expect(
            ConnectAttemptLivenessPlan.write(
                for: .failed(message: "nope", field: nil), hasSession: false,
                describesLostConnection: true, failureKind: .needsPerson)
                == .lost(.needsPerson))
    }

    /// A failure only a person can resolve — an unknown or changed host
    /// key, a missing passphrase, and every pre-dial refusal, which are
    /// `.needsPerson` by construction — keeps clearing to the form, because
    /// the form is where that question is asked and where its text has
    /// always lived.
    @Test func aFailedAttemptWithNoLostEpisodeClearsTheLiveness() {
        #expect(
            ConnectAttemptLivenessPlan.write(
                for: .failed(message: "nope", field: nil), hasSession: false,
                describesLostConnection: false, failureKind: .needsPerson)
                == .clear)
    }

    /// The case the failed-connect surface plan's Task 3 added: a dial that
    /// reached the wire and failed there, on a tab with no session and no
    /// earlier connection to explain, goes to its OWN surface. Before that
    /// task this answered `.clear`, which means "show the form" — the
    /// maintainer's complaint, being handed the entry mask again as if
    /// nothing had been asked for.
    @Test func aFailedDialWithNoLostEpisodeGoesToTheFailedSurface() {
        #expect(
            ConnectAttemptLivenessPlan.write(
                for: .failed(message: "timed out", field: nil), hasSession: false,
                describesLostConnection: false, failureKind: .other)
                == .failedConnect)
    }

    /// No verdict at all is not a failed dial this surface knows how to
    /// describe, so it falls the same way `.needsPerson` does. Checked
    /// because `.other` is the ONLY value that may open this surface: a
    /// mutation reading the condition as "not `.needsPerson`" passes the
    /// test above and fails here.
    @Test func aFailureWithNoVerdictStillClears() {
        #expect(
            ConnectAttemptLivenessPlan.write(
                for: .failed(message: "nope", field: nil), hasSession: false,
                describesLostConnection: false, failureKind: nil)
                == .clear)
    }

    /// The failed-connect surface never displaces the lost one: a tab that
    /// is describing a dropped connection stays on that surface even when
    /// the attempt that just failed is an ordinary wire failure. Otherwise
    /// the first unattended retry would replace the explanation of the drop
    /// — and the schedule that is still running behind it — with a fresh
    /// "could not connect".
    @Test func aFailedDialOnALostTabStaysWithTheLostSurface() {
        #expect(
            ConnectAttemptLivenessPlan.write(
                for: .failed(message: "timed out", field: nil), hasSession: false,
                describesLostConnection: true, failureKind: .other)
                == .lost(.reconnectFailed))
    }

    /// `.failed` is not exclusively "the dial failed" — `showFailure` is
    /// also how a validation refusal reaches this state — so a CONNECTED
    /// tab's liveness is never touched by it.
    @Test func aFailedStateNeverTouchesAConnectedTab() {
        #expect(
            ConnectAttemptLivenessPlan.write(
                for: .failed(message: "nope", field: nil), hasSession: true,
                describesLostConnection: true, failureKind: .needsPerson)
                == .leaveAlone)
    }

    @Test func idleIsLeftToWhoeverOwnsIt() {
        #expect(
            ConnectAttemptLivenessPlan.write(
                for: .idle, hasSession: false, describesLostConnection: true, failureKind: nil)
                == .leaveAlone)
    }

    // MARK: - TabIndicatorPlan: the dot precedence

    /// The maintainer's decision of 2026-08-21: while a tab reads `.lost`,
    /// the attention dot is suppressed, because the drop is what EXPLAINS
    /// the failed transfer and two red dots seven points apart tell the
    /// same news twice.
    @Test func theAttentionDotIsSuppressedWhileTheConnectionIsLost() {
        #expect(
            TabIndicatorPlan.indicator(
                liveness: .lost, hasConflictPrompt: false, hasUnseenFailures: true,
                queueIsActive: false, isUploading: false)
                == .none)
        #expect(
            TabIndicatorPlan.indicator(
                liveness: .lost, hasConflictPrompt: true, hasUnseenFailures: false,
                queueIsActive: false, isUploading: false)
                == .none)
    }

    /// The other half of the same decision: suppressed, not cleared. Every
    /// other liveness value still shows it, which is what makes "it comes
    /// back once connected again if unseen failures remain" true.
    @Test(arguments: [
        Optional<ConnectionLiveness>.none, .connecting, .connected, .degraded,
    ])
    func everyOtherLivenessStillShowsTheAttentionDot(liveness: ConnectionLiveness?) {
        #expect(
            TabIndicatorPlan.indicator(
                liveness: liveness, hasConflictPrompt: false, hasUnseenFailures: true,
                queueIsActive: false, isUploading: false)
                == .attention)
    }

    @Test func attentionStillWinsOverActivity() {
        #expect(
            TabIndicatorPlan.indicator(
                liveness: .connected, hasConflictPrompt: false, hasUnseenFailures: true,
                queueIsActive: true, isUploading: true)
                == .attention)
    }

    @Test func activityIsUnchangedByThisTask() {
        #expect(
            TabIndicatorPlan.indicator(
                liveness: .connected, hasConflictPrompt: false, hasUnseenFailures: false,
                queueIsActive: true, isUploading: true)
                == .upload)
        #expect(
            TabIndicatorPlan.indicator(
                liveness: .connected, hasConflictPrompt: false, hasUnseenFailures: false,
                queueIsActive: true, isUploading: false)
                == .download)
        #expect(
            TabIndicatorPlan.indicator(
                liveness: .connected, hasConflictPrompt: false, hasUnseenFailures: false,
                queueIsActive: false, isUploading: false)
                == .none)
    }
}
