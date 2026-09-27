import Foundation
import MacSCPTestSupport
import Testing

/// Guards the notification wiring (next build of 2026-09-17, Task 7) where
/// `ErrorNotificationTests` cannot reach: what text can reach a notification
/// at all, which hooks call the notifier, the live poster's order of checks,
/// and the Settings toggle.
///
/// Structural claims read the source with comments AND string literals
/// blanked (`SwiftSource.blankingCommentsAndStrings`); catalogue-key claims
/// read the comments-only view. Every negative check has a positive check
/// beside it naming the thing it scans.
///
/// Known blind spot: SOURCE TEXT only. That a notification appears on
/// screen, and that macOS asks for permission once, is a sight check.
@Suite("Error notification wiring guard")
struct ErrorNotificationWiringGuardTests {
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let appSources = "Sources/MacSCPAppKit"
    private static let notificationsFile = "Sources/MacSCPAppKit/ErrorNotifications.swift"
    private static let lifecycleFile = "Sources/MacSCPAppKit/ContentView+Lifecycle.swift"
    private static let detailFile = "Sources/MacSCPAppKit/ContentView+Detail.swift"
    private static let tunnelManagerFile = "Sources/MacSCPAppKit/TunnelManager.swift"
    private static let settingsViewFile = "Sources/MacSCPAppKit/SettingsView.swift"
    private static let appFile = "Sources/MacSCPAppKit/MacSCPApp.swift"
    private static let contentViewFile = "Sources/MacSCPAppKit/ContentView.swift"

    private static let keys = [
        "notifications.connectionLost.title",
        "notifications.transferFailed.title",
        "notifications.forwardingFailed.title",
        "notifications.body.unsavedConnection",
        "settings.general.notifications",
        "settings.general.notifications.footer",
    ]

    /// Identifiers that name something other than a session's or a
    /// forwarding's name. None of them may appear in the arguments of a call
    /// to the notifier.
    private static let forbiddenInArguments = [
        "host", "Host", "path", "Path", "reason", "Reason", "message", "Message",
        "error", "Error", "password", "Password", "secret", "Secret", "titleName",
        "displaySummary", "displayTitle", "description", "fileName", "kind",
    ]

    private static func path(_ relative: String) -> URL {
        repoRoot.appendingPathComponent(relative)
    }

    private static func views(_ relative: String) throws -> (code: String, withLiterals: String) {
        return (try SourceCorpus.code(of: path(relative)), try SourceCorpus.commentFree(of: path(relative)))
    }

    private static func body(of declaration: String, in source: String) throws -> String {
        try TransferQueueBarCancelGuardTests.declarationBody(of: declaration, in: source)
    }

    private static func count(_ needle: String, in source: String) -> Int {
        TransferQueueBarCancelGuardTests.occurrenceCount(of: needle, in: source)
    }

    /// Every App source file, blanked, by its path relative to the repo.
    private static func allAppCode() throws -> [(file: String, code: String)] {
        let directory = path(appSources)
        let names = try SourceCorpus.children(of: directory).map(\.lastPathComponent)
            .filter { $0.hasSuffix(".swift") }
            .sorted()
        return try names.map { name in
            let relative = "\(appSources)/\(name)"
            return (relative, try views(relative).code)
        }
    }

    /// The argument text of every call `needle(...)` in `source`, from just
    /// after the opening parenthesis to its balancing close.
    private static func callArguments(_ needle: String, in source: String) -> [String] {
        let characters = Array(source)
        let needleCharacters = Array(needle)
        var result: [String] = []
        var index = 0
        while index + needleCharacters.count <= characters.count {
            guard needleCharacters.isEmpty || characters[index] == needleCharacters[0],
                characters[index..<(index + needleCharacters.count)].elementsEqual(needleCharacters)
            else {
                index += 1
                continue
            }
            var depth = 1
            var cursor = index + needleCharacters.count
            let start = cursor
            while cursor < characters.count, depth > 0 {
                if characters[cursor] == "(" { depth += 1 }
                if characters[cursor] == ")" { depth -= 1 }
                cursor += 1
            }
            result.append(String(characters[start..<max(start, cursor - 1)]))
            index = cursor
        }
        return result
    }

