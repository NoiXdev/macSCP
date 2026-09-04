import Foundation
import Testing

/// Guards the load-bearing security decision of the connection-liveness
/// plan's recovery section: **every connection macSCP opens goes through
/// the one shared connect path**, so TOFU stays a hard stop, the keychain
/// and login-set rules in `ContentView.fillForm(_:from:)` always run, the
/// plaintext confirmation is always asked, and the hand-off locks always
/// apply.
///
/// **This suite is an allow-list, not a deny-list, and that inversion is
/// the whole point.** Its first version asked "does `ContentView
/// .reconnect(_:)` call `connect(in:stored:)`?" — anchored on the function
/// its author had just written. The reviewer defeated it in one line by
/// dialing from somewhere else entirely: `ReconnectRunner`'s mount in
/// `ContentView+Detail.swift` reaches the shared path through
/// `onAttempt: { reconnect($0) }`, and replacing THAT with a direct dial
/// compiled and left the whole suite green while bypassing `fillForm`, the
/// teardown, both hand-off locks, `startSession` and the audit recorder.
/// A guard anchored on the code its author was thinking about cannot see
/// the site its author was not thinking about.
///
/// So the question here is inverted. Not "does this one function
/// delegate?" but: **where can a connection be dialed, or a session be
/// handed to a tab, anywhere in the App layer — and is every such place on
/// the short list below?** A new dial anywhere in `Sources/MacSCPAppKit`
/// now turns this suite red by default, including in a file nobody thought
/// to anchor on. The same inversion this project already applied to the
/// snippet gate, for the same measured reason: an allow-list makes "nobody
/// thought of it" fail closed, a deny-list makes it pass.
///
/// The scan runs over comment- and string-stripped source, so neither a doc
/// comment nor a log line naming a call can satisfy or trip it — a mutation
/// that deleted a real call and left the prose behind is how an earlier
/// guard on this branch passed while broken.
///
/// Fail-closed throughout: an unreadable file, a missing anchor, an
/// unbalanced brace, a walk that finds implausibly few files, a symbolic
/// link among the sources, and a sanctioned site that no longer exists are
/// all failures.
///
/// ## What this guard cannot see
///
/// Green here is not proof that no dial escapes the shared path. Five
/// known gaps, named so the next person does not mistake one for the
/// other:
///
/// 1. **A Core-side dial under another name.** A function in Core —
///    `QuickOpenHelper.open(config)`, say — that dials, called from the
///    App, passes and always will. Core is an excluded root precisely
///    because dialling legitimately lives there, so an App call into an
///    arbitrarily named Core function is textually indistinguishable from
///    any other Core call. Catching it would mean knowing which Core
///    functions dial, which is this same problem one level down. **No
///    source scan can close this.** It needs a capability boundary in the
///    design — the App layer being unable to obtain a connection except
///    through one type it must hold — which is an architectural change,
///    not a guard. See "Where the capability boundary actually got to"
///    below for how far that change has come and what it does not yet
///    cover.
/// 2. **A key-path write**: `tab[keyPath: \SessionTab.session] = nil`
///    names neither `.session =` nor anything else these patterns look
///    for.
/// 3. **`Mirror`-based label lookup** reaches a property without naming
///    it in source at all.
/// 4. **A suspension more than one wrapped line above its call.** The
///    `.connect` discrimination reads a two-line window (see
///    `Discrimination.unlessSynchronousCall`), so a dial split across
///    three lines reads as an ordinary synchronous call and is excused.
/// 5. **The next spelling that suspends.** `suspends(_:)` knows the two
///    Swift has today — `await`, and the `async let` that round 6
///    measured slipping past a check that only knew the first. It knows
///    them because they were written down after being found, not because
///    anything here derives them from the language: a future spelling, or
///    a synchronous-looking wrapper whose own body does the awaiting
///    somewhere this scan does not read, is excused for the same reason
///    `async let` was.
///
/// Gaps 2 and 3 are exotic — they would not survive code review as
/// ordinary code, which is the layer that catches them. Gap 4 is the price
/// of clearing a false positive that would otherwise have taught someone
/// to switch this suite off.
///
/// Gaps 1 and 5 are the real ones, and they are the same gap seen from two
/// sides. `async let` was the sixth time on this branch that a SPELLING
/// beat a detector, and the fix for it was, once again, to write the
/// spelling down. That is a race this method loses permanently: a scan
/// over a language with several ways to spell one meaning can only ever
/// enumerate the ways someone has already thought of, and every round of
/// this suite has ended by adding one more. Round 6's addition is not
/// evidence that the enumeration is now complete — the previous five
/// rounds each looked equally complete from the inside.
///
/// ## Where the capability boundary actually got to
///
/// What would end that race is not a seventh pattern but a boundary the
/// App layer cannot spell around. Part of one now exists, and the useful
/// thing to record is which part. Each claim below was compiled in the
/// pass that wrote it, from a throwaway file under `Sources/MacSCPAppKit`
/// that was deleted again:
///
/// - **A decider is a type, not a closure.** `HostKeyDecider` and
///   `WebDAVSessionDelegate.CertificateDecider` have private initializers,
///   so a bare accept-anything closure where one is expected does not
///   compile: `closure passed to parameter of type 'HostKeyDecider' that
///   does not accept a closure`. A yes-man has to be spelled out as
///   `.asking { _ in true }` now.
/// - **The descriptor's own dial is out of reach.**
///   `BackendDescriptor.connect` is module-internal: `'connect' is
///   inaccessible due to 'internal' protection level`. Nothing in these
///   targets can route around `openConnection` by asking
///   `descriptor(for:)` for the closure.
/// - **Every backend's own dial is out of reach as well.**
///   `CitadelFileSystem.connect`, `WebDAVFileSystem.connect` and
///   `S3FileSystem.connect` are module-internal too, each refusing with the
///   same `'connect' is inaccessible due to 'internal' protection level`.
///   macSCP's own backends cannot be dialed from these targets at all, by
///   any spelling.
/// - **A transport library still can be, and that is the gap that is
///   left.** `import Citadel` compiles here even though `Package.swift`
///   gives `MacSCPAppKit` no Citadel dependency — SwiftPM leaves a
///   transitive dependency's module on the search path — so a raw
///   `SSHClient.connect(host:…, hostKeyValidator: .acceptAnything(), …)`
///   compiles in the App layer, reaching no TOFU, no keychain rule, no
///   login-set rule and no plaintext gate. Access levels closed macSCP's
///   own dials; they did not close that one. `permittedImports` and the
///   scan below are what stand in front of it, which is why neither is
///   decoration.
///
/// The access-level claims are about the app and the command line only: the
/// App TEST target imports Core `@testable`, which lifts `internal` and
/// hands that target both the descriptor's dial and the backends' own back.
/// The decider claim is not relaxed that way — `@testable` does not reach a
/// `private` initializer — so it holds everywhere in this package. Either
/// way this suite walks `Sources/` and nothing else, which is the scope it
/// has always had.
///
/// And one property neither the compiler nor any scan here holds:
/// **whether a decider that IS a type asks anybody.** Replacing the App
/// layer's certificate decider with `.asking { _ in true }` compiles, and
/// the whole test run stays green. The host-key side is not in that
/// position — `ConnectionViewModel` builds its own decider and
/// `ConnectionViewModelTests` goes red for the same mutation — but the
/// certificate one is held by nothing, here or anywhere. Measured
/// 2026-08-28; not guarded by a scan, on purpose, because the six rounds
/// above are the argument against adding a seventh.
@Suite("Reconnect wiring guard")
struct ReconnectWiringGuardTests {
    /// `#filePath` here is
    /// `<repoRoot>/Tests/macSCPAppKitTests/ReconnectWiringGuardTests.swift`;
    /// three `deletingLastPathComponent()` calls recover the repo root
    /// regardless of `swift test`'s working directory.
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static func file(_ relativePath: String) -> URL {
        repoRoot.appendingPathComponent(relativePath)
    }

    private static let sourcesDirectory = repoRoot.appendingPathComponent("Sources")

    /// The GUI targets this suite scans, BY NAME — but never as the last
    /// word on what exists. Round 2 hardcoded this list, and the reviewer
    /// walked past it by adding a whole new target: `Sources/MacSCPPanels`,
    /// containing a `BackendDescriptor` connect with an accept-anything
    /// host-key decider, made a dependency of the shipped `MacSCPMain`. The
    /// suite stayed green, and the walk's own floor test stayed true
    /// throughout, because a floor cannot notice what it was never pointed
    /// at.
    ///
    /// So the roots are DERIVED and this list is only one half of a
    /// partition. `everySourceDirectoryIsScannedOrExplicitlyExcluded` reads
    /// what is actually on disk under `Sources/`, and
    /// `everyPackageTargetIsScannedOrExplicitlyExcluded` reads what
    /// `Package.swift` actually declares; a directory or target in neither
    /// list fails both. A guard that scans less than it thinks is worse
    /// than one that scans nothing, because it reports success.
    private static let scannedRootNames = ["MacSCPAppKit", "MacSCPMain"]

    private struct ExcludedRoot {
        let name: String
        let reason: String
    }

    /// Not scanned, on purpose, each with the reason that makes it a
    /// decision rather than an oversight. An exclusion is as much a
    /// security statement as a sanctioned site, and is meant to be read as
    /// one.
    private static let excludedRoots: [ExcludedRoot] = [
        ExcludedRoot(
            name: "macSCPCore",
            reason: "Core is where the dial legitimately lives — every backend's `connect` is defined there. The property this suite guards is that the APP reaches those through one path, so scanning Core would mean sanctioning the implementation this suite exists to funnel access to."),
        ExcludedRoot(
            name: "MacSCPCLI",
            reason: "A separate program with no tabs, no lost surface and no reconnect policy. Its own connect path is a different property; sanctioning its dial sites here would mean vouching for code this suite is not about."),
    ]

    /// Package targets that are declared with an explicit `path:` outside
    /// `Sources/` and therefore have no directory for
    /// `everySourceDirectoryIsScannedOrExplicitlyExcluded` to find — naming
    /// one in `excludedRoots` would make that check fail with "named but no
    /// longer exists", which is the wrong red for a target that was never
    /// there to begin with. Named here instead, so
    /// `everyPackageTargetIsScannedOrExplicitlyExcluded` still accounts for
    /// it without the two checks disagreeing about what `Sources/` holds.
    private static let targetsRootedOutsideSources: [ExcludedRoot] = [
        ExcludedRoot(
            name: "MacSCPTestSupport",
            reason: "A plain target under Tests/, not Sources/: shared test-only helpers (currently `pollUntil`) with no path into the shipped app and no reconnect policy of its own. It is a leaf both test targets depend on, not a caller either scanned root can reach."),
    ]

    private static var scannedRoots: [URL] {
        scannedRootNames.map { sourcesDirectory.appendingPathComponent($0) }
    }

    // MARK: - The choke points, and who is allowed to be at one

