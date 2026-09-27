import AppKit
import macSCPCore
import UserNotifications

/// The seam between deciding to notify and asking macOS to show it (next
/// build of 2026-09-17, Task 7). The live implementation is
/// `UserNotificationCenterPoster`; tests hand `ErrorNotifier` a recorder.
@MainActor
protocol UserNotificationPosting: AnyObject {
    func post(title: String, body: String)
}

/// The three things this app notifies about (maintainer decision,
/// 2026-09-16: a lost connection, a failed transfer, a failed forwarding).
enum ErrorNotificationEvent: CaseIterable {
    case connectionLost
    case transferFailed
    case forwardingFailed

    /// The catalogue entry the notification's title is read from.
    var titleKey: (key: String, fallback: String) {
        switch self {
        case .connectionLost:
            return ("notifications.connectionLost.title", "Connection lost")
        case .transferFailed:
            return ("notifications.transferFailed.title", "Transfer failed")
        case .forwardingFailed:
            return ("notifications.forwardingFailed.title", "Port forwarding failed")
        }
    }
}

struct ErrorNotificationText: Equatable {
    let title: String
    let body: String
}

/// Every decision about a notification, as plain functions: whether to post
/// at all, whether an event is a repeat, and what the text says. The hooks
/// ask; `ErrorNotifier` posts; nothing here touches AppKit or the
/// notification center, so all of it is a table in `ErrorNotificationTests`.
enum ErrorNotificationPlan {
    /// Whether a notification is worth posting.
    ///
    /// Never with the setting off. Otherwise only when the user is not
    /// already looking at what happened, decided from what AppKit exposes:
    /// `NSApplication.isActive` (the app is frontmost) and, for an event
    /// that belongs to a window, that window's `isKeyWindow`. A lost
    /// connection or a failed transfer in a background window of the
    /// frontmost app still posts.
    ///
    /// `windowIsKey == nil` is an event no window owns — a forwarding, which
    /// belongs to the app-wide `TunnelManager`. It posts only while the app
    /// is not frontmost: in front, the forwarding's state is on the app's
    /// own surfaces (the sidebar glyph, the Dock badge).
    static func shouldPost(enabled: Bool, appIsActive: Bool, windowIsKey: Bool?) -> Bool {
        guard enabled else { return false }
        guard appIsActive else { return true }
        guard let windowIsKey else { return false }
        return !windowIsKey
    }

    /// Whether a forwarding's state change is the transition INTO `.failed`.
    /// A failure followed by another failure — of the same kind or another —
    /// is the same event still going on, and does not notify again; leaving
    /// `.failed` (a restart, a reconnect) and failing afterwards is a new one.
    static func entersFailure(from previous: TunnelState?, to next: TunnelState) -> Bool {
        guard case .failed = next else { return false }
        if case .failed? = previous { return false }
        return true
    }

    /// One tab's "transfer failed" state (fix round 1, the maintainer's
    /// ruling): **at most one notification per tab until that tab's window
    /// next becomes key.** A folder transfer's items fail across many
    /// updates, and a count-only watermark posted once per update that saw
    /// a higher count — a burst of banners for one folder.
    ///
    /// Lives on the tab (`SessionTab.transferFailureLatch`), so it travels
    /// with a tab that moves to another window.
    struct TransferFailureLatch: Equatable {
        /// The queue's `failureCountExcludingConnectionLoss` this tab has
        /// answered for. Only grows.
        private(set) var answeredThrough = 0
        /// A notification was posted and the window has not been key since.
        private(set) var isHeld = false

        /// Takes the queue's current failure count, and says whether to ask
        /// the notifier: there are failures not answered for yet, and no
        /// notification is still unseen. The failures are answered for
        /// either way, so a release never replays them.
        mutating func takeFailures(count: Int) -> Bool {
            let isNew = count > answeredThrough
            answeredThrough = max(answeredThrough, count)
            return isNew && !isHeld
        }

        /// The notifier did post: hold until the window becomes key. A check
        /// that did not post (the setting off, the window key) holds
        /// nothing — nobody was told anything.
        mutating func notificationPosted() {
            isHeld = true
        }

        /// The tab's window became key: the user has seen it.
        mutating func windowBecameKey() {
            isHeld = false
        }
    }