    /// Like `callArguments(_:in:)`, for a call to a TYPE named `name`: only
    /// where the name is not the tail of a longer identifier or a member
    /// access (`LostConnectionView(` is not a call to `View(`).
    private static func typeCallArguments(_ name: String, in source: String) -> [String] {
        let needle = name + "("
        var result: [String] = []
        var searchStart = source.startIndex
        while let found = source.range(of: needle, range: searchStart..<source.endIndex) {
            searchStart = found.upperBound
            if found.lowerBound > source.startIndex {
                let before = source[source.index(before: found.lowerBound)]
                if before.isLetter || before.isNumber || before == "_" || before == "." { continue }
            }
            let tail = String(source[found.lowerBound...])
            if let arguments = callArguments(needle, in: tail).first { result.append(arguments) }
        }
        return result
    }

    /// Runs of whitespace (newlines included) as one space, trimmed — so a
    /// call wrapped over several lines reads like one written on one.
    private static func collapsingWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func catalog(_ locale: String) throws -> [String: String] {
        let relative = "Sources/MacSCPAppKit/Resources/\(locale).lproj/Localizable.strings"
        let data = try Data(contentsOf: path(relative))
        return try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
    }

    // MARK: - What text can reach a notification

    /// The one call that hands text to the system is the notifier's, and it
    /// hands over exactly the plan's title and body.
    @Test func theOnlyPostCallPassesThePlansText() throws {
        var calls: [(file: String, arguments: String)] = []
        for (file, code) in try Self.allAppCode() {
            for arguments in Self.callArguments(".post(title:", in: code) {
                calls.append((file, arguments))
            }
        }
        #expect(calls.count == 1, "expected one .post(title: call, found \(calls.map(\.file))")
        let call = try #require(calls.first)
        #expect(call.file == Self.notificationsFile)
        #expect(call.arguments.filter { !$0.isWhitespace } == "text.title,body:text.body")

        let notify = try Self.body(
            of: "func notify(", in: Self.views(Self.notificationsFile).code)
        #expect(notify.contains("let text = ErrorNotificationPlan.text(for: event, name: name)"))
        #expect(notify.contains("ErrorNotificationPlan.shouldPost("))
    }

    /// The plan's text is a catalogue title plus the name: every title comes
    /// from an `L10n.string("notifications.…")` entry, the body is `name`
    /// itself or the catalogue's unsaved-connection sentence, and nothing is
    /// formatted, concatenated or interpolated into either.
    @Test func thePlansTextIsACatalogueTitlePlusTheName() throws {
        let views = try Self.views(Self.notificationsFile)
        let declaration = "static func text(for event: ErrorNotificationEvent, name: String?)"
        // The result type's own name is not a mention of an error.
        let code = try Self.body(of: declaration, in: views.code)
            .replacingOccurrences(of: "ErrorNotificationText(", with: "")
        let range = try TransferQueueBarCancelGuardTests.declarationBodyRange(
            of: declaration, in: views.code)
        let literals = TransferQueueBarCancelGuardTests.slice(range, of: views.withLiterals)

        // Positive: the parts are there.
        #expect(code.contains("titleKey"))
        #expect(code.contains("name"))
        #expect(literals.contains("L10n.string(\"notifications.body.unsavedConnection\""))
        let titleKeys = try Self.body(
            of: "var titleKey: (key: String, fallback: String)", in: views.withLiterals)
        for event in ["connectionLost", "transferFailed", "forwardingFailed"] {
            #expect(titleKeys.contains("\"notifications.\(event).title\""))
        }
        #expect(code.contains("L10n.string("))

        // Negative, beside the positives above: nothing else is mixed in.
        for forbidden in ["String(format:", "+", "\\(", "joined", "append"] {
            #expect(literals.contains(forbidden) == false, "text(for:name:) contains \(forbidden)")
        }
        for forbidden in Self.forbiddenInArguments {
            #expect(code.contains(forbidden) == false, "text(for:name:) mentions \(forbidden)")
        }
    }