    /// What counts as touching a choke point — expressed as patterns over
    /// the THING, not as literal spellings of it.
    ///
    /// Round 2 got this half wrong, and the reviewer measured it: the sites
    /// were an allow-list, but the detector was still thirteen literal
    /// substrings, which is a deny-list wearing an allow-list's clothes.
    /// `let dial = connectionViewModel.connect` followed by
    /// `Task { _ = await dial() }` bypassed `fillForm`, both hand-off locks,
    /// `startSession` and the audit recorder — and passed, because the
    /// token was `.connect(` and the evasion has no paren. Every entry here
    /// was re-read with that question: does this describe a thing, or one
    /// way of writing it?
    ///
    /// What changed, and why:
    /// - `.connect(` → `\.connect\b`. A member named `connect`, applied or
    ///   merely referenced. `.connected`/`.connecting` do not match (the
    ///   word boundary), and catalog keys naming it are string literals the
    ///   stripper has already blanked. `openConnection` joined it as an
    ///   alternative once Core's dial moved behind that name — see the
    ///   comment on the choke point itself.
    /// - the five concrete backend/transport type names → two patterns for
    ///   the CATEGORY. Any `…FileSystem` that is not the protocol
    ///   (`RemoteFileSystem`) or the one legitimate local one
    ///   (`LocalFileSystem`), and any `SSH…Client`/`SFTP…Client`. A fourth
    ///   backend added to Core is caught without anyone remembering to add
    ///   it here.
    /// - `import Citadel`/`import NIO` → deleted, and replaced by
    ///   `permittedImports` below. Naming forbidden modules is the same
    ///   deny-list mistake one level down; every import in these targets is
    ///   now allow-listed instead.
    /// - `startSession(`/`BrowserSession(`/`LostConnectionContent(`/
    ///   `LostConnectionView(` → the paren is dropped or made part of a
    ///   construction pattern that also accepts `.init`, so a reference or
    ///   an `.init` spelling cannot slip past.
    /// - `tab.session =` → a pattern for WRITING that property through any
    ///   receiver (`self.session =`, `activeTab.session =`) or none, while
    ///   excluding the `if let session =` bindings that merely read it.
    ///
    /// `dot(.red` → `\bdot\s*\(\s*\.red\b` is the one entry that stays
    /// tied to a helper's name, and it is worth being honest about: a
    /// renamed helper would evade it. It is a belt, not the guarantee. What
    /// actually keeps the `.lost` suppression working is `TabIndicatorPlan`
    /// plus `ReconnectPlanTests` and
    /// `theTabIndicatorPassesItsArgumentsUnconditioned`.
    private enum Discrimination {
        /// Every match counts.
        case always
        /// A match counts unless it is an ordinary SYNCHRONOUS call: an
        /// applied `(…)` whose window does not suspend. Exists for exactly
        /// one shape — Combine's `ConnectablePublisher.connect()`, which is
        /// not async and is never awaited. Round 3 flagged such a call as a
        /// dial, and a guard that cries wolf on unrelated code is a guard
        /// the next person switches off.
        ///
        /// Every dial in this project is `async`, so it has to suspend to
        /// be a dial — but round 6 measured what that does NOT imply: it
        /// does not imply the word `await` is written. `async let` calls an
        /// `async` function without it, and the version of this comment
        /// that said a dial "cannot be called without `await`" was the
        /// reason nobody looked. `suspends(_:)` is what answers the
        /// question now, and it knows about both spellings — see its own
        /// doc comment for the mutation, and this suite's "what this guard
        /// cannot see" for why knowing about two is not the same as
        /// knowing about all of them.
        ///
        /// An unapplied reference (`let dial = x.connect`) is never
        /// excused: it has no parentheses, and it is the round-2 evasion.
        case unlessSynchronousCall
    }

    private struct ChokePoint {
        let pattern: String
        /// What the pattern is looking for, in words — this is what a
        /// failure message tells the reader they have just done.
        let describes: String
        var discrimination: Discrimination = .always
    }

    private static let chokePoints: [ChokePoint] = [
        // Round 5, review-measured — and the same lesson a fifth time: a
        // detector that matches a SPELLING loses to a spelling. This one
        // required a literal dot, and Swift's implicit `self` inside a
        // same-type extension removes it. The defeating mutation was one
        // line in a brand-new App-layer file —
        // `extension ConnectionViewModel { func redial() async -> (any
        // RemoteFileSystem)? { await connect() } }` — called from the
        // failed-connect surface: the whole suite stayed green while the
        // call bypassed `fillForm`, the plaintext confirmation,
        // `startSession`, the audit recorder and both hand-off locks. The
        // reviewer ran the dotted spelling of the same helper first and it
        // WAS red, so the walk does reach unanchored files; only the
        // receiver's absence escaped.
        //
        // So the pattern is now over the IDENTIFIER, with no claim about
        // how the receiver is written or whether there is one:
        // `.connect`, `self.connect`, a bare `connect` inside an
        // extension, `\.connect` as a key path and `Type.connect` as an
        // unapplied reference all match. `reconnect`/`retryConnect`/
        // `connected`/`connecting` do not — the lookbehind rejects a
        // preceding identifier character and `\b` rejects a following one.
        //
        // The App layer's OWN synchronous funnel calls
        // (`connect(in:stored:)` and its declaration) now match too, and
        // are excused by the discrimination rather than by the pattern:
        // they are applied and carry no `await`, while every dial in this
        // project is `async`. That is the honest split — "is this a dial"
        // is answered by whether it suspends, not by whether someone
        // spelled a receiver.
        //
        // The alternation is round 7's addition, and it is bookkeeping
        // rather than another spelling lost to: Core's dial moved behind
        // `BackendDescriptor.openConnection`, whose name contains no
        // lowercase `connect` at all. Left alone, the detector above would
        // have matched nothing at the one App-layer dial and gone on
        // reporting an empty unsanctioned list — the silent-negative
        // failure this project has a rule about. Access levels have since
        // closed macSCP's OWN dials, descriptor and backends alike, so what
        // this pattern still catches is a dial that is not macSCP's:
        // `ConnectionViewModel.connect()`, which is public Core API and
        // goes around everything `ContentView.connect(in:stored:)` applies,
        // and a raw `SSHClient.connect(…)` through the transport library,
        // which the App layer can still import. Both compile from here
        // today, so this is not a leftover beside a guarantee.
        ChokePoint(
            pattern: #"(?<![A-Za-z0-9_])(?:connect|openConnection)\b"#,
            describes: "obtaining a connection",
            discrimination: .unlessSynchronousCall),
        // `[A-Z]` (round 4, review-measured): the lookaheads are
        // case-sensitive, so `let remoteFileSystem = fs` — an ordinary
        // local — was read as a concrete backend. Swift capitalizes type
        // names, so requiring one is what distinguishes a type from a
        // variable that merely ends the same way.
        ChokePoint(
            pattern: #"\b(?!RemoteFileSystem\b)(?!LocalFileSystem\b)[A-Z]\w*FileSystem\b"#,
            describes: "naming a concrete remote backend"),
        ChokePoint(
            pattern: #"\b(?:SSH|SFTP)\w*Client\b"#,
            describes: "naming a transport client"),
        ChokePoint(
            pattern: #"\bstartSession\b"#,
            describes: "installing a session on a tab"),
        ChokePoint(
            pattern: #"\bBrowserSession\s*(?:\(|\.init\b)"#,
            describes: "constructing a session"),
        // Narrowed to what is actually ASSIGNED (round 4,
        // review-measured): `self.session = URLSession.shared` matched the
        // old property-name-only pattern, and `session` is far too common a
        // property name to keep flagging by name alone.
        //
        // The three assignable shapes are `nil` (releasing one), a
        // `BrowserSession` (installing a fresh one) and another object's
        // `.session` (moving a live one between tabs). Nothing is lost by
        // narrowing: a `BrowserSession` cannot exist without its
        // construction being flagged by the pattern above, so a write whose
        // right-hand side is some helper's return value is caught where
        // that helper builds it.
        ChokePoint(
            pattern: #"(?:\.|(?<!let )(?<!var )(?<![A-Za-z0-9_.]))session\s*=\s*(?:nil\b|BrowserSession\b|[A-Za-z_][\w.?!]*\.session\b)"#,
            describes: "moving a session onto or off a tab"),
        ChokePoint(
            pattern: #"\bLostConnectionContent\s*(?:\(|\.init\b)"#,
            describes: "building the lost-connection surface's content"),
        ChokePoint(
            pattern: #"\bLostConnectionView\s*(?:\(|\.init\b)"#,
            describes: "rendering the lost-connection surface"),
        // The failed-connect surface's own pair (failed-connect surface
        // plan, Task 3), added for the reason the two above exist: the
        // claim that this surface can only show a fixed set of catalog
        // keys holds only while ONE function builds its content and ONE
        // view renders it. The dialog is in the second pattern rather than
        // a third entry because it is part of the same surface — it is
        // where the surface puts the one text that is NOT a catalog key,
        // and a second, unsanctioned dialog fed from somewhere else is
        // exactly the change that should stop a reader.
        ChokePoint(
            pattern: #"\bConnectFailure(?:Content|DetailText)\s*(?:\(|\.init\b)"#,
            describes: "building the failed-connect surface's content or its details text"),
        ChokePoint(
            pattern: #"\bConnectFailure(?:View|DetailsSheet)\s*(?:\(|\.init\b)"#,
            describes: "rendering the failed-connect surface or its details dialog"),
        ChokePoint(
            pattern: #"\bdot\s*\(\s*\.red\b"#,
            describes: "drawing the attention dot"),
    ]

    /// Every module these targets may import. An allow-list for the same
    /// reason the sites are one: a hand-rolled dial has to reach a
    /// transport somehow, and naming the libraries it must NOT use is a
    /// list that fails open on the first one nobody thought of.
    ///
    /// Ten entries, counted while writing this sentence. Adding an eleventh
    /// is a deliberate edit, which is the point — `import Citadel`,
    /// `import NIOCore` or `import Network` appearing in the App layer is
    /// exactly the change that should stop a reader.
    ///
    /// Measured in the pass that made every backend's `connect`
    /// module-internal, because it is why this list outlived that change:
    /// `Package.swift` gives `MacSCPAppKit` no Citadel dependency, and
    /// `import Citadel` compiles here anyway — SwiftPM leaves a transitive
    /// dependency's module on the search path. A raw
    /// `SSHClient.connect(host:…, hostKeyValidator: .acceptAnything(), …)`
    /// therefore compiles in the App layer, reaching no TOFU. Access levels
    /// closed macSCP's own dials; this list is what stands in front of that
    /// one.
    private static let permittedImports: Set<String> = [
        "AppKit", "Combine", "Foundation", "MacSCPAppKit", "Observation",
        "SwiftTerm", "SwiftUI", "UniformTypeIdentifiers", "macSCPCore", "os",
    ]

    private struct SanctionedSite {
        /// Repo-relative path.
        let file: String
        /// The line as it must read after comment/string stripping and
        /// whitespace normalization.
        let code: String
        /// How many times that exact line may appear in that file. Always
        /// `1` today — the field exists so a SECOND line spelled identically
        /// to a sanctioned one cannot smuggle a dial in under its allowance.
        let occurrences: Int
        let reason: String
    }

