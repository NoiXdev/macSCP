import Foundation
import MacSCPTestSupport
import Testing

@testable import MacSCPAppKit
@testable import macSCPCore

/// The app re-reads both stores when it becomes active (CLI sessions and
/// tunnels plan, Task 5), so a session or a forwarding profile the CLI wrote
/// into `sessions-v2.json` / `tunnels.json` shows up without a relaunch.
///
/// **Why a source guard rather than a driven test.** The thing being claimed
/// is a wiring: that `NSApplication.didBecomeActiveNotification` is observed
/// in the app's one owner of process-wide lifecycle, and that the observer's
/// body reaches both reloads. Driving it would mean an `NSApplication` that
/// actually activates — a GUI launch — and the two reloads themselves are
/// driven, as ordinary behaviour, in `TunnelManagerTests` (the manager keeps
/// its runners across a reload) and `SessionListViewModelTests` (a session
/// written from outside appears). This suite is the wire between them.
///
/// **The names are derived, not spelled** (CLAUDE.md, "a guard that spells a
/// symbol it could read instead is waiting for a rename"): both reload
/// functions are read out of the types that declare them, and the registry's
/// enumeration out of its own return type. What is spelled here is what this
/// target cannot derive — AppKit's notification name, and the two declaration
/// anchors the spans are cut at.
@Suite("The stores are re-read when the app becomes active")
@MainActor
struct StoreReloadOnActivationGuardTests {

    // MARK: - Where the sources are

    /// `#filePath` here is
    /// `<repoRoot>/Tests/macSCPAppKitTests/StoreReloadOnActivationGuardTests.swift`;
    /// three `deletingLastPathComponent()` calls recover the repo root
    /// regardless of `swift test`'s working directory — the recipe
    /// `QuitSequenceTests` and `TabRegistryNoTeardownGuardTests` use.
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let appFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/MacSCPApp.swift")
    private static let lifecycleFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/ContentView+Lifecycle.swift")
    private static let registryFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/TabRegistry.swift")
    private static let tunnelManagerFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/TunnelManager.swift")
    private static let contentViewFile = repoRoot
        .appendingPathComponent("Sources/MacSCPAppKit/ContentView.swift")
    private static let tunnelStoreFile = repoRoot
        .appendingPathComponent("Sources/macSCPCore/Tunnels/TunnelStore.swift")
    private static let sessionListFile = repoRoot
        .appendingPathComponent("Sources/macSCPCore/Presentation/SessionListViewModel.swift")

    /// The three declaration anchors, each the part of a signature that
    /// cannot wrap: the name and its opening parenthesis.
    private static let observerDeclaration = "private func observeActivation("
    private static let launchDeclaration = "func applicationDidFinishLaunching("
    private static let windowSetupDeclaration = "func performWindowSetup()"
    private static let windowCloseDeclaration =
        "func handleWindowWillClose(_ notification: Notification)"

    enum ScanError: Error, CustomStringConvertible {
        case derivation(String)

        var description: String {
            switch self {
            case .derivation(let message): return message
            }
        }
    }

    /// The strict (comments-and-string-literals-blanked) view of one file —
    /// a guard reading raw source cannot tell a call from a sentence about a
    /// call (CLAUDE.md, "Source-scanning guards read comments too"), and the
    /// files scanned below carry prose naming every needle used here.
    private static func strictSource(of file: URL) throws -> String {
        try SwiftSource.blankingCommentsAndStrings(
            String(contentsOf: file, encoding: .utf8))
    }