    /// What a post does while the app's very first authorization request is
    /// still unanswered (deferred minor of 2026-09-17, cleared 2026-09-27).
    ///
    /// Before this, only the FIRST post of a launch waited for the answer;
    /// every post after it was handed to the notification center straight
    /// away, while the system's permission alert was still on screen — and
    /// macOS drops what is not allowed yet, so such a post was never shown
    /// and never came back. The window is not hypothetical: one dropped
    /// connection can raise both a "transfer failed" and a "connection
    /// lost" notification (`ContentView.notifyTransferFailures` says why
    /// that pair is deliberate), so the first drop after a fresh install is
    /// exactly the case that loses one of the two.
    ///
    /// So a post made before the answer is HELD and delivered once the
    /// answer arrives, oldest first. Whether macOS then shows it stays
    /// macOS's decision: a denial drops a held post exactly as it drops
    /// every later one, which is why whether authorization was GRANTED is
    /// not a question this gate asks.
    ///
    /// Plain values, no framework: `ErrorNotificationTests` drives it as a
    /// table, which is the only way this decision can be tested at all —
    /// `UserNotificationCenterPoster` itself needs an app bundle to run.
    struct FirstAuthorizationGate: Equatable {
        /// What the caller must do with the text it just handed over.
        enum Outcome: Equatable {
            /// Ask macOS for authorization now. The text is held; the
            /// answer hands it back.
            case requestAuthorization
            /// Held until the answer arrives.
            case held
            /// The answer is in: post it now.
            case deliver
            /// Not held: `heldLimit` texts are already waiting.
            case dropped
        }

        /// How many posts one unanswered request holds. Small on purpose —
        /// the alert is answered in seconds, and a longer burst behind it
        /// says something else is wrong. The OLDEST are kept, because the
        /// event that opened the episode is the one worth telling the user
        /// about.
        static let heldLimit = 8

        private enum State: Equatable {
            case notAsked
            case pending
            case answered
        }

        private var state: State = .notAsked
        /// Waiting for the answer, oldest first. Empty once it arrives.
        private(set) var held: [ErrorNotificationText] = []

        mutating func take(_ text: ErrorNotificationText) -> Outcome {
            switch state {
            case .answered:
                return .deliver
            case .notAsked:
                state = .pending
                held.append(text)
                return .requestAuthorization
            case .pending:
                guard held.count < Self.heldLimit else { return .dropped }
                held.append(text)
                return .held
            }
        }

        /// The request was answered. Returns everything held, oldest first,
        /// and holds nothing afterwards — every later post is `.deliver`.
        mutating func answered() -> [ErrorNotificationText] {
            state = .answered
            defer { held.removeAll() }
            return held
        }
    }

    /// The notification's text: the event's catalogue title, and a body
    /// that is the session's or the forwarding's NAME and nothing else — no
    /// host, no path, no reason sentence, no secret. A connection that is
    /// not a stored session has no name, and its body is the catalogue's
    /// "unsaved connection" entry rather than the tab's own title, which
    /// for such a tab spells the user and the host.
    static func text(for event: ErrorNotificationEvent, name: String?) -> ErrorNotificationText {
        let title = L10n.string(event.titleKey.key, event.titleKey.fallback)
        guard let name, !name.isEmpty else {
            return ErrorNotificationText(
                title: title,
                body: L10n.string("notifications.body.unsavedConnection", "Unsaved connection"))
        }
        return ErrorNotificationText(title: title, body: name)
    }
}

/// Asks the plan and posts what it says. It holds no connection, tab or
/// window state (a tab's latch lives on the tab, a forwarding's previous
/// state in `TunnelManager`), only the poster and the way to read whether
/// the app is frontmost.
///
/// **The live one is built once, in `MacSCPApp`, and handed in** — to
/// every window's `ContentView` and to `TunnelManager.shared` (fix round
/// 1). Anything built without one gets `silent()`, so no test reaches
/// `UNUserNotificationCenter` by leaving an argument out.
@MainActor
final class ErrorNotifier {
    /// A notifier that decides as the live one does and shows nothing.
    static func silent() -> ErrorNotifier {
        ErrorNotifier(poster: SilentNotificationPoster(), appIsActive: { false })
    }

    let poster: any UserNotificationPosting
    private let appIsActive: @MainActor () -> Bool

    init(poster: any UserNotificationPosting, appIsActive: @escaping @MainActor () -> Bool) {
        self.poster = poster
        self.appIsActive = appIsActive
    }

