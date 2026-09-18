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
        let raw = try String(contentsOf: path(relative), encoding: .utf8)
        return (try SwiftSource.blankingCommentsAndStrings(raw), try SwiftSource.blankingComments(raw))
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
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
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
            guard Array(characters[index..<(index + needleCharacters.count)]) == needleCharacters
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
            (".forwardingFailed", Self.tunnelManagerFile),
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
        #expect(notify.contains("ErrorNotificationPlan.isNewTransferFailure("))
        #expect(notify.contains("failureCountExcludingConnectionLoss"))
        #expect(notify.contains("totalFailureCount") == false)
        #expect(notify.contains("windowIsKey: notificationWindowIsKey"))
        let key = try Self.body(of: "var notificationWindowIsKey: Bool", in: content)
        #expect(key.filter { !$0.isWhitespace } == "window?.isKeyWindow??false")
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
        // Positive beside the file-wide negatives above: the center really
        // is used here, and nowhere else in this file.
        #expect(Self.count("UNUserNotificationCenter.current()", in: code)
            == Self.count("UNUserNotificationCenter.current()", in: post))
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