    /// Fifteen entries, counted while writing this sentence. Adding a
    /// sixteenth is a deliberate edit here, with a reason, which is the
    /// entire mechanism: a new dial cannot become invisible by being
    /// somewhere nobody anchored on.
    private static let sanctionedSites: [SanctionedSite] = [
        SanctionedSite(
            file: "Sources/MacSCPAppKit/ContentView+Lifecycle.swift",
            code: "return try await BackendDescriptor.openConnection(",
            occurrences: 1,
            reason: "The connector closure `ContentView.makeTab` builds — the ONE place the App layer reaches a backend, with the host-key decider, the certificate decider and the plaintext gate already applied around it. The descriptor's own `connect` closure is module-internal to Core, so this is the whole surface of `BackendDescriptor` that this target can reach, and every backend's own `connect` is module-internal too. What the scan above still catches is a dial that is not macSCP's own — `ConnectionViewModel.connect()`, or the transport library reached directly."),
        SanctionedSite(
            file: "Sources/MacSCPAppKit/ConnectionFormView.swift",
            code: "if let fs = await viewModel.connect() {",
            occurrences: 1,
            reason: "The connection form's own Connect button — the ad-hoc path, which hands its result to `ContentView.handleAdHocConnected`."),
        SanctionedSite(
            file: "Sources/MacSCPAppKit/ContentView.swift",
            code: "if let fs = await form.connect(origin: stored.id) {",
            occurrences: 1,
            reason: "`ContentView.connect(in:stored:)` — the stored-session path, after `fillForm(_:from:)` has applied the keychain, login-set and managed-key rules. This is the dial `reconnect(_:)` reaches. The `origin:` argument is the one place the App layer names which stored session an attempt belongs to (M3); spelled out here so dropping it, which would silently downgrade every stored failure to an ad-hoc one, has to be a deliberate edit in this list."),
        SanctionedSite(
            file: "Sources/MacSCPAppKit/ContentView.swift",
            code: "func startSession(",
            occurrences: 1,
            reason: "The hand-off function's own declaration."),
        SanctionedSite(
            file: "Sources/MacSCPAppKit/ContentView.swift",
            code: "tab.session = BrowserSession(",
            occurrences: 1,
            reason: "Inside `startSession` — the only construction of a `BrowserSession` in the App layer."),
        SanctionedSite(
            file: "Sources/MacSCPAppKit/ContentView.swift",
            code: "startSession(in: tab, with: fs, startPath: home)",
            occurrences: 1,
            reason: "`handleAdHocConnected` — the ad-hoc path's hand-off, behind its own attempt-token check."),
        SanctionedSite(
            file: "Sources/MacSCPAppKit/ContentView.swift",
            code: "startSession(in: tab, with: fs, storedName: stored.name, startPath: home)",
            occurrences: 1,
            reason: "`connect(in:stored:)` — the stored-session path's hand-off, behind its own attempt-token check."),
        SanctionedSite(
            file: "Sources/MacSCPAppKit/ContentView+Lifecycle.swift",
            code: "tab.session = nil",
            occurrences: 1,
            reason: "`teardown(_:)` releasing the session — the only other writer of that property."),
        SanctionedSite(
            file: "Sources/MacSCPAppKit/ContentView+Detail.swift",
            code: "return LostConnectionContent(",
            occurrences: 1,
            reason: "`LostConnectionPlan.content` — the only builder of the error view's content, which is what keeps that surface to a fixed set of catalog keys (see `ReconnectPlanTests`)."),
        SanctionedSite(
            file: "Sources/MacSCPAppKit/ContentView+Detail.swift",
            code: "LostConnectionView(",
            occurrences: 1,
            reason: "`ContentView.detail`'s lost branch — the only site that renders the error view."),
        SanctionedSite(
            file: "Sources/MacSCPAppKit/ContentView+Detail.swift",
            code: "ConnectFailureContent(",
            occurrences: 1,
            reason: "`ConnectFailurePlan.content` — the only builder of the failed-connect surface's content, which is what keeps that surface to a fixed set of catalog keys (see `ConnectFailurePlanTests`)."),
        SanctionedSite(
            file: "Sources/MacSCPAppKit/ContentView+Detail.swift",
            code: "ConnectFailureView(",
            occurrences: 1,
            reason: "`ContentView.detail`'s failed-connect branch — the only site that renders that surface, and the one place its five actions are wired to the functions they delegate to."),
        SanctionedSite(
            file: "Sources/MacSCPAppKit/ContentView+Detail.swift",
            code: "ConnectFailureDetailsSheet(",
            occurrences: 1,
            reason: "`ConnectFailureView`'s own sheet — the only site that opens the details dialog, which is the one surface on this branch showing a raw error text and therefore the one whose single source matters."),
        SanctionedSite(
            file: "Sources/MacSCPAppKit/ConnectFailureDetails.swift",
            code: "return ConnectFailureDetailText(text: message)",
            occurrences: 1,
            reason: "`ConnectFailureDetailText.read(from:)` — the only construction of the details text in the App layer, and the line that decides it is the published message and nothing else."),
        SanctionedSite(
            file: "Sources/MacSCPAppKit/TabStripView.swift",
            code: "case .attention: dot(.red, pulse: false)",
            occurrences: 1,
            reason: "`TabItemView.body` — the only site that draws the attention dot, and it draws it from `TabIndicatorPlan`'s answer, which is where the `.lost` suppression lives."),
    ]

    // MARK: - The allow-list scan