    /// `enabled` is the "Notifications" setting as the caller's own store
    /// reads it; `windowIsKey` is the owning window's `isKeyWindow`, or
    /// `nil` for an event no window owns.
    ///
    /// Returns whether it posted, which is what a tab's
    /// `TransferFailureLatch` holds on.
    @discardableResult
    func notify(
        _ event: ErrorNotificationEvent, name: String?, enabled: Bool, windowIsKey: Bool?
    ) -> Bool {
        guard ErrorNotificationPlan.shouldPost(
            enabled: enabled, appIsActive: appIsActive(), windowIsKey: windowIsKey)
        else { return false }
        let text = ErrorNotificationPlan.text(for: event, name: name)
        poster.post(title: text.title, body: text.body)
        return true
    }
}

/// Posts nothing. `ErrorNotifier.silent()`'s poster.
@MainActor
final class SilentNotificationPoster: UserNotificationPosting {
    func post(title: String, body: String) {}
}

/// Everything `UserNotificationCenterPoster` does to the world outside
/// itself, behind one seam (fix round 1 of 2026-09-27).
///
/// **Why it exists.** The poster's SEQUENCING is the part of it that has
/// had bugs in it, and until this round that sequencing was held only by
/// scanning the poster's own source — because the poster could not be
/// built in a test without reaching `UNUserNotificationCenter`. Three
/// violations were planted that the scan bought and printed a pass for:
/// the gate consulted and its answer discarded, a second gate shadowing
/// the stored one so every held post vanished, and an authorization
/// completion that never drained the hold. A fourth anchor would have
/// bought the next spelling too. This is the boundary instead: with the
/// seam handed in, all three are ordinary red tests
/// (`ErrorNotificationTests`, "The live poster's sequence").
///
/// Not an abstraction — a seam. `LiveNotificationCenterOperations` is the
/// only production conformance, every member of it is a single statement,
/// and no decision lives here: whether to post is
/// `ErrorNotificationPlan.shouldPost`'s, what to do with a post before the
/// answer is `FirstAuthorizationGate`'s.
@MainActor
protocol NotificationCenterOperations: AnyObject {
    /// Whether this process has an app bundle at all. See
    /// `LiveNotificationCenterOperations` for why nothing may be touched
    /// without one.
    var hasBundleIdentifier: Bool { get }
    /// Install the delegate that lets a notification show while this app is
    /// frontmost. Idempotent: the poster calls it on every post.
    func installForegroundPresenter()
    /// Ask macOS for authorization. `completion` runs on the main actor
    /// once the user has answered, whatever the answer was.
    func requestAuthorization(completion: @escaping @MainActor () -> Void)
    /// Hand one notification to the center.
    func add(title: String, body: String)
    /// A post the gate could not hold was discarded. Leaves a trace, so a
    /// discarded post is not indistinguishable from one never made.
    func reportDiscardedWhileWaiting()
}

/// The live `NotificationCenterOperations` over `UNUserNotificationCenter`.
/// Thin on purpose: every decision is `ErrorNotificationPlan`'s, and every
/// member below is one statement of framework work.
///
/// **No bundle, no notification.** An unbundled build (`swift run`) has a
/// `Bundle.main` with no bundle identifier, and
/// `UNUserNotificationCenter.current()` is not safe to call there: the
/// arm64e dyld shared cache of this Mac carries the format string
/// "bundleProxyForCurrentProcess is nil: mainBundle.bundleURL %@", which is
/// the exception text reported outside this project for that call in a
/// process without an app bundle. That is what was read (2026-09-17); which
/// framework raises it was not traced, and the call was not run unbundled
/// to watch it. So the identifier is checked before the center is touched
/// at all.
///
/// The `swift test` process is one of those, measured 2026-09-18 with a
/// throwaway test: its `Bundle.main` is SwiftPM's `swiftpm-testing-helper`,
/// with a nil identifier, and `NSApp` is nil. No test relies on that since
/// fix round 1: a `ContentView` or `TunnelManager` built without a notifier
/// is silent, and only `MacSCPApp` builds this poster. `swift run` itself
/// was not measured.
///
/// **Authorization is asked at the first post, not at launch.** The first
/// post requests it; every post made before the answer arrives is held and
/// delivered once it does, oldest first
/// (`ErrorNotificationPlan.FirstAuthorizationGate`, which carries the
/// reasoning and is where that decision is tested). Once the answer is in,
/// a post is added directly, and macOS drops it while the user has not
/// allowed them.
@MainActor
final class LiveNotificationCenterOperations: NotificationCenterOperations {
    /// Kept here because the center holds its delegate weakly.
    private var presenter: ForegroundNotificationPresenter?