    /// Capture group 1 of every match of `pattern` in `text`.
    private static func captures(of pattern: String, in text: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    // MARK: - The names, derived

    /// The name of the zero-argument, nothing-returning, SYNCHRONOUS
    /// function whose name begins with `reload` that `file`'s type declares
    /// — `SessionListViewModel.reload()`.
    ///
    /// Fails closed: a second such function makes the derivation ambiguous
    /// and this throws rather than picking one. Two of `TunnelManager`'s
    /// three `reload…` functions are excluded here and that is deliberate —
    /// `reloadAutoStartProfiles()` by its return type and
    /// `reloadReconciling()` by its `async`, which is the whole reason the
    /// pattern insists on the body brace following the parentheses directly.
    private static func reloadFunctionName(in file: URL) throws -> String {
        let names = Set(
            try captures(of: #"func\s+(reload\w*)\s*\(\s*\)\s*\{"#, in: strictSource(of: file)))
        guard names.count == 1, let only = names.first else {
            throw ScanError.derivation("""
                expected exactly one zero-argument, nothing-returning, synchronous reload \
                function in \(file.lastPathComponent) — found \(names.sorted())
                """)
        }
        return only
    }

    /// The name of the zero-argument, nothing-returning `async` function
    /// whose name begins with `reload` that `file`'s type declares — the
    /// tunnel store's re-read, which awaits a discard for every profile that
    /// disappeared and so cannot be the synchronous one above.
    ///
    /// Fails closed the same way, and the `async` is what tells the two
    /// apart: `reload()` and `reloadReconciling()` both take no argument and
    /// return nothing.
    private static func asyncReloadFunctionName(in file: URL) throws -> String {
        let names = Set(
            try captures(
                of: #"func\s+(reload\w*)\s*\(\s*\)\s*async\s*\{"#,
                in: strictSource(of: file)))
        guard names.count == 1, let only = names.first else {
            throw ScanError.derivation("""
                expected exactly one zero-argument, nothing-returning async reload function \
                in \(file.lastPathComponent) — found \(names.sorted())
                """)
        }
        return only
    }

    /// The registry function that hands back every open window's session
    /// list, derived from its return type.
    private static func sessionListEnumerationName() throws -> String {
        let names = Set(
            try captures(
                of: #"func\s+(\w+)\s*\(\s*\)\s*->\s*\[SessionListViewModel\]"#,
                in: strictSource(of: registryFile)))
        guard names.count == 1, let only = names.first else {
            throw ScanError.derivation("""
                expected exactly one function returning [SessionListViewModel] in \
                \(registryFile.lastPathComponent) — found \(names.sorted())
                """)
        }
        return only
    }

    /// The registry function a window calls to make its session list
    /// reachable, derived from its parameter list.
    private static func sessionListRegistrationName() throws -> String {
        let names = Set(
            try captures(
                of: #"func\s+(\w+)\s*\(\s*_\s+\w+:\s*SessionListViewModel,"#,
                in: strictSource(of: registryFile)))
        guard names.count == 1, let only = names.first else {
            throw ScanError.derivation("""
                expected exactly one function taking a SessionListViewModel in \
                \(registryFile.lastPathComponent) — found \(names.sorted())
                """)
        }
        return only
    }

    // MARK: - The observer

    /// The positive: the app's one owner of process-wide lifecycle observes
    /// activation, and the observer's body reaches BOTH reloads — the
    /// manager's own, and every open window's session list through the
    /// registry the quit chain already enumerates windows with.
    ///
    /// The two reload calls are counted rather than located, because the two
    /// functions are spelled the same: deleting either one turns the count
    /// from two into one.
    @Test func theActivationObserverReReadsBothStores() throws {
        let source = try Self.strictSource(of: Self.appFile)
        let body = try TransferQueueBarCancelGuardTests.declarationBody(
            of: Self.observerDeclaration, in: source)

        #expect(
            body.contains("NSApplication.didBecomeActiveNotification"), """
                the activation observer no longer names didBecomeActiveNotification — a store \
                the CLI wrote would need a relaunch to appear.
                """)

        let tunnelReload = try Self.asyncReloadFunctionName(in: Self.tunnelManagerFile)
        let listReload = try Self.reloadFunctionName(in: Self.sessionListFile)
        let enumeration = try Self.sessionListEnumerationName()

        #expect(
            body.contains("TunnelManager.shared.\(tunnelReload)("),
            "activation no longer re-reads the tunnel store")
        #expect(
            body.contains("TabRegistry.shared.\(enumeration)("), """
                activation no longer asks the registry for the open windows' session lists — \
                either the reload reaches no window, or a second registry has appeared.
                """)

        // Counted per derived name, never as one total (fix round 1). The
        // two names are distinct today, so each call is counted by the name
        // that spells it; a rename of ONE of them used to give a false red
        // against a total of two, and a spelling both share still has to be
        // counted once for both.
        let sharedSpelling = tunnelReload == listReload
        let tunnelCalls = TransferQueueBarCancelGuardTests.occurrenceCount(
            of: "\(tunnelReload)(", in: body)
        #expect(tunnelCalls == (sharedSpelling ? 2 : 1), """
            the activation observer spells "\(tunnelReload)(" \(tunnelCalls) time(s), not \
            \(sharedSpelling ? 2 : 1) — the tunnel store's re-read is missing or doubled.
            """)
        let listCalls = TransferQueueBarCancelGuardTests.occurrenceCount(
            of: "\(listReload)(", in: body)
        #expect(listCalls == (sharedSpelling ? 2 : 1), """
            the activation observer spells "\(listReload)(" \(listCalls) time(s), not \
            \(sharedSpelling ? 2 : 1) — each open window's session list is no longer \
            re-read.
            """)
    }

    /// The observer is installed at launch, from the callback that owns the
    /// rest of this process's lifecycle. Without this, `observeActivation()`
    /// could be a function nobody calls — which reads exactly like a wiring
    /// that is in place.
    @Test func theLaunchInstallsTheActivationObserver() throws {
        let source = try Self.strictSource(of: Self.appFile)
        let launch = try TransferQueueBarCancelGuardTests.declarationBody(
            of: Self.launchDeclaration, in: source)
        #expect(
            launch.contains("observeActivation("),
            "nothing installs the activation observer — the app would never re-read a store")
    }

    /// The other end of the enumeration: a window makes its session list
    /// reachable on the way in and gives it up on the way out, in the two
    /// places its registrations are already bracketed. Without this the
    /// observer above would loop over an empty list and pass.
    @Test func aWindowRegistersItsSessionListAndGivesItUpBeforeItCloses() throws {
        let source = try Self.strictSource(of: Self.lifecycleFile)
        let register = try Self.sessionListRegistrationName()
        // Derived from the registration's own name rather than spelled a
        // second time: the pair is `register…`/`unregister…`, and the
        // registry declares three other `unregister…(for window:)`
        // functions that a pattern over the parameter list could not tell
        // apart from this one.
        let unregister = "un\(register)"

        let setup = try TransferQueueBarCancelGuardTests.declarationBody(
            of: Self.windowSetupDeclaration, in: source)
        #expect(
            setup.contains("TabRegistry.shared.\(register)("), """
                a window no longer registers its session list — the activation reload would \
                reach no window at all.
                """)

        let closing = try TransferQueueBarCancelGuardTests.declarationBody(
            of: Self.windowCloseDeclaration, in: source)
        #expect(
            closing.contains("TabRegistry.shared.\(unregister)("), """
                a closing window no longer gives its session list up — activation would go on \
                reloading a window that is gone.
                """)
    }

    // MARK: - The negative, and the positives beside it

    /// A store read the activation path performs ITSELF, rather than through
    /// the two owners above, is what this forbids: a second `store.all()` or
    /// `allProfiles()` on activation is a second in-memory copy of a file two
    /// processes write, and nothing would keep it in step with the first.
    ///
    /// A negative check that names a spelling nothing uses any more matches
    /// nothing and passes (CLAUDE.md, "Only a NEGATIVE check can go stale in
    /// silence"), so every needle below is pinned PRESENT in the file that
    /// owns it, in the same test.
    @Test func theActivationPathReadsNoStoreOfItsOwn() throws {
        let source = try Self.strictSource(of: Self.appFile)
        let body = try TransferQueueBarCancelGuardTests.declarationBody(
            of: Self.observerDeclaration, in: source)
        #expect(
            body.contains("NSApplication.didBecomeActiveNotification"),
            "the scanned span is not the activation observer's body")

        for (needle, owner) in Self.directStoreReads {
            let readsItself = body.contains(needle)
            #expect(readsItself == false, """
                the activation observer reads \"\(needle)\" itself — the re-read belongs to \
                TunnelManager and to each window's SessionListViewModel, and a third copy of \
                a file two processes write has nobody keeping it in step.
                """)
            let live = try Self.strictSource(of: owner).contains(needle)
            #expect(live, """
                \"\(needle)\" occurs nowhere in \(owner.lastPathComponent) any more, so the \
                check above forbids a spelling this tree no longer writes — it would pass \
                over the real thing.
                """)
        }
    }

    /// The session lists are reloaded BEFORE the tunnel reconcile (fix round
    /// 3, N3), and the order is the claim: the session reloads are
    /// synchronous file reads, while the reconcile can suspend for as long as
    /// a discarded runner's `stop()` takes — `connectTimeoutSeconds`, up to
    /// 120 s. Behind it, the sidebar would show yesterday's sessions for that
    /// whole wait.
    ///
    /// Positional, over the same derived names the count check above uses.
    /// Each is asserted PRESENT first — an ordering claim over a needle that
    /// is not there is no claim at all.
    ///
    /// **The session side is anchored on the RELOAD, not on the enumeration**
    /// (fix round 4). It used to compare the index of
    /// `TabRegistry.shared.allSessionLists(` against the reconcile's, which
    /// is not the claim: a body that enumerates the windows, awaits the
    /// reconcile, and reloads them afterwards puts the enumeration first and
    /// the sidebar still waits out the dial. The needle is the derived
    /// session-list reload name, whose spelling cannot collide with the
    /// tunnel one — `reload(` does not occur inside `reloadReconciling(`,
    /// because a character follows the `reload` there.
    @Test func theActivationReloadsTheSessionListsBeforeItReconcilesTheTunnels() throws {
        let source = try Self.strictSource(of: Self.appFile)
        let body = try TransferQueueBarCancelGuardTests.declarationBody(
            of: Self.observerDeclaration, in: source)
        let tunnelReload = try Self.asyncReloadFunctionName(in: Self.tunnelManagerFile)
        let listReload = try Self.reloadFunctionName(in: Self.sessionListFile)
        let enumeration = try Self.sessionListEnumerationName()

        #expect(
            body.contains("TabRegistry.shared.\(enumeration)("), """
                the activation no longer asks the registry for the open windows' session \
                lists — the reload below reaches no window.
                """)

        let lists = Self.firstIndex(of: "\(listReload)(", in: body)
        let tunnels = Self.firstIndex(of: "TunnelManager.shared.\(tunnelReload)(", in: body)
        #expect(lists != nil, "the activation no longer reloads the windows' session lists")
        #expect(tunnels != nil, "the activation no longer reconciles the tunnel store")
        if let lists, let tunnels {
            #expect(lists < tunnels, """
                the activation awaits the tunnel reconcile before it reloads the session \
                lists — a reconcile parked in a runner's stop would hold the sidebar on \
                stale sessions for the length of a dial timeout.
                """)
        }
    }

    /// The character index of `needle`'s first occurrence in `text`, or
    /// `nil` — the two indices the ordering claim above compares.
    private static func firstIndex(of needle: String, in text: String) -> Int? {
        guard let range = text.range(of: needle) else { return nil }
        return text.distance(from: text.startIndex, to: range.lowerBound)
    }

    /// One unreadable `tunnels.json` is one condition, so the two lines
    /// written about it are written at the same level (fix round 3, N7).
    ///
    /// `TunnelStore.load()` logs the swallow at `.error`; the activation
    /// reconcile logs the "changed nothing" at whatever this reads out of
    /// that file. At `.info` — which is what it was — the reconcile's line
    /// was dropped by any sink configured at `.error`, which is the level a
    /// user selects precisely when hunting a failure, leaving the one
    /// unreadable-store record that matters unwritten.
    ///
    /// Both levels are DERIVED — the store's from the single
    /// `DiagnosticLog.shared.log(` call its file contains, the manager's from
    /// the single such call inside the function that performs the store
    /// operation — so the check is "these agree", not "both are `.error`",
    /// and it fails closed if either span grows a second call and the
    /// derivation stops being unambiguous.
    ///
    /// Scoped to a FUNCTION on the manager's side since 2026-09-16 (technical
    /// backlog, Task 2), when `TunnelManager.swift` gained its second call:
    /// the line `forgetEverything(for:)` writes when the store refuses a
    /// deleted session's `deleteAll`. That line records the same condition
    /// from the other side, so it is held to the same level, as a second
    /// span rather than as a whole-file count.
    @Test(arguments: ["store.readProfiles(", "store.deleteAll("])
    func theManagerLogsAStoreFailureAtTheStoresOwnLevel(storeCall: String) throws {
        let storeLevel = try Self.soleLogLevel(
            in: Self.strictSource(of: Self.tunnelStoreFile),
            named: Self.tunnelStoreFile.lastPathComponent)
        let body = try Self.enclosingFunctionBody(
            of: storeCall, in: Self.strictSource(of: Self.tunnelManagerFile))
        let managerLevel = try Self.soleLogLevel(
            in: body, named: "the TunnelManager function calling \(storeCall)")
        #expect(managerLevel == storeLevel, """
            the manager writes its line about \(storeCall) failing at \(managerLevel) while \
            TunnelStore writes the same condition at \(storeLevel) — a sink configured at \
            the stricter of the two keeps one record of an unreadable file and drops the \
            other.
            """)
    }

    /// The level argument of the ONE `DiagnosticLog.shared.log(` call `text`
    /// contains. Throws when there is not exactly one, so a second call site
    /// makes this loud rather than arbitrary.
    private static func soleLogLevel(in text: String, named name: String) throws -> String {
        let levels = try captures(
            of: #"DiagnosticLog\.shared\.log\(\s*\.(\w+)"#, in: text)
        guard levels.count == 1, let only = levels.first else {
            throw ScanError.derivation("""
                expected exactly one DiagnosticLog.shared.log( call in \
                \(name) — found \(levels.count): \(levels)
                """)
        }
        return only
    }

    /// The text of the function whose body holds the only occurrence of
    /// `marker`: from the last `func ` before it to that declaration's
    /// matching closing brace. Fails closed when the marker is absent or
    /// repeated, when no `func ` precedes it, or when the span that brace
    /// closes does not reach the marker (a function declared and closed
    /// before it).
    private static func enclosingFunctionBody(of marker: String, in source: String) throws
        -> String
    {
        let ranges = occurrenceRanges(of: marker, in: source)
        guard ranges.count == 1, let markerRange = ranges.first else {
            throw ScanError.derivation(
                "expected exactly one \(marker) — found \(ranges.count)")
        }
        guard let declaration = source.range(
            of: "func ", options: .backwards, range: source.startIndex..<markerRange.lowerBound)
        else {
            throw ScanError.derivation("no func declaration precedes \(marker)")
        }
        var depth = 0
        var entered = false
        var index = declaration.lowerBound
        while index < source.endIndex {
            let character = source[index]
            if character == "{" { depth += 1; entered = true }
            if character == "}" { depth -= 1 }
            index = source.index(after: index)
            if entered, depth == 0 { break }
        }
        guard entered, depth == 0, index > markerRange.upperBound else {
            throw ScanError.derivation("the function before \(marker) does not enclose it")
        }
        return String(source[declaration.lowerBound..<index])
    }

    private static func occurrenceRanges(of needle: String, in text: String) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        var searchStart = text.startIndex
        while let range = text.range(of: needle, range: searchStart..<text.endIndex) {
            found.append(range)
            searchStart = range.upperBound
        }
        return found
    }

    /// Every direct store read the activation path must not perform, with the
    /// file that still performs it — the positive half of the check above.
    /// Counted 2026-09-06: FIVE spellings, each pinned in one file.
    /// `store.readProfiles(` joined the list in fix round 3, when it became
    /// the reconcile's own reader — a reporting read is exactly as wrong
    /// here as a lenient one, because the observer is not the place either
    /// belongs.
    private static let directStoreReads: [(String, URL)] = [
        ("store.all(", sessionListFile),
        ("store.allProfiles(", tunnelManagerFile),
        ("store.readProfiles(", tunnelManagerFile),
        ("SessionStore(directory:", contentViewFile),
        ("TunnelStore(directory:", tunnelManagerFile),
    ]
}

/// The registry side of the activation reload: which session lists the app
/// hands a reload to, driven rather than scanned.
///
/// `TabRegistry()` instances of their own, never `.shared` — the rule that
/// type's own doc comment states, so a registration here can never leak into
/// another test.
@Suite("Every open window's session list", .timeLimit(.minutes(1)))
@MainActor
struct SessionListRegistrationTests {

    private static func makeDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-list-registration-\(UUID().uuidString)")
        return directory
    }

    private static func makeSessionList(in directory: URL) -> SessionListViewModel {
        SessionListViewModel(
            store: SessionStore(directory: directory),
            secrets: RegistrationSecretStore(),
            auditStore: AuditLogStore(directory: directory),
            loginSetStore: LoginSetStore(directory: directory),
            keys: ManagedKeyStore(directory: directory))
    }

    @Test func theRegistryHandsBackEveryRegisteredWindowsSessionList() {
        let directory = Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = TabRegistry()
        let first = Self.makeSessionList(in: directory)
        let second = Self.makeSessionList(in: directory)
        let firstWindow = WindowID()
        let secondWindow = WindowID()

        registry.registerSessionList(first, for: firstWindow)
        registry.registerSessionList(second, for: secondWindow)

        let handed = registry.allSessionLists()
        #expect(handed.count == 2)
        #expect(handed.contains { $0 === first })
        #expect(handed.contains { $0 === second })
    }

    /// Registering is idempotent and order-stable, the rule every other
    /// registration on this type follows: a window calls it on every setup
    /// pass, the last one wins, and no window is handed a reload twice.
    @Test func aWindowRegisteringAgainIsHandedOneReloadNotTwo() {
        let directory = Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = TabRegistry()
        let window = WindowID()
        let first = Self.makeSessionList(in: directory)
        let second = Self.makeSessionList(in: directory)

        registry.registerSessionList(first, for: window)
        registry.registerSessionList(second, for: window)

        let handed = registry.allSessionLists()
        #expect(handed.count == 1)
        #expect(handed.first === second)
    }

    @Test func aWindowThatUnregisteredIsNoLongerHandedBack() {
        let directory = Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = TabRegistry()
        let window = WindowID()
        let list = Self.makeSessionList(in: directory)

        registry.registerSessionList(list, for: window)
        registry.unregisterSessionList(for: window)

        #expect(registry.allSessionLists().isEmpty)
    }

    /// The reference is weak, so a window that went away without
    /// unregistering cannot be reloaded — and cannot be kept alive by the
    /// registry either, which is the same rule `registerModel(_:for:)`
    /// follows for a whole window's worth of live sessions.
    ///
    /// **The view model's lifetime is a SCOPE, not an `= nil`** (fix round
    /// 1). An optional set back to `nil` leaves the release to whatever
    /// temporaries the enclosing function still holds, which is a timing this
    /// test would be measuring rather than asserting. Registered from a
    /// `do {}` of its own instead: the only strong reference is the `let`
    /// inside it, and the check below runs after that scope has ended. The
    /// count inside the scope is asserted on an array that is itself
    /// released at the end of its statement — nothing that outlives the
    /// brace holds the model.
    @Test func aSessionListThatWentAwayIsDroppedRatherThanReloaded() {
        let directory = Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = TabRegistry()
        let window = WindowID()

        do {
            let list = Self.makeSessionList(in: directory)
            registry.registerSessionList(list, for: window)
            #expect(registry.allSessionLists().count == 1)
        }

        #expect(registry.allSessionLists().isEmpty)
    }
}

/// A secret store for the view models above, which never reach a secret at
/// all: they are constructed, registered, and read back by identity.
private final class RegistrationSecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UUID: String] = [:]

    func savePassword(_ password: String, for sessionID: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[sessionID] = password
    }

    func password(for sessionID: UUID) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage[sessionID]
    }

    func deletePassword(for sessionID: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[sessionID] = nil
    }
}