    /// The claim: no line anywhere under `Sources/MacSCPAppKit` touches a
    /// choke point except the sanctioned ones. This is the test the
    /// reviewer's mutation trips — the dial it added sits in
    /// `ContentView+Detail.swift`, which has sanctioned lines of its own,
    /// but not that one.
    @Test func everyChokePointInTheAppLayerIsSanctioned() throws {
        let detectors = try Self.chokePointDetectors()
        var unsanctioned: [String] = []
        for file in try Self.appSwiftFiles() {
            let relative = Self.relativePath(of: file)
            let stripped = try Self.stripCommentsAndStrings(
                try String(contentsOf: file, encoding: .utf8))
            let codeLines = stripped.split(separator: "\n", omittingEmptySubsequences: false)
                .map { Self.normalized(String($0)) }
            for (index, code) in codeLines.enumerated() {
                let window = index > 0 ? codeLines[index - 1] + " " + code : code
                guard let describes = Self.chokePoint(in: code, window: window, detectors: detectors)
                else { continue }
                let sanctioned = Self.sanctionedSites.contains {
                    $0.file == relative && $0.code == code
                }
                if !sanctioned { unsanctioned.append("\(relative): \(code)   [\(describes)]") }
            }
        }
        #expect(unsanctioned.isEmpty, """
            unsanctioned choke point(s) in the App layer:
            \(unsanctioned.joined(separator: "\n"))

            A connection may only be dialed, and a session may only be handed to a tab, at a \
            site on `sanctionedSites`. Every other path must go through \
            `ContentView.connect(in:stored:)` — that is what keeps TOFU a hard stop, the \
            keychain and login-set rules applied, the plaintext confirmation asked and the \
            hand-off locks in force. If this line really is a new sanctioned path, add it to \
            the list WITH a reason, and expect that addition to be read as the security \
            decision it is.
            """)
    }

    /// The other half, without which the list rots into fiction: every
    /// allowance must still match, and match exactly as many lines as it
    /// claims. A count of 0 means the code moved and the allowance is now
    /// a lie; a count of 2 means a second line spelled identically to a
    /// sanctioned one is riding on its allowance.
    @Test func everySanctionedSiteStillExistsExactlyAsOftenAsDeclared() throws {
        for site in Self.sanctionedSites {
            let stripped = try Self.stripCommentsAndStrings(
                try String(contentsOf: Self.file(site.file), encoding: .utf8))
            let matches = stripped
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { Self.normalized(String($0)) == site.code }
                .count
            #expect(matches == site.occurrences, """
                `\(site.code)` appears \(matches) time(s) in \(site.file), expected \
                \(site.occurrences). Sanctioned for: \(site.reason)
                """)
        }
    }

    /// The walk itself has to be believable, or both tests above pass by
    /// scanning nothing. Checked against a floor and a known member rather
    /// than an exact count, so adding a source file is not a test edit.
    @Test func theScanActuallyReachesTheAppLayer() throws {
        let files = try Self.appSwiftFiles()
        #expect(files.count >= 30, """
            only \(files.count) Swift files found under Sources/MacSCPAppKit — the walk is \
            not reaching the App layer, and the allow-list scan above is scanning nothing.
            """)
        #expect(files.contains { $0.lastPathComponent == "ContentView.swift" })
        #expect(files.contains { $0.lastPathComponent == "TabStripView.swift" })
        #expect(files.contains { $0.lastPathComponent == "Main.swift" }, """
            the second scanned root (Sources/MacSCPMain) is not being reached.
            """)
    }

    /// Derives the roots from the filesystem rather than trusting the list:
    /// every directory under `Sources/` must be either scanned or
    /// explicitly excluded with a reason. This is what a new target cannot
    /// walk past — the reviewer's `Sources/MacSCPPanels`, with its
    /// accept-anything host-key decider, is a directory that is in neither
    /// list, so it fails here whether or not anyone remembered this suite.
    ///
    /// Both directions are checked: an unknown directory fails, and a name
    /// on either list that no longer exists on disk fails too, so neither
    /// list can rot into a claim about code that is gone.
    @Test func everySourceDirectoryIsScannedOrExplicitlyExcluded() throws {
        let contents = try FileManager.default.contentsOfDirectory(
            at: Self.sourcesDirectory, includingPropertiesForKeys: [.isDirectoryKey])
        let directories = contents.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }.map(\.lastPathComponent)

        #expect(directories.count >= 2, """
            only \(directories.count) director(ies) found under Sources/ — this check is not \
            reading the directory it is meant to derive the roots from.
            """)

        let known = Set(Self.scannedRootNames).union(Self.excludedRoots.map(\.name))
        let unknown = Set(directories).subtracting(known)
        #expect(unknown.isEmpty, """
            director(ies) under Sources/ that this suite neither scans nor excludes: \
            \(unknown.sorted()).

            A new target is invisible to a hardcoded root list — which is exactly how a target \
            containing a `BackendDescriptor` connect with an accept-anything host-key decider \
            was added, made a dependency of the shipped app, and left this suite green. Add it \
            to `scannedRootNames` (and expect to sanction whatever it dials), or to \
            `excludedRoots` WITH a reason that says why its connect path is not this property.
            """)

        let missing = known.subtracting(directories)
        #expect(missing.isEmpty, """
            \(missing.sorted()) are named by this suite but no longer exist under Sources/ — \
            an allowance for code that is gone is a lie about the code.
            """)
    }


    /// The parser, on every form the grammar allows — including the one
    /// whose misreading would have talked a developer into opening the
    /// door this list exists to hold shut.
    @Test func theImportParserReadsTheModuleNotTheKeyword() throws {
        let modules = try Self.importedModules(in: """
            import Foundation
            @preconcurrency import SwiftUI
            import Foundation.NSString
            import struct Foundation.Decimal
            import struct Citadel.SSHClient
            import func Darwin.fcntl
            let showImportFileImporter = true
            """)
        #expect(modules == ["Citadel", "Darwin", "Foundation", "SwiftUI"], """
            expected the MODULE of each import — `import struct Foundation.Decimal` is             Foundation, not `struct`, and `import struct Citadel.SSHClient` is Citadel, which             is exactly what must not be able to hide behind a keyword: \(modules)
            """)
    }

    /// Every module imported by the scanned sources, first path component
    /// only. Shared by `everyImportIsPermitted` and its parser self-test so
    /// the two cannot disagree about what an import is.
    private static func importedModules(in stripped: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: importPattern)
        let range = NSRange(stripped.startIndex..., in: stripped)
        var modules: Set<String> = []
        for match in regex.matches(in: stripped, range: range) {
            guard let nameRange = Range(match.range(at: 1), in: stripped) else { continue }
            modules.insert(String(stripped[nameRange]))
        }
        return modules.sorted()
    }

    /// No source the compiler sees may be reached through a symbolic link.
    ///
    /// The gap this closes was measured, not imagined: a directory linked
    /// in under a scanned root compiles into the target while the walk
    /// neither descends into it nor reports it — see `appSwiftFiles()`'s
    /// own doc comment. This test names the offending paths directly, so
    /// the finding is readable without decoding a thrown error.
    @Test func noSourceIsReachedThroughASymbolicLink() throws {
        let links = try Self.symbolicLinks(under: Self.scannedRoots + [Self.sourcesDirectory])
        #expect(links.isEmpty, """
            symbolic link(s) among the scanned sources: \(links).

            A symlinked directory is compiled into the target, but the walk does not descend \
            into it and it does not report itself as a directory — so it is neither scanned \
            for dials nor reported as an unscanned root, and this suite reports success over \
            less than it read. Replace it with a real directory, or teach the walk to resolve \
            it deliberately.
            """)
    }

    /// Proves the detector actually detects, without planting a symlink in
    /// the repository: a throwaway tree with a real subdirectory, a link to
    /// a directory INSIDE the tree, a link to one OUTSIDE it, and a linked
    /// file — checking that all three links are found and the real
    /// directory and file are not.
    @Test func theSymlinkDetectorFindsALinkedDirectory() throws {
        let manager = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-symlink-guard-\(UUID().uuidString)")
        let outside = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-symlink-outside-\(UUID().uuidString)")
        defer {
            try? manager.removeItem(at: root)
            try? manager.removeItem(at: outside)
        }

        let real = root.appendingPathComponent("Real")
        try manager.createDirectory(at: real, withIntermediateDirectories: true)
        try manager.createDirectory(at: outside, withIntermediateDirectories: true)
        let realFile = real.appendingPathComponent("Kept.swift")
        try "// kept".write(to: realFile, atomically: true, encoding: .utf8)
        let outsideFile = outside.appendingPathComponent("Hidden.swift")
        try "// hidden".write(to: outsideFile, atomically: true, encoding: .utf8)

        try manager.createSymbolicLink(
            at: root.appendingPathComponent("LinkedInside"), withDestinationURL: real)
        try manager.createSymbolicLink(
            at: root.appendingPathComponent("LinkedOutside"), withDestinationURL: outside)
        try manager.createSymbolicLink(
            at: real.appendingPathComponent("LinkedFile.swift"), withDestinationURL: outsideFile)

        let links = try Self.symbolicLinks(under: [root])
        #expect(links.count == 3, "expected the three links, found \(links)")
        #expect(links.contains { $0.hasSuffix("LinkedInside") })
        #expect(links.contains { $0.hasSuffix("LinkedOutside") }, """
            a link pointing outside the tree must be found too — that is the shape whose \
            contents no repo-relative scan could ever describe.
            """)
        #expect(links.contains { $0.hasSuffix("LinkedFile.swift") })
        #expect(!links.contains { $0.hasSuffix("Real") })
        #expect(!links.contains { $0.hasSuffix("Kept.swift") })
    }

    /// And the walk must refuse to answer while one is present, so every
    /// scanning test fails rather than only the dedicated one above.
    @Test func theWalkRefusesToScanWhileALinkIsPresent() throws {
        let manager = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-symlink-refusal-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: root) }
        let real = root.appendingPathComponent("Real")
        try manager.createDirectory(at: real, withIntermediateDirectories: true)
        try manager.createSymbolicLink(
            at: root.appendingPathComponent("Linked"), withDestinationURL: real)

        let links = try Self.symbolicLinks(under: [root])
        #expect(!links.isEmpty)
        // The refusal `appSwiftFiles()` performs, on the same input: a
        // non-empty link list is what it turns into a thrown error.
        let error = ScanError.symbolicLinkInSources(links)
        #expect(error.description.contains("symbolic link"))
        #expect(error.description.contains("Linked"))
    }

    /// The second, independent derivation: `Package.swift`'s own non-test
    /// targets. A target could in principle live outside `Sources/` (SwiftPM
    /// takes a `path:`), which the filesystem check above would never see.
    ///
    /// Read from the RAW manifest, comments included. A commented-out target
    /// therefore demands coverage it does not need — a false positive, which
    /// is the safe direction for this check and cheaper than parsing Swift.
    @Test func everyPackageTargetIsScannedOrExplicitlyExcluded() throws {
        let manifest = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("Package.swift"), encoding: .utf8)
        let regex = try NSRegularExpression(
            pattern: #"\.(?:executableTarget|target)\(\s*name:\s*"([^"]+)""#)
        let range = NSRange(manifest.startIndex..., in: manifest)
        var targets: Set<String> = []
        for match in regex.matches(in: manifest, range: range) {
            guard let nameRange = Range(match.range(at: 1), in: manifest) else { continue }
            targets.insert(String(manifest[nameRange]))
        }

        #expect(targets.count >= 2, """
            only \(targets.count) target(s) parsed out of Package.swift — the manifest scan is \
            not reading what it thinks it is.
            """)

        let known = Set(Self.scannedRootNames)
            .union(Self.excludedRoots.map(\.name))
            .union(Self.targetsRootedOutsideSources.map(\.name))
        let unknown = targets.subtracting(known)
        #expect(unknown.isEmpty, """
            Package.swift declares target(s) this suite neither scans nor excludes: \
            \(unknown.sorted()). See `everySourceDirectoryIsScannedOrExplicitlyExcluded` for \
            what to do about it — this check exists because a target's sources need not live \
            under Sources/ at all.
            """)
    }

    /// The last gap in the "this surface can only show fixed catalog keys"
    /// claim, found by asking where the property could be violated FROM
    /// rather than whether the lines just written still say what they said:
    /// `LostConnectionContent` covers what is passed IN, and the allow-list
    /// above pins that the plan is its only builder — but the view could
    /// still render a string of its own. Every `L10n.string(` in
    /// `LostConnectionView` must take its arguments from `content`, never a
    /// literal.
    ///
    /// Checked on stripped source, where a string literal has become a
    /// space: a hardcoded label reads as `L10n.string( , )`, while
    /// `L10n.string(content.title.key, …)` still starts with an identifier
    /// character. So the test is simply that no `L10n.string(` is followed
    /// by whitespace.
    @Test func theLostSurfaceRendersNoStringOfItsOwn() throws {
        let body = try Self.strippedBody(
            after: "private struct LostConnectionView: View", in: Self.detailFile)
        #expect(body.contains("L10n.string("), "the surface renders no localized text at all?")
        let literals = Self.localizedCallsWithALiteralArgument(in: body)
        #expect(literals.isEmpty, """
            `LostConnectionView` passes a string literal to `L10n.string(`: \(literals). Every \
            string on this surface has to come through `LostConnectionContent`, or the \
            guarantee that it can only show a fixed, enumerated set of catalog keys — and \
            therefore no host name, server message or typed value — covers only the part that \
            happens to go through the plan.
            """)
    }

    /// The literal reader, on every shape the two surface tests depend on
    /// — including the wrapped one that defeated the line-based version.
    @Test func theLiteralReaderSeesAWrappedCallTheSameAsAnInlineOne() throws {
        let stripped = try Self.stripCommentsAndStrings("""
            Text(L10n.string(content.title.key, content.title.fallback))
            Text(L10n.string(
                content.body.key,
                content.body.fallback))
            Text(L10n.string(nested(a, b), content.body.fallback))
            """)
        #expect(Self.localizedCallsWithALiteralArgument(in: stripped).isEmpty, """
            a call whose arguments are identifier paths must pass however it is wrapped, and \
            a nested call's own comma must not be read as an argument separator: \
            \(Self.localizedCallsWithALiteralArgument(in: stripped))
            """)

        let inlineLiteral = try Self.stripCommentsAndStrings("""
            Text(L10n.string("connection.failed.close", "Close"))
            """)
        #expect(Self.localizedCallsWithALiteralArgument(in: inlineLiteral).count == 1)

        // The measured escape: identical call, wrapped.
        let wrappedLiteral = try Self.stripCommentsAndStrings("""
            Text(L10n.string(
                "connection.failed.body",
                "Host: prod-db.internal"))
            """)
        #expect(Self.localizedCallsWithALiteralArgument(in: wrappedLiteral).count == 1, """
            a hardcoded label wrapped onto the next line is invisible to a line-based check, \
            and it is what actually put raw text on the surface with the whole suite green.
            """)

        // A literal in the SECOND position only — the shape a check that
        // looked at the first argument alone would wave through.
        let literalFallback = try Self.stripCommentsAndStrings("""
            Text(L10n.string(content.body.key, "Host: prod-db.internal"))
            """)
        #expect(Self.localizedCallsWithALiteralArgument(in: literalFallback).count == 1)
    }

    /// Runs the detectors over synthetic source the way the real scan does,
    /// window and all.
    private static func flaggedLines(in source: String) throws -> [String] {
        let detectors = try chokePointDetectors()
        let lines = try stripCommentsAndStrings(source)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { normalized(String($0)) }
        return lines.enumerated().compactMap { index, code in
            let window = index > 0 ? lines[index - 1] + " " + code : code
            return chokePoint(in: code, window: window, detectors: detectors) != nil ? code : nil
        }
    }

    /// Self-test on synthetic source: the scan must reject a dial it has
    /// not been told about, accept the sanctioned spelling, and — the case
    /// round 2 shipped broken — see a dial spelled as an UNAPPLIED method
    /// reference, which has no paren anywhere.
    @Test func theScanSeesEveryWayADialCanBeSpelled() throws {
        let flagged = try Self.flaggedLines(in: """
            // if let fs = await form.connect() {
            let harmless = tab.liveness == .connected
            let alsoHarmless = surface == .connecting
            if let fs = await form.connect() {
            Task { _ = await tab.connectionViewModel.connect() }
            let dial = tab.connectionViewModel.connect
            let handRolled = try await SSHClient.connect(host: h, hostKeyValidator: .acceptAnything())
            let client = SSHClient.self
            tab.session = BrowserSession.init(id: id)
            let viaImplicitSelf = await connect()
            let unqualifiedReference = connect
            async let dialed = tab.connectionViewModel.connect()
            let viaTheEntryPoint = try await BackendDescriptor.openConnection(c, hostKey: d, certificate: d, timeoutSeconds: 30)
            """)

        #expect(!flagged.contains { $0.contains("harmless") }, """
            `.connected`/`.connecting` must not match the `connect` pattern, or every liveness \
            comparison in the App layer would need a sanction: \(flagged)
            """)
        #expect(flagged.contains("let dial = tab.connectionViewModel.connect"), """
            an unapplied method reference is invisible to the scan — this is the exact evasion \
            round 2 shipped, where the only difference from a caught line was a paren.
            """)
        #expect(flagged.contains("if let fs = await form.connect() {"))
        #expect(flagged.contains("Task { _ = await tab.connectionViewModel.connect() }"))
        #expect(
            flagged.contains(
                "let handRolled = try await SSHClient.connect(host: h, hostKeyValidator: .acceptAnything())"),
            """
            the dial macSCP's own access levels do NOT stop. `CitadelFileSystem.connect(config, \
            decider)` stood here until every backend's `connect` became module-internal, and it \
            no longer compiles from this target; a raw transport dial does, and it reaches no \
            TOFU at all. A probe that only proves sensitivity to a violation nobody can write \
            makes this suite look stronger than it is.
            """)
        #expect(flagged.contains("let client = SSHClient.self"))
        #expect(flagged.contains("tab.session = BrowserSession.init(id: id)"), """
            an `.init` spelling must be seen the same as a `(` one.
            """)
        #expect(flagged.contains("let viaImplicitSelf = await connect()"), """
            a dial written with Swift's implicit `self` — which is what an `extension \
            ConnectionViewModel` in the App layer gets for free — has no dot anywhere, and \
            round 4's pattern required one. This is the spelling that defeated the whole \
            suite while bypassing `fillForm`, the plaintext confirmation, `startSession`, \
            the audit recorder and both hand-off locks.
            """)
        #expect(flagged.contains("let unqualifiedReference = connect"), """
            the same shape unapplied: no dot AND no paren.
            """)
        #expect(
            flagged.contains("async let dialed = tab.connectionViewModel.connect()"),
            """
            an `async let` dial was excused as a synchronous call. `async let` calls an `async` \
            function without ever writing `await`, which is round 6's measured escape: a dial \
            in a brand-new App-layer file compiled and left the whole suite green. Round 6 \
            spelled it as the descriptor's own closure, which no longer compiles from this \
            target; this line is a spelling that does, and it goes around `fillForm`, the \
            plaintext confirmation, `startSession`, the audit recorder and both hand-off locks \
            exactly as that one did.
            """)
        #expect(
            flagged.contains(
                "let viaTheEntryPoint = try await BackendDescriptor.openConnection(c, hostKey: d, certificate: d, timeoutSeconds: 30)"),
            """
            the name Core's dial actually goes by now. `openConnection` contains no lowercase \
            `connect`, so the pattern that had been catching every dial in this project \
            stopped seeing the only one left — and an allow-list scan that matches nothing \
            reports success.
            """)
        #expect(flagged.count == 10, "expected exactly the ten real hits, found \(flagged)")
    }

    /// The other direction, and the one round 3 got wrong: ordinary code
    /// that merely reads like a dial must NOT be flagged. Every line here
    /// was measured as a false positive by the review — a local variable
    /// whose name ends in `FileSystem`, an unrelated `session` property,
    /// and Combine's synchronous `connect()`. A guard that cries wolf on
    /// code like this is a guard the next person switches off, and then it
    /// protects nothing.
    @Test func ordinaryCodeIsNotMistakenForADial() throws {
        let flagged = try Self.flaggedLines(in: """
            let remoteFileSystem = fs
            let myLocalFileSystem = LocalFileSystem()
            self.session = URLSession.shared
            let task = URLSession.shared.dataTask(with: request)
            cancellable = publisher.connect()
            let connected = liveness == .connected
            if state == .connecting { return }
            reconnect(tab)
            retryConnect(tab)
            func connect(
            connect(in: tab, stored: stored)
            connect(in: target, stored: stored, paneVisibility: .terminalOnly)
            func mount() async {
            cancellable = publisher.connect()
            """)
        #expect(flagged.isEmpty, """
            ordinary code was flagged as touching a dial choke point: \(flagged)
            """)
        // `reconnect(tab)` and `retryConnect(tab)` never match at all: the
        // lookbehind rejects a preceding identifier character. `func
        // connect(` and both `connect(in:...)` callers — the App layer's
        // own funnel, `ContentView.connect(in:stored:)` — are the price of
        // widening the pattern from `\.connect` to the bare identifier
        // (round 5): they DO match it, and are cleared by the
        // discrimination instead, because each is applied and does not
        // suspend.
        //
        // `func mount() async {` and the `cancellable =
        // publisher.connect()` inside its body are the false positive
        // round 6's `async let` fix had to avoid buying: `async` and `let`
        // are adjacent TOKENS there, but a brace stands between them, so a
        // Combine `connect()` opening the body of an `async` function is
        // still read as the synchronous call it is.
    }

    /// …but the narrowing must not have gone so far that the real thing
    /// slips through alongside it. Each line here is the dangerous twin of
    /// one above.
    @Test func theNarrowingDidNotLetTheRealThingThrough() throws {
        let flagged = try Self.flaggedLines(in: """
            let fs = CitadelFileSystem.self
            self.session = BrowserSession(id: id)
            tab.session = otherTab.session
            tab.session = nil
            async let fs = publisher.connect()
            let fs = await publisher.connect()
            """)
        #expect(flagged.contains("async let fs = publisher.connect()"), """
            the `async let` twin of the Combine call above was excused: it is applied and \
            writes no `await`, which is exactly what round 6 measured slipping past.
            """)
        #expect(flagged.count == 6, """
            a dangerous line was excused by the narrowing that cleared the false positives: \
            \(flagged)
            """)
    }

    /// The `await` that belongs to a wrapped call sits on the line above
    /// it. Without the window, splitting the line would excuse the dial.
    @Test func anAwaitOnTheWrappedLineAboveStillCounts() throws {
        let flagged = try Self.flaggedLines(in: """
            let fs = try await form
                .connect()
            """)
        #expect(flagged.contains(".connect()"), """
            a dial whose `await` wrapped onto the previous line was excused: \(flagged)
            """)
    }

    /// Fail-closed self-test, the exact shape a re-review measured as a
    /// gap in this suite: `stripCommentsAndStrings` did not know Swift's
    /// raw-string delimiters (`#"…"#`). `#"""#` — an entirely ordinary
    /// literal for one quote character — desynchronized the plain-quote
    /// counting instead, reading it as one opening quote, one closing
    /// quote, and a fresh string that swallowed everything up to the next
    /// real `"` in the file. Measured: a real backend dial with
    /// accept-anything host-key deciders, sitting after such a line in a
    /// brand-new App-layer file, vanished from the scan along with it, and
    /// all 38 tests in this suite passed GREEN. The fix must throw instead
    /// of silently reading less than the source it claims to have checked.
    @Test func theScanFailsClosedOnARawStringDelimiterRatherThanHidingWhatFollowsIt() {
        let source =
            "static let quote = #\"\"\"#\n"
            + "async let dialed = tab.connectionViewModel.connect()"
        #expect(throws: (any Error).self) {
            _ = try Self.flaggedLines(in: source)
        }
    }

    /// The other half of the same proof: with the raw-string line gone,
    /// the identical dial must still be caught. The fix must not have
    /// traded a silent truncation for a blanket refusal that also
    /// swallows source that never had a raw string in it.
    @Test func theControlDialIsStillCaughtOnceTheRawStringIsGone() throws {
        let flagged = try Self.flaggedLines(
            in: "async let dialed = tab.connectionViewModel.connect()")
        #expect(flagged.contains("async let dialed = tab.connectionViewModel.connect()"))
    }

    /// Fail-closed self-test: a string or block comment that never closes
    /// must not be treated as "closed at end of file" — that is the same
    /// truncation risk under a different cause, and just as capable of
    /// hiding whatever comes after it.
    @Test func theScanFailsClosedOnAnUnterminatedLiteral() {
        #expect(throws: (any Error).self) {
            _ = try Self.flaggedLines(in: "let x = \"unterminated")
        }
        #expect(throws: (any Error).self) {
            _ = try Self.flaggedLines(in: "/* never closes")
        }
    }

    /// Nothing may enter these targets that is not on `permittedImports` —
    /// a hand-rolled dial has to reach a transport somehow, and this is the
    /// door it would come through.
    /// Swift's import grammar has three forms, and round 3 understood one:
    ///
    /// - `import Foundation`
    /// - `import Foundation.NSString` — a submodule
    /// - `import struct Foundation.Decimal` — an import KIND
    ///   (`typealias`/`struct`/`class`/`enum`/`protocol`/`let`/`var`/`func`)
    ///   followed by the declaration's path
    ///
    /// The third read as a module named `struct`, and the failure message
    /// then told the developer to add `struct` to `permittedImports` —
    /// after which `import struct Citadel.SSHClient` would have passed. A
    /// remediation that opens the hole it was guarding is worse than no
    /// message at all, which is why the kind is now consumed and the FIRST
    /// path component — the actual module — is what gets checked.
    private static let importPattern =
        #"(?<![A-Za-z0-9_])import\s+(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?([A-Za-z_]\w*)"#

    @Test func everyImportIsPermitted() throws {
        var seen: Set<String> = []
        var forbidden: [String] = []
        for file in try Self.appSwiftFiles() {
            let stripped = try Self.stripCommentsAndStrings(
                try String(contentsOf: file, encoding: .utf8))
            for module in try Self.importedModules(in: stripped) {
                seen.insert(module)
                if !Self.permittedImports.contains(module) {
                    forbidden.append("\(Self.relativePath(of: file)): import \(module)")
                }
            }
        }
        #expect(forbidden.isEmpty, """
            module(s) imported into the GUI targets that are not on the allow-list:
            \(forbidden.joined(separator: "\n"))

            A transport library reaching the App layer is how a dial that goes around \
            `ContentView.connect(in:stored:)` gets built. If this really is a new dependency \
            of the App layer, add it to `permittedImports` and expect that addition to be \
            read as the decision it is.
            """)
        let stale = Self.permittedImports.subtracting(seen)
        #expect(stale.isEmpty, """
            \(stale.sorted()) are on `permittedImports` but imported nowhere. An allowance for \
            something that does not exist is a lie about the code — remove them.
            """)
    }

    // MARK: - Delegation claims
    //
    // Narrower than the scan above and kept alongside it: the scan proves
    // nothing dials outside the sanctioned sites, these prove the surfaces
    // and the schedule still ASK the plain functions whose behaviour
    // `ReconnectPlanTests` pins.

    private static let reconnectAnchor = "func reconnect(_ tab: SessionTab)"
    private static let retryAnchor = "func retryConnect(_ tab: SessionTab)"
    private static let failedBranchAnchor =
        "// Failed-connect surface branch (failed-connect surface plan, Task 3)"
    private static let lostBranchAnchor = "// Lost surface branch (connection-liveness plan, Task 7)"
    private static let runnerAnchor = "struct ReconnectRunner: View"
    private static let runnerMountAnchor = "// Unattended reconnect (Task 7)"
    private static let mirrorWriteAnchor = "// Liveness mirror write (connection-liveness plan, Task 7)"
    private static let mirrorAnchor = "struct ConnectAttemptLivenessMirror: View"
    private static let indicatorAnchor = "private var indicator: TabIndicatorPlan.Indicator"

    private enum ScanError: Error, Equatable, CustomStringConvertible {
        case anchorNotFound
        case openBraceNotFound
        case unbalancedBraces
        case symbolicLinkInSources([String])
        case unrecognizedStringDelimiter
        case unterminatedLiteral

        var description: String {
            switch self {
            case .anchorNotFound: return "anchor not found"
            case .openBraceNotFound: return "no opening brace after the anchor"
            case .unbalancedBraces: return "unbalanced braces"
            case .symbolicLinkInSources(let paths):
                return """
                    symbolic link(s) in the scanned sources: \(paths). A symlinked DIRECTORY \
                    is compiled into the target but is not descended into by the walk, and it \
                    does not report itself as a directory either — so its contents are neither \
                    scanned for dials nor reported as an unscanned root. Replace the link with \
                    a real directory, or teach this suite to resolve it deliberately and decide \
                    what a link pointing outside the repository means for `sanctionedSites`' \
                    repo-relative paths.
                    """
            case .unrecognizedStringDelimiter:
                return """
                    unrecognized string delimiter (a raw string's `#"`, `##"`, …) — this \
                    stripper does not parse raw strings and refuses to guess where one ends
                    """
            case .unterminatedLiteral:
                return "unterminated string or comment literal"
            }
        }
    }

    private static let contentViewFile = file("Sources/MacSCPAppKit/ContentView.swift")
    private static let detailFile = file("Sources/MacSCPAppKit/ContentView+Detail.swift")
    private static let tabStripFile = file("Sources/MacSCPAppKit/TabStripView.swift")

    @Test func theReconnectDialsThroughTheSharedConnect() throws {
        let body = try Self.strippedBody(after: Self.reconnectAnchor, in: Self.contentViewFile)
        #expect(body.contains("connect(in: tab, stored: stored)"), """
            `ContentView.reconnect(_:)` no longer calls `connect(in:stored:)`.
            """)
    }

    /// The failed-connect surface's "Try again" (failed-connect surface
    /// plan, Task 3) reaches the wire the same single way everything else
    /// does. The whole security argument for adding a retry control at all
    /// is that it adds no dial: TOFU stays a hard stop, the keychain and
    /// login-set rules stay `fillForm`'s, and the plaintext confirmation
    /// still gets asked, because this function delegates rather than
    /// dialling. The allow-list scan above is the half that catches a dial
    /// written ANYWHERE in the App layer; this is the half that catches
    /// this function quietly ceasing to delegate at all.
    @Test func theRetryDialsThroughTheSharedConnect() throws {
        let body = try Self.strippedBody(after: Self.retryAnchor, in: Self.contentViewFile)
        #expect(body.contains("connect(in: tab, stored: stored)"), """
            `ContentView.retryConnect(_:)` no longer calls `connect(in:stored:)`.
            """)
    }

    /// The site the first version of this suite missed entirely: the
    /// schedule reaches the shared path through this mount's `onAttempt`,
    /// not through anything in `reconnect(_:)`'s own neighbourhood.
    @Test func theRunnerMountRoutesItsAttemptThroughReconnect() throws {
        let body = try Self.strippedBody(after: Self.runnerMountAnchor, in: Self.detailFile)
        #expect(body.contains("onAttempt: { reconnect($0) }"), """
            the `ReconnectRunner` mount no longer routes its attempt through `reconnect(_:)`. \
            This is the line the reviewer replaced with a direct dial: it compiled, it \
            bypassed `fillForm`, the teardown, both hand-off locks, `startSession` and the \
            audit recorder, and the suite stayed green.
            """)
    }

    @Test func theLostBranchRendersThePlansContent() throws {
        let body = try Self.strippedBody(after: Self.lostBranchAnchor, in: Self.detailFile)
        #expect(body.contains("surface == .lost"), """
            the lost branch no longer tests `surface == .lost` — the surface choice must stay \
            `ConnectionSurfacePlan.surface`'s answer.
            """)
        #expect(body.contains("LostConnectionPlan.content("), """
            the lost branch no longer asks `LostConnectionPlan.content(`.
            """)
    }

    @Test func theLostBranchRoutesBothButtonsToTheirRealHandlers() throws {
        let body = try Self.strippedBody(after: Self.lostBranchAnchor, in: Self.detailFile)
        #expect(body.contains("reconnect(tab)"), """
            the lost surface's Reconnect button no longer calls `reconnect(tab)`.
            """)
        #expect(body.contains("dismissLostConnection(tab)"), """
            the lost surface's dismissal no longer calls `dismissLostConnection(tab)` — \
            clearing only one of `liveness`/`lostConnection` inline would leave either the \
            surface up or an unattended schedule running behind the form.
            """)
    }

    @Test func theFailedBranchRendersThePlansContent() throws {
        let body = try Self.strippedBody(after: Self.failedBranchAnchor, in: Self.detailFile)
        #expect(body.contains("surface == .failed"), """
            the failed-connect branch no longer tests `surface == .failed` — the surface \
            choice must stay `ConnectionSurfacePlan.surface`'s answer, which is where the \
            rule that a pending host-key prompt overrides every surface lives.
            """)
        #expect(body.contains("ConnectFailurePlan.content("), """
            the failed-connect branch no longer asks `ConnectFailurePlan.content(` — which \
            action appears for which state would then be decided in a view body no test in \
            this project can render.
            """)
    }

    /// Every one of the four actions goes to the function that owns it,
    /// rather than to an inline reimplementation. Named individually
    /// because "the surface has four buttons" is not the property — the
    /// property is that each button reaches the same code the rest of the
    /// app reaches for that action.
    @Test func theFailedBranchRoutesAllFourActionsToTheirRealHandlers() throws {
        let body = try Self.strippedBody(after: Self.failedBranchAnchor, in: Self.detailFile)
        #expect(body.contains("retryConnect(tab)"), """
            the failed-connect surface's Retry no longer calls `retryConnect(tab)` — the one \
            function that routes it through the shared `connect(in:stored:)`.
            """)
        #expect(body.contains("dismissConnectFailure(tab)"), """
            the failed-connect surface's Edit no longer calls `dismissConnectFailure(tab)`.
            """)
        #expect(body.contains("editFailedSession(tab)"), """
            the failed-connect surface's "Edit session" no longer calls \
            `editFailedSession(tab)`, which is what routes it through the same `editStored` \
            the sidebar's own Edit uses.
            """)
        #expect(body.contains("requestClose(tab)"), """
            the failed-connect surface's Close no longer calls `requestClose(tab)` — closing \
            a tab any other way skips the active-transfer confirmation.
            """)
    }

    /// Where the details dialog's text comes from, which is the one place
    /// on this branch a raw error string reaches a surface at all.
    ///
    /// It must be the message `ConnectionViewModel` published — the text
    /// the connection form has always shown, whose producing sites this
    /// branch's groundwork task audited and repaired. Reaching around that
    /// for a rawer form would put text on screen no audit covered, and
    /// `String(describing:)` over a thrown error is precisely how that
    /// would be spelled.
    @Test func theDetailsDialogShowsWhatTheViewModelPublished() throws {
        let body = try Self.strippedBody(after: Self.failedBranchAnchor, in: Self.detailFile)
        #expect(body.contains("ConnectFailureDetailText.read("), """
            the failed-connect branch no longer asks `ConnectFailureDetailText.read(` for the \
            dialog's text.
            """)
        #expect(body.contains("from: tab.connectionViewModel.state"), """
            the details text is no longer taken from `tab.connectionViewModel.state` — the \
            published failure is the only text this dialog may show.
            """)
        #expect(!body.contains("String(describing:"), """
            the failed-connect branch now builds a description of its own. The details dialog \
            shows what the layer below published and nothing richer; a `String(describing:)` \
            of a thrown error or a config is text no audit of the producing sites covered.
            """)
    }

    /// The half of the details guarantee a compiler cannot hold.
    ///
    /// `ConnectFailureDetailText.text` is `fileprivate`, so
    /// `ConnectFailureView` — which lives in another file — cannot NAME
    /// it: both spellings of the measured mutation (`Text(details ?? …)`
    /// and `Text(details?.text ?? …)`) fail to compile. What round 1 of
    /// this test claimed, and what the review then measured, is that this
    /// makes rendering the text a compile error full stop. It does not:
    /// `Text(String(describing: details))` compiled and left the whole
    /// suite green, because reflection reads storage without naming it.
    ///
    /// That is now closed at the type — `CustomStringConvertible`,
    /// `CustomDebugStringConvertible` and `CustomReflectable` answer with
    /// a placeholder — and `ConnectFailurePlanTests
    /// .reflectionDoesNotHandBackTheMessage` is the check that they do,
    /// behaviourally, by looking for a known message in the output.
    ///
    /// What is left for a scan is this file's shape, which is the one
    /// thing neither the compiler nor that behavioural test can hold: an
    /// edit HERE can widen the type again, and nothing about that edit
    /// would be objectionable to the type system. Two halves, and the
    /// promise is exactly what the code below does, no wider:
    ///
    /// 1. The storage stays `fileprivate let text: String`, and the three
    ///    reflection answers stay the placeholder rather than the message
    ///    — each pinned as the literal declaration it is.
    /// 2. `var text` and `func text` are banned outright, as the two
    ///    spellings of re-exporting the storage under its own name. That
    ///    is a ban on TWO SPELLINGS, not on the idea: `var raw: String {
    ///    text }` or `func message() -> String { text }` walks past it,
    ///    and saying otherwise here (this test used to promise "a
    ///    `String`-returning `func`") would be the same overclaim the
    ///    round-1 comment made about `fileprivate`.
    @Test func theDetailsTextHasNoWayOutOfItsOwnFile() throws {
        let file = Self.file("Sources/MacSCPAppKit/ConnectFailureDetails.swift")
        let stripped = try Self.stripCommentsAndStrings(
            try String(contentsOf: file, encoding: .utf8))
        #expect(stripped.contains("fileprivate let text: String"), """
            `ConnectFailureDetailText`'s storage is no longer `fileprivate let text: String`. \
            That declaration is what keeps the raw text from being NAMED outside this file.
            """)
        // The three generic routes to a string, each pinned as the
        // literal that answers it. Counted here: three required
        // declarations, one per protocol the type conforms to for this
        // reason.
        for required in [
            "var description: String { Self.placeholder }",
            "var debugDescription: String { Self.placeholder }",
            "var customMirror: Mirror { Mirror(self, children: []) }",
        ] {
            #expect(stripped.contains(required), """
                `ConnectFailureDetails.swift` no longer declares `\(required)`. Without it a \
                generic conversion — `String(describing:)`, an interpolation, \
                `String(reflecting:)` or `dump(_:)` — falls back to a `Mirror` over the \
                storage and prints the server's own message, which is the measured bypass \
                this declaration exists to close.
                """)
        }
        for escape in ["var text", "func text"] {
            #expect(!stripped.contains(escape), """
                `ConnectFailureDetails.swift` now contains `\(escape)`, which hands the raw \
                error text back to the whole module under its own name — and with it the \
                shape that put a server's own message on the general surface with the suite \
                green.
                """)
        }
    }

    /// The same last gap `theLostSurfaceRendersNoStringOfItsOwn` closes, for
    /// this surface: the allow-list pins that one function builds the
    /// content, but the view could still render a literal of its own beside
    /// it, and then the enumerable-keys claim would cover only the part
    /// that happens to go through the plan.
    ///
    /// Scoped to `ConnectFailureView` and NOT to the details dialog, on
    /// purpose: the dialog's whole body is a raw string by design, and it
    /// dismisses itself with the shared `common.ok` label the rest of the
    /// app uses.
    @Test func theFailedSurfaceRendersNoStringOfItsOwn() throws {
        let body = try Self.strippedBody(
            after: "private struct ConnectFailureView: View", in: Self.detailFile)
        #expect(body.contains("L10n.string("), "the surface renders no localized text at all?")
        let literals = Self.localizedCallsWithALiteralArgument(in: body)
        #expect(literals.isEmpty, """
            `ConnectFailureView` passes a string literal to `L10n.string(`: \(literals). Every \
            string on this surface has to come through `ConnectFailureContent`, or the \
            guarantee that it can only show a fixed, enumerated set of catalog keys — and \
            therefore no host name, server message or typed value — covers only the part that \
            happens to go through the plan.
            """)
        // The measured third bypass, kept out of this body as well as
        // answered by the type: `Text(String(describing: details))`
        // compiles, and before `ConnectFailureDetailText` grew its own
        // reflection answers it printed the server's message. Belt beside
        // braces, and worth being exact about which is which — this line
        // is the belt, `ConnectFailurePlanTests
        // .reflectionDoesNotHandBackTheMessage` is the braces.
        //
        // The stripper blanks string literals whole, interpolations
        // included, so `Text("\(details)")` is invisible HERE. That
        // spelling is covered by the placeholder alone, which is the
        // reason the placeholder and not this line is the load-bearing
        // half.
        #expect(!body.contains("String(describing:"), """
            `ConnectFailureView` builds a description of a value of its own. The general \
            surface shows fixed catalog keys and nothing else; the technical text belongs in \
            the dialog, one click away, and reaching for it here is how it stopped being \
            one click away once already.
            """)
    }

    @Test func theRunnerAsksTheReconnectPlan() throws {
        let body = try Self.strippedBody(after: Self.runnerAnchor, in: Self.detailFile)
        #expect(body.contains("ReconnectPlan.step("), """
            `ReconnectRunner` no longer calls `ReconnectPlan.step(` — a schedule \
            reimplemented inside this view would drift from the behaviours \
            `ReconnectPlanTests` pins, including the rule that an attempt needing a person is \
            never repeated unattended.
            """)
        #expect(body.contains("Task.sleep"), """
            `ReconnectRunner` no longer sleeps — an attempt fired without the backoff the \
            plan hands it is a retry storm, not a schedule.
            """)
    }

    @Test func theRunnerCountsTheAttemptAndFiresIt() throws {
        let body = try Self.strippedBody(after: Self.runnerAnchor, in: Self.detailFile)
        #expect(body.contains("automaticAttempts += 1"), """
            `ReconnectRunner` no longer counts the attempt — `ReconnectPlan.step` paces \
            itself by that count.
            """)
        #expect(body.contains("onAttempt(tab)"), """
            `ReconnectRunner` no longer calls `onAttempt(tab)` — the schedule would run and \
            nothing would be dialed.
            """)
    }

    @Test func theLivenessMirrorAsksItsPlan() throws {
        let body = try Self.strippedBody(after: Self.mirrorWriteAnchor, in: Self.detailFile)
        #expect(body.contains("ConnectAttemptLivenessPlan.write("), """
            `ConnectAttemptLivenessMirror` no longer asks `ConnectAttemptLivenessPlan.write(`.
            """)
        #expect(body.contains("tab.lostConnection?.reason = reason"), """
            the mirror no longer writes back the reason the plan derived — the reconnect \
            schedule reads `lostConnection.reason`, so without this write an attempt that \
            stopped at a host key or a passphrase would keep being repeated unattended.
            """)
    }

    /// The two writes the failed-connect surface depends on, pinned the
    /// same way the reason write-back above is: this mirror is a SwiftUI
    /// `.onChange` closure, and nothing in this project renders one, so a
    /// scan of its stripped source is the only check there can be that it
    /// still performs them.
    ///
    /// Both are load-bearing and neither is visible from the plain
    /// functions the suites around it drive.
    /// `ConnectAttemptLivenessPlan.write` can answer `.failedConnect`
    /// forever without a surface ever appearing, if the mirror stops
    /// recording it; and reading the origin off the attempt is what keeps a
    /// stored session dialed earlier from being offered for editing after
    /// a LATER ad-hoc attempt fails.
    ///
    /// This test had a THIRD expectation until M3, pinning a line that
    /// cleared the origin whenever the state left `.connecting`. That line
    /// is gone, and so is the property it cleared: the origin now lives on
    /// `ConnectionViewModel.attemptOrigin`, assigned with the attempt and
    /// `private(set)`, so the App layer cannot write one early and there is
    /// nothing left for a clear to catch. The expectation was not dropped
    /// for a weaker one — it was replaced by a boundary that will not
    /// compile, which is the trade this project's own rule about scans that
    /// keep buying a spelling asks for.
    @Test func theLivenessMirrorRecordsTheFailedAttemptWithTheOriginOfThatAttempt() throws {
        // The WHOLE mirror, not just its `switch` (round 1 of this test,
        // measured): `mirrorWriteAnchor`'s body is brace-matched from the
        // switch's own `{`, so it ends at the switch.
        let body = try Self.strippedBody(after: Self.mirrorAnchor, in: Self.detailFile)
        #expect(body.contains("tab.connectFailure = ConnectFailure("), """
            the mirror no longer records the failed attempt on the tab — `ConnectionSurfacePlan` \
            reads `tab.connectFailure` and nothing else to put that surface up, so the tab \
            would fall back to the form exactly as it did before this task.
            """)
        #expect(body.contains("storedSessionID: tab.connectionViewModel.attemptOrigin"), """
            the recorded failure no longer carries the origin of the attempt that failed, so \
            "Edit session" would never be offered — or, worse, would be offered for whatever \
            the mirror reads instead.
            """)
    }

    @Test func theTabIndicatorAsksItsPlanAndHandsItTheLiveness() throws {
        let body = try Self.strippedBody(after: Self.indicatorAnchor, in: Self.tabStripFile)
        #expect(body.contains("TabIndicatorPlan.indicator("), """
            `TabItemView.indicator` no longer calls `TabIndicatorPlan.indicator(`.
            """)
        #expect(body.contains("liveness: tab.liveness,"), """
            `TabItemView.indicator` no longer threads `tab.liveness` into the plan.
            """)
    }

    /// A substring check on `liveness: tab.liveness` is satisfied by
    /// `liveness: tab.liveness == .lost ? nil : tab.liveness`, which passes
    /// the plan a value that can never trigger the suppression — the
    /// "keep the spelling, change the behaviour" shape this branch has been
    /// bitten by repeatedly. The real body contains no `?` at all: no
    /// ternary, no optional chaining, no optional type. Banning the
    /// character is crude, and deliberately so — if this property ever
    /// genuinely needs one, that is a change worth stopping at.
    @Test func theTabIndicatorPassesItsArgumentsUnconditioned() throws {
        let body = try Self.strippedBody(after: Self.indicatorAnchor, in: Self.tabStripFile)
        #expect(!body.contains("?"), """
            `TabItemView.indicator` now contains a `?`. A ternary or an optional here can \
            neutralize a value while still spelling out the argument that carries it — check \
            what is actually reaching `TabIndicatorPlan` before widening this guard.
            """)
        #expect(!body.contains("return .attention"), """
            `TabItemView.indicator` decides `.attention` itself again — that is the \
            pre-Task-7 body, which had no way to know about `.lost`.
            """)
    }

    @Test(arguments: [
        (reconnectAnchor, "Sources/MacSCPAppKit/ContentView.swift"),
        (retryAnchor, "Sources/MacSCPAppKit/ContentView.swift"),
        (failedBranchAnchor, "Sources/MacSCPAppKit/ContentView+Detail.swift"),
        (lostBranchAnchor, "Sources/MacSCPAppKit/ContentView+Detail.swift"),
        (runnerAnchor, "Sources/MacSCPAppKit/ContentView+Detail.swift"),
        (runnerMountAnchor, "Sources/MacSCPAppKit/ContentView+Detail.swift"),
        (mirrorWriteAnchor, "Sources/MacSCPAppKit/ContentView+Detail.swift"),
        (mirrorAnchor, "Sources/MacSCPAppKit/ContentView+Detail.swift"),
        (indicatorAnchor, "Sources/MacSCPAppKit/TabStripView.swift"),
    ])
    func everyAnchorAppearsExactlyOnceInItsRealFile(anchor: String, relativePath: String) throws {
        let source = try String(contentsOf: Self.file(relativePath), encoding: .utf8)
        let count = source.components(separatedBy: anchor).count - 1
        #expect(count == 1, """
            expected exactly 1 occurrence of `\(anchor)` in \(relativePath), found \(count) — \
            re-anchor this guard.
            """)
    }

    // MARK: - Scanner self-tests

    @Test func scannerThrowsWhenTheAnchorIsMissing() {
        #expect(throws: ScanError.anchorNotFound) {
            _ = try Self.strippedBody(after: Self.reconnectAnchor, in: "func somethingElse() {}")
        }
    }

    /// The exact mutation that defeated an earlier guard on this branch: a
    /// comment naming the call, with the real call deleted, must not
    /// satisfy the check.
    @Test func scannerIsNotFooledByACommentNamingTheCall() throws {
        let source = """
            func reconnect(_ tab: SessionTab) {
                // Goes through connect(in: tab, stored: stored), the shared path.
                dialSomethingElse()
            }
            """
        let body = try Self.strippedBody(after: Self.reconnectAnchor, in: source)
        #expect(!body.contains("connect(in: tab, stored: stored)"))
    }

    @Test func scannerIsNotFooledByAStringLiteralNamingTheCall() throws {
        let source = """
            func reconnect(_ tab: SessionTab) {
                log("connect(in: tab, stored: stored)")
                dialSomethingElse()
            }
            """
        let body = try Self.strippedBody(after: Self.reconnectAnchor, in: source)
        #expect(!body.contains("connect(in: tab, stored: stored)"))
    }

    @Test func stripperSelfTestRemovesLineAndBlockCommentsAndStringLiterals() throws {
        let source = #"""
            let a = "ReconnectPlan.step(" // ReconnectPlan.step(
            /* ReconnectPlan.step( */ let b = 1
            let c = """
                ReconnectPlan.step(
                """
            ReconnectPlan.step(
            """#
        let stripped = try Self.stripCommentsAndStrings(source)
        #expect(stripped.components(separatedBy: "ReconnectPlan.step(").count - 1 == 1, """
            expected exactly 1 real occurrence of `ReconnectPlan.step(` to survive stripping; \
            found \(stripped.components(separatedBy: "ReconnectPlan.step(").count - 1).
            """)
    }

    /// The stripper must not swallow line breaks, or the allow-list scan
    /// would see one enormous line and match nothing.
    @Test func stripperKeepsLineStructure() throws {
        let stripped = try Self.stripCommentsAndStrings("""
            let a = 1 /* a
            comment across lines */
            let b = "text"
            """)
        #expect(stripped.split(separator: "\n", omittingEmptySubsequences: false).count == 3)
    }

    // MARK: - Scanner

    /// Every Swift file the scan covers — and it refuses to answer at all
    /// while a symbolic link is in the way.
    ///
    /// `FileManager.enumerator(at:)` yields a symlinked DIRECTORY as an
    /// entry but does not descend into it, and `.isDirectoryKey` is `false`
    /// for that entry. Round 3 therefore neither scanned such a directory
    /// nor reported it as unknown: `Extras/Panels/Dial.swift`, linked in as
    /// `Sources/MacSCPAppKit/Panels`, compiled into the target with
    /// accept-anything deciders and a `startSession`, and left the suite
    /// green. A symlinked FILE was always caught; only directories slipped,
    /// which is the worst kind of gap — the walk reported success over less
    /// than it thought it was reading.
    ///
    /// Refusing rather than following, deliberately: a symlinked source
    /// directory is unusual enough that stopping with a clear message is a
    /// better outcome than quietly resolving it and scanning a path nobody
    /// declared. Following would also have to decide what to do about a
    /// link pointing outside the repository, where `sanctionedSites`'
    /// repo-relative paths stop meaning anything.
    private static func appSwiftFiles() throws -> [URL] {
        let links = try symbolicLinks(under: scannedRoots + [sourcesDirectory])
        guard links.isEmpty else { throw ScanError.symbolicLinkInSources(links) }
        var files: [URL] = []
        for root in scannedRoots {
            guard let walker = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: nil)
            else { throw ScanError.anchorNotFound }
            files += walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        }
        return files.sorted { $0.path < $1.path }
    }

    /// Every symbolic link at or under the given roots, in repo-relative
    /// form. Detected by the link's OWN metadata (`.isSymbolicLinkKey`,
    /// with `attributesOfItem` — `lstat` semantics — as the fallback), not
    /// by asking whether the target is a directory, which is exactly the
    /// question that answered `false` for a symlinked directory and let one
    /// through.
    ///
    /// Takes its roots as a parameter so
    /// `theSymlinkDetectorFindsALinkedDirectory` can drive it over a
    /// throwaway temporary tree, rather than the property being provable
    /// only by planting a symlink in the repository.
    private static func symbolicLinks(under roots: [URL]) throws -> [String] {
        var found: [String] = []
        for root in roots {
            guard let walker = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isSymbolicLinkKey],
                options: [.skipsSubdirectoryDescendants])
            else { continue }
            var candidates = walker.compactMap { $0 as? URL }
            // The immediate children above, plus everything below the
            // roots that are actually scanned — a link nested inside a real
            // subdirectory hides just as well as one at the top.
            if let deep = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isSymbolicLinkKey])
            {
                candidates += deep.compactMap { $0 as? URL }
            }
            for url in candidates where isSymbolicLink(url) {
                let relative = relativePath(of: url)
                if !found.contains(relative) { found.append(relative) }
            }
        }
        return found.sorted()
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        if let value = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink {
            return value
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    /// Compiled once per test that needs them, and `throws` rather than
    /// force-unwrapping: a pattern that fails to compile must fail the
    /// calling test loudly, not take the whole run down with it.
    private static func chokePointDetectors() throws -> [(regex: NSRegularExpression, point: ChokePoint)] {
        try chokePoints.map { (try NSRegularExpression(pattern: $0.pattern), $0) }
    }

    /// What choke point this line touches, if any — the description, so a
    /// failure message can say what was just done rather than which
    /// substring matched.
    ///
    /// `window` is the matched line together with the one before it, and is
    /// consulted only by `.unlessSynchronousCall`: Swift lets an `await`
    /// sit on a wrapped line above the call it belongs to. Two lines is the
    /// window, not the whole statement — see this suite's own "what this
    /// guard cannot see" list, which says so rather than implying more.
    private static func chokePoint(
        in line: String, window: String,
        detectors: [(regex: NSRegularExpression, point: ChokePoint)]
    ) -> String? {
        let range = NSRange(line.startIndex..., in: line)
        for detector in detectors
        where detector.regex.firstMatch(in: line, range: range) != nil {
            switch detector.point.discrimination {
            case .always:
                return detector.point.describes
            case .unlessSynchronousCall:
                if !isAppliedCall(of: detector.regex, in: line) || suspends(window) {
                    return detector.point.describes
                }
            }
        }
        return nil
    }

    /// Whether the match is immediately applied — `x.connect(` rather than
    /// the bare `x.connect` a method reference produces.
    private static func isAppliedCall(of regex: NSRegularExpression, in line: String) -> Bool {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = regex.firstMatch(in: line, range: range),
            let matchRange = Range(match.range, in: line)
        else { return false }
        let rest = line[matchRange.upperBound...].drop { $0 == " " }
        return rest.first == "("
    }

    /// Whether the window SUSPENDS — which is the question
    /// `.unlessSynchronousCall` actually wants answered, and is not the
    /// same question as "does the word `await` appear".
    ///
    /// Round 6, review-measured: the previous version asked only for
    /// `await`, and `async let dialed = BackendDescriptor.descriptor(for:
    /// config.kind).connect(config, { _ in true }, { _ in true }, 30)` — a
    /// raw backend dial with an accept-anything host-key decider, in a
    /// brand-new App-layer file — calls an `async` function without ever
    /// writing the word. It compiled and left the whole suite green. The
    /// controls run in the same pass were red (the same line with `await`,
    /// and a `Task.detached` around it), so the walk did reach the file;
    /// only the spelling escaped.
    ///
    /// That exact line no longer compiles: the closures are not deciders
    /// and the descriptor's `connect` is out of reach. `async let` is not
    /// history, though — a dial through a public Core function, which is
    /// what the App layer can still reach, suspends the same way and
    /// writes `await` just as little. The probe in
    /// `theScanSeesEveryWayADialCanBeSpelled` is spelled that way for
    /// exactly that reason.
    ///
    /// `async let` is matched as two WHITESPACE-separated words, not as
    /// two tokens somewhere in the window: `func f() async {` followed by
    /// a body that opens with `let x = publisher.connect()` has `async`
    /// and `let` adjacent in token order but a brace between them, and
    /// reading that as a suspension would reintroduce exactly the false
    /// positive `.unlessSynchronousCall` exists to clear.
    private static func suspends(_ text: String) -> Bool {
        if text.split(whereSeparator: { !$0.isLetter && $0 != "_" }).contains("await") {
            return true
        }
        let words = text.split(whereSeparator: { $0.isWhitespace })
        for (offset, word) in words.enumerated()
        where word == "async" && offset + 1 < words.count && words[offset + 1] == "let" {
            return true
        }
        return false
    }

    private static func relativePath(of file: URL) -> String {
        let root = repoRoot.path.hasSuffix("/") ? repoRoot.path : repoRoot.path + "/"
        return file.path.hasPrefix(root)
            ? String(file.path.dropFirst(root.count)) : file.path
    }

    /// Collapses every run of whitespace to one space and trims — so an
    /// allow-list entry survives reindentation and line rewrapping without
    /// surviving an actual change to the code on the line.
    /// Every `L10n.string(` in `body` that is handed a string literal,
    /// returned as the compacted call text.
    ///
    /// Round 5, review-measured: the previous check was `!body.contains(
    /// "L10n.string( ")` — a claim about ONE LINE. `stripCommentsAndStrings`
    /// turns a literal into a single space, so a hardcoded label reads as
    /// `L10n.string( , )` and was caught, but the identical call with its
    /// arguments wrapped onto the next line reads as `L10n.string(` followed
    /// by a NEWLINE and was green — with `Host: prod-db.internal` on the
    /// surface. Wrapping is not a semantic difference, and a check that a
    /// reformat can defeat is not a check.
    ///
    /// So this reads the CALL: whitespace is removed entirely, the argument
    /// list is taken by matching parentheses, and it is split at top-level
    /// commas. A blanked literal leaves an EMPTY argument in any position —
    /// `L10n.string(,)`, `L10n.string(key,)` — while every legitimate
    /// argument is an identifier path and survives compaction intact.
    /// Nesting is handled by the depth counter, so `L10n.string(key(a, b),
    /// fallback)` is not mistaken for three arguments.
    private static func localizedCallsWithALiteralArgument(in body: String) -> [String] {
        let compact = String(body.filter { !$0.isWhitespace })
        let token = "L10n.string("
        var found: [String] = []
        var searchStart = compact.startIndex
        while let hit = compact.range(of: token, range: searchStart..<compact.endIndex) {
            searchStart = hit.upperBound
            var depth = 1
            var arguments: [String] = []
            var current = ""
            var index = hit.upperBound
            while index < compact.endIndex, depth > 0 {
                let character = compact[index]
                if character == "(" { depth += 1 }
                if character == ")" {
                    depth -= 1
                    if depth == 0 { break }
                }
                if character == ",", depth == 1 {
                    arguments.append(current)
                    current = ""
                } else {
                    current.append(character)
                }
                index = compact.index(after: index)
            }
            // An unbalanced call means the scan read past the end of the
            // body — report it rather than silently deciding it is clean.
            guard depth == 0 else {
                found.append(token + current + "  <unbalanced>")
                break
            }
            arguments.append(current)
            if arguments.contains(where: \.isEmpty) {
                found.append(token + arguments.joined(separator: ",") + ")")
            }
        }
        return found
    }

    private static func normalized(_ line: String) -> String {
        line.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
    }

    private static func strippedBody(after anchor: String, in file: URL) throws -> String {
        let source = try String(contentsOf: file, encoding: .utf8)
        return try strippedBody(after: anchor, in: source)
    }

    /// Strips comments and string literals FIRST, then counts braces from
    /// the first `{` of the remaining text to its match, returning
    /// everything from the anchor through that close — the header included,
    /// since several claims are about a call in a `switch` subject or an
    /// `if` condition. Stripping first matters: a brace inside a comment
    /// would otherwise shift where the scanner believes the block ends.
    /// The anchor is found in the RAW source, because some anchors are `//`
    /// comments a global strip would delete first.
    private static func strippedBody(after anchor: String, in source: String) throws -> String {
        guard let anchorRange = source.range(of: anchor) else { throw ScanError.anchorNotFound }
        let stripped = try stripCommentsAndStrings(String(source[anchorRange.upperBound...]))
        guard let openBraceIndex = stripped.firstIndex(of: "{") else {
            throw ScanError.openBraceNotFound
        }
        var depth = 0
        var index = openBraceIndex
        while index < stripped.endIndex {
            let character = stripped[index]
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(stripped[stripped.startIndex...index])
                }
            }
            index = stripped.index(after: index)
        }
        throw ScanError.unbalancedBraces
    }

    /// Strips `//` and `/* */` comments and both `"..."` and `"""..."""`
    /// string literals, preserving line breaks so the allow-list scan can
    /// still work line by line. Measured necessary, not theoretical: a
    /// mutation that deleted a real call from this project's source once
    /// passed a guard because the surrounding doc comment named the method
    /// in prose.
    ///
    /// Handles `\"`-escaped quotes and nested `/* */` comments. Does not
    /// parse string interpolation — `\(...)` inside a literal is treated as
    /// string content, which can only make a check find LESS text, never
    /// invent a match that was not code.
    ///
    /// Fails closed: a raw-string delimiter (`#"…"#`) is a form this
    /// stripper does not parse, and an unterminated string or comment means
    /// it ran off the end of the file without finding what it was looking
    /// for. Both throw rather than return whatever was collected so far —
    /// the alternative is a scan that silently reads less than the file it
    /// claims to have checked. Measured necessary, not theoretical: an
    /// unhandled `#"""#` — an entirely ordinary raw-string literal for one
    /// quote character — desynchronized the plain-quote counting instead,
    /// reading it as one opening quote, one closing quote, and a fresh
    /// string that swallowed everything up to the next real `"` in the
    /// file, silently. A raw backend dial with accept-anything host-key
    /// deciders sitting past that point left the whole suite green.
    private static func stripCommentsAndStrings(_ source: String) throws -> String {
        var result = ""
        result.reserveCapacity(source.count)
        let chars = Array(source)
        var i = 0
        var blockCommentDepth = 0
        while i < chars.count {
            let c = chars[i]
            if blockCommentDepth > 0 {
                if c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                    blockCommentDepth += 1
                    i += 2
                    continue
                }
                if c == "*", i + 1 < chars.count, chars[i + 1] == "/" {
                    blockCommentDepth -= 1
                    i += 2
                    continue
                }
                result.append(c == "\n" ? "\n" : " ")
                i += 1
                continue
            }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                while i < chars.count, chars[i] != "\n" {
                    result.append(" ")
                    i += 1
                }
                continue
            }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                blockCommentDepth = 1
                i += 2
                continue
            }
            if c == "#" {
                var j = i
                while j < chars.count, chars[j] == "#" { j += 1 }
                if j < chars.count, chars[j] == "\"" {
                    throw ScanError.unrecognizedStringDelimiter
                }
            }
            if c == "\"", i + 2 < chars.count, chars[i + 1] == "\"", chars[i + 2] == "\"" {
                i += 3
                while i + 2 < chars.count,
                    !(chars[i] == "\"" && chars[i + 1] == "\"" && chars[i + 2] == "\"")
                {
                    result.append(chars[i] == "\n" ? "\n" : " ")
                    i += 1
                }
                guard i + 2 < chars.count else { throw ScanError.unterminatedLiteral }
                i += 3
                result.append(" ")
                continue
            }
            if c == "\"" {
                i += 1
                while i < chars.count, chars[i] != "\"" {
                    if chars[i] == "\\", i + 1 < chars.count { i += 2 } else { i += 1 }
                }
                guard i < chars.count else { throw ScanError.unterminatedLiteral }
                i += 1
                result.append(" ")
                continue
            }
            result.append(c)
            i += 1
        }
        guard blockCommentDepth == 0 else { throw ScanError.unterminatedLiteral }
        return result
    }
}
