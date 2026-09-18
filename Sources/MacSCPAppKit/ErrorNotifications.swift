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

    /// Whether a tab's transfer queue has failures nobody has been notified
    /// about yet. `failureCount` is the queue's
    /// `failureCountExcludingConnectionLoss`, which only grows;
    /// `notifiedThrough` is the tab's own watermark
    /// (`SessionTab.notifiedTransferFailureCount`), which travels with the
    /// tab when it moves to another window. Several failures seen at once
    /// are one notification.
    static func isNewTransferFailure(failureCount: Int, notifiedThrough: Int) -> Bool {
        failureCount > notifiedThrough
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

/// Asks the plan and posts what it says. One per process: it holds no
/// connection, tab or window state (a tab's watermark lives on the tab, a
/// forwarding's previous state in `TunnelManager`), only the poster and the
/// way to read whether the app is frontmost.
@MainActor
final class ErrorNotifier {
    static let shared = ErrorNotifier(
        poster: UserNotificationCenterPoster(),
        appIsActive: { NSApp?.isActive ?? false })

    private let poster: any UserNotificationPosting
    private let appIsActive: @MainActor () -> Bool

    init(poster: any UserNotificationPosting, appIsActive: @escaping @MainActor () -> Bool) {
        self.poster = poster
        self.appIsActive = appIsActive
    }

    /// `enabled` is the "Notifications" setting as the caller's own store
    /// reads it; `windowIsKey` is the owning window's `isKeyWindow`, or
    /// `nil` for an event no window owns.
    func notify(_ event: ErrorNotificationEvent, name: String?, enabled: Bool, windowIsKey: Bool?) {
        guard ErrorNotificationPlan.shouldPost(
            enabled: enabled, appIsActive: appIsActive(), windowIsKey: windowIsKey)
        else { return }
        let text = ErrorNotificationPlan.text(for: event, name: name)
        poster.post(title: text.title, body: text.body)
    }
}

/// The live poster over `UNUserNotificationCenter`. Thin on purpose: every
/// decision is `ErrorNotificationPlan`'s.
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
/// with a nil identifier, and `NSApp` is nil. The existing tests that drive
/// a give-up on a `ContentView` built without a notifier reach this poster
/// through `ErrorNotifier.shared` and stop at this check. `swift run` itself
/// was not measured.
///
/// **Authorization is asked at the first post, not at launch.** The first
/// post requests it and delivers once it is granted; later posts are added
/// directly, and macOS drops them while the user has not allowed them. A
/// post made while the first request is still unanswered is added before
/// the answer, and is not shown if the answer is still pending.
@MainActor
final class UserNotificationCenterPoster: UserNotificationPosting {
    private var hasRequestedAuthorization = false

    func post(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let deliver: @Sendable () -> Void = {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let request = UNNotificationRequest(
                identifier: UUID().uuidString, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
        }
        guard !hasRequestedAuthorization else {
            deliver()
            return
        }
        hasRequestedAuthorization = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) {
            granted, _ in
            if granted { deliver() }
        }
    }
}