    /// Exactly three calls to the notifier, one per event, and each passes a
    /// name and nothing that names a host, a path, a reason or a secret.
    @Test func everyNotifyCallPassesAnEventAndANameOnly() throws {
        var calls: [(file: String, arguments: String)] = []
        for (file, code) in try Self.allAppCode() {
            for arguments in Self.callArguments(".notify(", in: code) {
                calls.append((file, Self.collapsingWhitespace(arguments)))
            }
        }
        // Positive: the three hooks are there, each where it belongs.
        #expect(calls.count == 3, "found notify calls in \(calls.map(\.file))")
        let events = [
            (".connectionLost", Self.lifecycleFile),
            (".transferFailed", "Sources/MacSCPAppKit/ContentView.swift"),
            (".forwardingFailed", Self.appFile),
        ]
        for (event, file) in events {
            let matching = calls.filter { $0.arguments.hasPrefix(event + ",") }
            #expect(matching.count == 1, "expected one notify(\(event), …)")
            #expect(matching.first?.file == file)
        }
        for call in calls {
            #expect(call.arguments.contains("name:"))
            #expect(call.arguments.contains("enabled:"))
            #expect(call.arguments.contains("windowIsKey:"))
            // The gate is the setting as read, never a literal: the text
            // between `enabled:` and `, windowIsKey:` ends in the property.
            let afterEnabled = call.arguments.components(separatedBy: "enabled:").last ?? ""
            let enabled = (afterEnabled.components(separatedBy: ", windowIsKey:").first ?? "")
                .trimmingCharacters(in: .whitespaces)
            #expect(
                enabled.hasSuffix(".notificationsEnabled"),
                "\(call.file): notify(…) gates on `\(enabled)`, not the setting")
            // Negative, beside the positives above.
            for forbidden in Self.forbiddenInArguments {
                #expect(
                    call.arguments.contains(forbidden) == false,
                    "\(call.file): notify(\(call.arguments)) mentions \(forbidden)")
            }
        }
        // The two session events take their name from the stored session.
        for call in calls where !call.arguments.hasPrefix(".forwardingFailed,") {
            #expect(call.arguments.contains("name: notificationName(forStoredSession:"))
        }
    }

    /// The forwarding name the manager hands its hook is a profile's name.
    @Test func theForwardingHookIsHandedAProfileName() throws {
        let code = try Self.views(Self.tunnelManagerFile).code
        let calls = Self.callArguments("notifyForwardingFailed(", in: code)
            .filter { !$0.contains(":") }   // the call, not the declarations
        #expect(calls.count == 1)
        let call = try #require(calls.first)
        #expect(call.contains(".name"))
        for forbidden in Self.forbiddenInArguments {
            #expect(call.contains(forbidden) == false, "notifyForwardingFailed(\(call)) mentions \(forbidden)")
        }
        let mirror = try Self.body(
            of: "private func runner(for profile: TunnelProfile) -> any TunnelRunning", in: code)
        #expect(mirror.contains("ErrorNotificationPlan.entersFailure(from:"))
        #expect(mirror.contains("notifyForwardingFailed("))
    }

    // MARK: - Hooks

    /// The lost-connection notification is posted by the function that
    /// opens a lost episode, and not by the mirror that re-enters `.lost`
    /// after a failed reconnect (a repeat of the same episode).
    @Test func theLostNotificationComesFromTheGiveUpAndNotFromTheMirror() throws {
        let lifecycle = try Self.views(Self.lifecycleFile).code
        let giveUp = try Self.body(
            of: "func handleLivenessGiveUp(_ tab: SessionTab) async", in: lifecycle)
        #expect(Self.collapsingWhitespace(giveUp).contains("errorNotifier.notify( .connectionLost,"))
        let lostWrite = try #require(giveUp.range(of: "tab.liveness = .lost"))
        let notify = try #require(giveUp.range(of: "errorNotifier.notify("))
        #expect(lostWrite.lowerBound < notify.lowerBound)
        #expect(giveUp.contains("windowIsKey: notificationWindowIsKey"))

        let detail = try Self.views(Self.detailFile).code
        let mirror = try Self.body(of: "struct ConnectAttemptLivenessMirror: View", in: detail)
        // Positive: this is the mirror that writes `.lost` again.
        #expect(mirror.contains("tab.liveness = .lost"))
        // Negative.
        #expect(mirror.contains("notify(") == false)
        #expect(mirror.contains("errorNotifier") == false)
    }

    /// The transfer hook is driven by the queue's failure count, the one
    /// that leaves a drop's sweep out.
    @Test func theTransferHookObservesTheCountThatExcludesADrop() throws {
        let lifecycle = try Self.views(Self.lifecycleFile).code
        let observer = try Self.body(of: ".onChange(of: transferFailureCounts)", in: lifecycle)
        #expect(observer.contains("notifyTransferFailures()"))

        let content = try Self.views("Sources/MacSCPAppKit/ContentView.swift").code
        let counts = try Self.body(of: "var transferFailureCounts: [Int]", in: content)
        #expect(counts.contains("failureCountExcludingConnectionLoss"))
        #expect(counts.contains("totalFailureCount") == false)
        let notify = try Self.body(of: "func notifyTransferFailures()", in: content)
        #expect(notify.contains("tab.transferFailureLatch.takeFailures("))
        #expect(notify.contains("tab.transferFailureLatch.notificationPosted()"))
        #expect(notify.contains("failureCountExcludingConnectionLoss"))
        #expect(notify.contains("totalFailureCount") == false)
        #expect(notify.contains("windowIsKey: notificationWindowIsKey"))
        let key = try Self.body(of: "var notificationWindowIsKey: Bool", in: content)
        #expect(key.filter { !$0.isWhitespace } == "window?.isKeyWindow??false")

        // The latch is released when this window becomes key, and only then
        // (fix round 1: the user has seen the window).
        let release = try Self.body(of: "func transferNotificationWindowBecameKey()", in: content)
        #expect(release.contains("tab.transferFailureLatch.windowBecameKey()"))
        let keyObserver = try Self.body(
            of: ".onChange(of: controlActiveState, initial: true)", in: lifecycle)
        #expect(Self.collapsingWhitespace(keyObserver)
            .contains("if controlActiveState == .key { transferNotificationWindowBecameKey() }"))
        let releaseCalls = try Self.allAppCode()
            .map { Self.count("transferNotificationWindowBecameKey()", in: $0.code) }
            .reduce(0, +)
        #expect(releaseCalls == 2)   // the declaration and that one call
    }

    /// The notification rule's `isKeyWindow` read lives in `ContentView.swift`,
    /// which `TabsWindowLifecycleTests.nothingReAsksWhichWindowIsKey` does not
    /// scan — that guard keeps key-window reads out of the files that route
    /// menus. So this one pins the read from the other side: exactly one
    /// `isKeyWindow` in the whole App target, inside
    /// `notificationWindowIsKey`, and that property read only by the two
    /// window-owned notify calls. A second read anywhere — a menu route
    /// coming back through this file — changes the count.
    @Test func theOnlyKeyWindowReadIsTheNotificationRules() throws {
        let files = try Self.allAppCode()
        let keyReads = files.map { Self.count("isKeyWindow", in: $0.code) }.reduce(0, +)
        let propertyUses = files.map { Self.count("notificationWindowIsKey", in: $0.code) }
            .reduce(0, +)
        #expect(keyReads == 1)
        // The declaration and the two arguments `windowIsKey: notificationWindowIsKey`.
        #expect(propertyUses == 3)
        let uses = files.map {
            Self.count("windowIsKey: notificationWindowIsKey", in: $0.code)
        }.reduce(0, +)
        #expect(uses == 2)

        let content = try Self.views("Sources/MacSCPAppKit/ContentView.swift").code
        let key = try Self.body(of: "var notificationWindowIsKey: Bool", in: content)
        #expect(Self.count("isKeyWindow", in: key) == 1)
    }

    // MARK: - The live poster

    /// `UNUserNotificationCenter` is touched only inside the live poster's
    /// `post`, after the bundle check, and authorization is asked there —
    /// at the first post, not at launch.
    @Test func theLivePosterChecksTheBundleBeforeTouchingTheCenter() throws {
        for (file, code) in try Self.allAppCode() where file != Self.notificationsFile {
            #expect(code.contains("UNUserNotificationCenter") == false, "\(file)")
            #expect(code.contains("requestAuthorization") == false, "\(file)")
        }
        let code = try Self.views(Self.notificationsFile).code
        let post = try Self.body(
            of: "final class UserNotificationCenterPoster", in: code)
        let bundleCheck = try #require(
            post.range(of: "guard Bundle.main.bundleIdentifier != nil else { return }"))
        let firstCenter = try #require(post.range(of: "UNUserNotificationCenter"))
        #expect(bundleCheck.lowerBound < firstCenter.lowerBound)
        #expect(post.contains("requestAuthorization("))

        // Fix round 1: the foreground presenter is installed after the
        // bundle check and before authorization is asked, and it is kept —
        // the center holds its delegate weakly.
        let delegateSet = try #require(post.range(of: ".delegate = "))
        let authorization = try #require(post.range(of: "requestAuthorization("))
        #expect(bundleCheck.lowerBound < delegateSet.lowerBound)
        #expect(delegateSet.lowerBound < authorization.lowerBound)
        #expect(post.contains("private var presenter: ForegroundNotificationPresenter?"))
        #expect(Self.count(".delegate = ", in: code) == 1)
        let presenter = try Self.body(
            of: "final class ForegroundNotificationPresenter", in: code)
        #expect(presenter.contains("willPresent notification: UNNotification"))
        #expect(presenter.contains("completionHandler(Self.presentationOptions)"))
        // Positive beside the file-wide negatives above: the center really
        // is used here, and nowhere else in this file.
        #expect(Self.count("UNUserNotificationCenter.current()", in: code)
            == Self.count("UNUserNotificationCenter.current()", in: post))
    }

    /// Every post goes through the gate, and the one place that adds a
    /// request to the center is reached only from the gate's two answers —
    /// the immediate `.deliver` and the held texts the answer hands back
    /// (deferred minor of 2026-09-17, cleared 2026-09-27).
    @Test func theLivePosterRoutesEveryPostThroughTheAuthorizationGate() throws {
        let code = try Self.views(Self.notificationsFile).code
        let poster = try Self.body(of: "final class UserNotificationCenterPoster", in: code)
        // Positives: the gate is held, asked, and read back.
        #expect(poster.contains("private var gate = ErrorNotificationPlan.FirstAuthorizationGate()"))
        #expect(Self.count("gate.take(", in: poster) == 1)
        #expect(Self.count("gate.answered()", in: poster) == 1)
        // The add happens in exactly one place in the whole file, and that
        // place is the helper both answers call.
        #expect(Self.count(".add(request, withCompletionHandler: nil)", in: code) == 1)
        let deliver = try Self.body(
            of: "private func deliver(title: String, body: String)", in: code)
        #expect(deliver.contains(".add(request, withCompletionHandler: nil)"))
        // Negative beside them: `post` does not reach the center's add
        // itself, so nothing bypasses the gate. Read out of the class body,
        // not the file — the protocol declares this same signature.
        let post = try Self.body(of: "func post(title: String, body: String)", in: poster)
        #expect(post.contains("gate.take("), "scanning the wrong body")
        #expect(post.contains(".add(request") == false)
        // The gate is asked BEFORE anything is delivered, and `post` hands
        // over exactly once: a `deliver` call added ahead of the switch —
        // which is precisely the behaviour this replaced — would satisfy a
        // bare `contains` and was measured green against one.
        let asked = try #require(post.range(of: "gate.take("))
        let handedOver = try #require(post.range(of: "deliver(title: title, body: body)"))
        #expect(asked.upperBound < handedOver.lowerBound)
        #expect(Self.count("deliver(title:", in: post) == 1)
        // The held texts are handed back in the order the gate returns
        // them; nothing re-sorts or reverses them.
        let answered = try Self.body(of: "private func authorizationAnswered()", in: code)
        #expect(answered.contains("for text in gate.answered()"))
        #expect(answered.contains("deliver(title: text.title, body: text.body)"))
        for forbidden in [".reversed()", ".sorted", ".last", ".first"] {
            #expect(answered.contains(forbidden) == false, "\(forbidden)")
        }
    }

    // MARK: - Who holds the live notifier

    /// The live poster is built in `MacSCPApp` and nowhere else, and it
    /// reaches the windows and the forwardings only by being handed in: a
    /// `ContentView` or a `TunnelManager` built without one is silent, so
    /// no test reaches `UNUserNotificationCenter` by omission (fix round 1).
    @Test func theLiveNotifierIsBuiltAndInjectedOnlyInMacSCPApp() throws {
        let files = try Self.allAppCode()
        let app = try Self.views(Self.appFile).code

        // Positive: the one construction is in `MacSCPApp`.
        #expect(Self.count("UserNotificationCenterPoster(", in: app) == 1)
        // Negative, beside it: nowhere else.
        for (file, code) in files where file != Self.appFile {
            #expect(Self.count("UserNotificationCenterPoster(", in: code) == 0, "\(file)")
        }

        // Every `ContentView(` in the App target hands a notifier in.
        var windows: [(file: String, arguments: String)] = []
        for (file, code) in files {
            for arguments in Self.typeCallArguments("ContentView", in: code) {
                windows.append((file, Self.collapsingWhitespace(arguments)))
            }
        }
        #expect(windows.count == 1, "ContentView( in \(windows.map(\.file))")
        for window in windows {
            #expect(window.file == Self.appFile)
            #expect(window.arguments.contains("errorNotifier: errorNotifier"))
        }

        // The forwarding hook is installed from `MacSCPApp`, once, and the
        // manager's own `shared` builds none.
        let installs = files.map {
            Self.count("TunnelManager.shared.notifyForwardingFailed = ", in: $0.code)
        }.reduce(0, +)
        #expect(installs == 1)
        #expect(Self.count("TunnelManager.shared.notifyForwardingFailed = ", in: app) == 1)
        let manager = try Self.views(Self.tunnelManagerFile).code
        let shared = try #require(Self.typeCallArguments("TunnelManager", in: manager).first)
        #expect(shared.contains("makeRunner:"))
        #expect(shared.contains("notifyForwardingFailed") == false)
        #expect(shared.contains("ErrorNotifier") == false)

        // A window's default is the silent notifier.
        let content = try Self.views(Self.contentViewFile).code
        #expect(content.contains("self.errorNotifier = errorNotifier ?? ErrorNotifier.silent()"))
    }

    // MARK: - Settings

    @Test func theGeneralSettingsBindTheToggle() throws {
        let views = try Self.views(Self.settingsViewFile)
        let general = try Self.body(
            of: "private struct GeneralSettingsSection: View", in: views.withLiterals)
        #expect(general.contains("$store.notificationsEnabled"))
        #expect(general.contains("\"settings.general.notifications\""))
        #expect(general.contains("\"settings.general.notifications.footer\""))
    }

    @Test func everyKeyIsInAllFourCatalogues() throws {
        for locale in ["en", "de", "fr", "pl"] {
            let catalog = try Self.catalog(locale)
            for key in Self.keys {
                #expect(catalog[key]?.isEmpty == false, "\(locale): \(key)")
            }
        }
        let german = try Self.catalog("de")["settings.general.notifications.footer"] ?? ""
        #expect(german.contains(" du "))
    }
}