    var hasBundleIdentifier: Bool { Bundle.main.bundleIdentifier != nil }

    /// Fix round 1 of 2026-09-18: without a delegate answering
    /// `willPresent`, macOS shows nothing while this app is frontmost — and
    /// the plan posts for a background window of the frontmost app.
    func installForegroundPresenter() {
        guard presenter == nil else { return }
        let installed = ForegroundNotificationPresenter()
        presenter = installed
        UNUserNotificationCenter.current().delegate = installed
    }

    /// `@Sendable` spelled out: the answer arrives on a queue of the
    /// framework's, and without it Swift could infer this closure
    /// main-actor isolated from the class and trap there. A `@Sendable`
    /// closure is accepted whether or not the SDK imports the parameter as
    /// `@Sendable`. The answer itself is not read: a denial drops a held
    /// post the same way it drops every later one, and the gate's doc
    /// comment says why.
    func requestAuthorization(completion: @escaping @MainActor () -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) {
            @Sendable _, _ in
            Task { @MainActor in completion() }
        }
    }

    func add(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    /// The fact and nothing else: no title, no body, no session name. The
    /// body of a notification is a stored session's NAME, which is the
    /// user's own text, and this line exists to say that the hold
    /// overflowed — not what was in it.
    func reportDiscardedWhileWaiting() {
        DiagnosticLog.shared.log(
            .info, "app",
            "notification discarded: the first authorization request is still unanswered")
    }
}

/// The live poster. It owns the gate and the ORDER of the four steps —
/// bundle check, presenter, gate, hand-over — and nothing else; every step
/// itself is `NotificationCenterOperations`'. That split is what makes the
/// order testable at all (see that protocol's doc comment for the three
/// planted violations that were invisible before it).
///
/// `operations` is undefaulted on purpose: `MacSCPApp` is the one place
/// that names `LiveNotificationCenterOperations`, so nothing can reach
/// `UNUserNotificationCenter` by leaving an argument out.
@MainActor
final class UserNotificationCenterPoster: UserNotificationPosting {
    private var gate = ErrorNotificationPlan.FirstAuthorizationGate()
    private let operations: any NotificationCenterOperations

    init(operations: any NotificationCenterOperations) {
        self.operations = operations
    }

    func post(title: String, body: String) {
        guard operations.hasBundleIdentifier else { return }
        // Before authorization is asked, and on every post because it is
        // idempotent.
        operations.installForegroundPresenter()
        switch gate.take(ErrorNotificationText(title: title, body: body)) {
        case .deliver:
            operations.add(title: title, body: body)
        case .held:
            return
        case .dropped:
            operations.reportDiscardedWhileWaiting()
        case .requestAuthorization:
            operations.requestAuthorization { [weak self] in
                self?.authorizationAnswered()
            }
        }
    }

    /// The permission alert has been answered: everything the gate held
    /// goes to the center now, in the order it was posted.
    private func authorizationAnswered() {
        for text in gate.answered() {
            operations.add(title: text.title, body: text.body)
        }
    }
}

/// Answers macOS's question "this app is frontmost — show its notification
/// anyway?" with a banner and a place in Notification Centre. Whether to
/// post at all is `ErrorNotificationPlan.shouldPost`'s decision, made
/// before anything reaches the center; this only keeps macOS from muting
/// what was decided (fix round 1).
///
/// Not main-actor isolated: the protocol carries no isolation in the SDK
/// headers, and the framework calls it on a queue of its own. It holds no
/// state. The completion handler is declared WITHOUT `@Sendable` on
/// purpose — measured 2026-09-18 with a scratch `swiftc -swift-version 6`
/// (6.4): a plain witness satisfies an `@objc optional` requirement whose
/// handler is `@Sendable`, while a `@Sendable` witness for a plain
/// requirement is an error. The plain spelling fits either import.
/// `ErrorNotificationTests.thePresenterShowsBannersWhileTheAppIsFrontmost`
/// asks the runtime whether it answers the selector.
final class ForegroundNotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    static let presentationOptions: UNNotificationPresentationOptions = [.banner, .list]

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler(Self.presentationOptions)
    }
}
