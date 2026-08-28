import Darwin
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import Testing

@testable import macSCPCore

/// B-1's open question, measured rather than reasoned about: while a connect
/// to a host that never answers is in flight, does the main actor keep
/// running, or does it stop until the timeout fires?
///
/// The instrument is the same in every test here: a ticker `Task` pinned to
/// `@MainActor` that stamps `ContinuousClock.now` and sleeps briefly, over
/// and over. Its resumptions can only be scheduled by the main actor's own
/// executor, so a main actor that stops running produces a gap between two
/// consecutive stamps as long as the block. The verdict is therefore the
/// LARGEST gap, not the tick count — a tick count alone cannot tell a
/// blocked main actor apart from a slow one.
///
/// THE INSTRUMENT HAS A NOISE FLOOR, and it is large. Measured on
/// 2026-08-28 with a bare ticker and no dial of any kind in flight: a full
/// parallel `swift test` run (2923 tests, 256 suites) stalls its own main
/// actor for **4.7 seconds** in one stretch — `Task.sleep(20 ms)` resuming
/// four times in five seconds. That is the harness, not the product: ~256
/// suites, many of them `@MainActor`, all queueing onto one serial
/// executor. Run this suite alone and the same ticker shows a 30 ms
/// maximum.
///
/// So an absolute threshold on the gap is a coin flip in CI. Every negative
/// measurement below is therefore stated against `ambientGap(over:)` — the
/// same ticker, same process, moments earlier, with nothing under test —
/// and asserts only that the dial did not stall the main actor beyond what
/// this run was stalling it anyway. What keeps that from being a check that
/// can never fail is test 3, which blocks the main actor on purpose and
/// requires the gap to show up: the suite carries its own positive control.
///
/// `.serialized` is load-bearing, not tidiness: every test in here measures
/// the SAME main actor, and the third one deliberately blocks it. Run in
/// parallel, that block shows up as a gap in the other two tickers and fails
/// them — which is how the suite first ran, and is itself the sharpest
/// demonstration of what a blocking wait on the main actor costs everything
/// else scheduled on it.
@Suite("Connect against an unresponsive host: main-actor liveness", .serialized)
struct ConnectMainActorLivenessTests {

    // MARK: - The instrument

    /// Collects the ticker's stamps. Main-actor isolated, so the ticker
    /// writing and the test reading are the same executor and need no
    /// further synchronization.
    @MainActor
    private final class TickLog {
        private(set) var stamps: [ContinuousClock.Instant] = []

        func tick() { stamps.append(.now) }

        /// The longest interval between two consecutive resumptions — the
        /// measured stall of the main actor.
        var largestGap: Duration {
            guard stamps.count >= 2 else { return .seconds(0) }
            return zip(stamps, stamps.dropFirst())
                .map { $1 - $0 }
                .max() ?? .seconds(0)
        }
    }

    /// Starts a main-actor ticker and returns it once it has actually
    /// stamped at least once. The caller cancels the task when the
    /// measurement window closes.
    ///
    /// Waiting for that first stamp is not politeness — it closes one of the
    /// two ends through which a real stall can pass this instrument
    /// unrecorded. A gap exists only BETWEEN two stamps, so a block that
    /// begins before the ticker's first stamp is invisible, exactly as one
    /// that is still running when the ticker is cancelled is invisible. Both
    /// holes were found by planting a block and watching the suite stay
    /// green: the second one by round 1 of test 3, which reported a 25 ms
    /// maximum for a 400 ms block, and the first by a mutation run against
    /// test 2, which reported no gap at all for a 1500 ms one.
    @MainActor
    private func startTicker(every interval: Duration = .milliseconds(20))
        async -> (task: Task<Void, Never>, log: TickLog)
    {
        let log = TickLog()
        let task = Task { @MainActor in
            while !Task.isCancelled {
                log.tick()
                try? await Task.sleep(for: interval)
            }
        }
        while log.stamps.isEmpty { await Task.yield() }
        return (task, log)
    }

    /// Closes a measurement window: gives the ticker one more turn on the
    /// main actor before cancelling it, then cancels. The other end of the
    /// hole `startTicker` documents — a stall that is still running when the
    /// ticker is cancelled leaves no second stamp to be measured against,
    /// and reads exactly like no stall at all.
    @MainActor
    private func closeWindow(_ ticker: Task<Void, Never>) async {
        try? await Task.sleep(for: .milliseconds(60))
        ticker.cancel()
    }

    /// The main actor's own background stall in THIS process, right now,
    /// with nothing under test — the control every negative measurement in
    /// this suite is stated against. See the suite's doc comment for the
    /// 4.7-second reason it exists.
    @MainActor
    private func ambientGap(over window: Duration) async -> Duration {
        let (ticker, log) = await startTicker()
        try? await Task.sleep(for: window)
        await closeWindow(ticker)
        return log.largestGap
    }

    /// The ceiling a measured gap has to stay under to count as "the main
    /// actor kept running": the ambient noise, or 300 ms, whichever is
    /// larger. 300 ms is the floor for an uncontended run, where ambient is
    /// a few tens of milliseconds and a real block would be hundreds.
    private func ceiling(forAmbient ambient: Duration) -> Duration {
        max(ambient, .milliseconds(300))
    }

    // MARK: - 1. The boundary itself

    /// The load-bearing structural claim: `ConnectionViewModel.connect()` is
    /// `@MainActor`, but the `Connector` it awaits is a plain `@Sendable`
    /// async closure with no isolation of its own. If awaiting it kept the
    /// main actor, anything the real backend does synchronously — a socket
    /// call, a semaphore, a lock — would freeze the app for the duration.
    ///
    /// Measured with a connector that blocks its own thread outright, which
    /// is the worst case the real one could ever be, and read two ways. The
    /// thread identity is the deterministic half and survives any amount of
    /// load: whichever thread ran the connector body, it was not the main
    /// one. The gap is the timing half, and is stated against the ambient
    /// control.
    @MainActor
    @Test func awaitingTheConnectorDoesNotKeepTheMainActor() async {
        let ambient = await ambientGap(over: .milliseconds(600))

        let ranOnMainThread = OneShotFlag()
        let vm = ConnectionViewModel(connector: { _, _ in
            ranOnMainThread.set(onMainThread())
            blockThisThread(forMilliseconds: 600)
            throw HostKeyError.rejectedByUser
        })
        // TEST-NET-1 (RFC 5737), never dialed: this connector is injected
        // and throws without touching the network. The address is here only
        // because the form requires one.
        vm.host = "192.0.2.1"
        vm.port = "22"
        vm.username = "tester"
        vm.password = "secret"

        let (ticker, log) = await startTicker()
        _ = await vm.connect()
        await closeWindow(ticker)

        #expect(ranOnMainThread.value == false)
        #expect(
            log.largestGap <= ceiling(forAmbient: ambient),
            "gap \(log.largestGap) over \(log.stamps.count) ticks, ambient \(ambient)")
    }

    // MARK: - 2. The real dial

    /// The same measurement against the real SSH backend, dialing an
    /// endpoint that swallows the connection attempt (see
    /// `StalledLoopbackEndpoint` — loopback only, nothing leaves the
    /// machine). The dial is expected to end in a connect timeout; what is
    /// under test is what the main actor did in the meantime.
    ///
    /// Bounded by the injected `connectTimeout`, so it cannot hang the
    /// suite: 1.5 s of stall, then a thrown error either way.
    @MainActor
    @Test(.enabled(if: StalledLoopbackEndpoint.isAvailable))
    func theMainActorKeepsRunningWhileARealDialStalls() async throws {
        let endpoint = try StalledLoopbackEndpoint()
        defer { endpoint.close() }

        let knownHostsDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-b1-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: knownHostsDirectory) }
        let store = KnownHostsStore(directory: knownHostsDirectory)

        let config = try SSHConnectionConfig(
            host: "127.0.0.1",
            port: endpoint.port,
            username: "tester",
            auth: .password("secret")
        )

        let ambient = await ambientGap(over: .milliseconds(600))
        let (ticker, log) = await startTicker()
        let started = ContinuousClock.now
        var thrown: Error?
        do {
            let fs = try await CitadelFileSystem.connect(
                config: config,
                connectTimeout: .milliseconds(1500),
                knownHosts: store,
                onUnknownHostKey: { _ in false })
            await fs.disconnect()
        } catch {
            thrown = error
        }
        let elapsed = ContinuousClock.now - started
        await closeWindow(ticker)

        // The endpoint really stalled rather than refusing: had the SYN been
        // answered with a reset, this would have come back in milliseconds.
        #expect(thrown != nil)
        #expect(elapsed > .milliseconds(1200))
        // And the main actor ran the whole time it was stalling.
        #expect(
            log.largestGap <= ceiling(forAmbient: ambient),
            "gap \(log.largestGap) over \(log.stamps.count) ticks, ambient \(ambient)")
    }

    // MARK: - 3. The agent's blocking wait

    /// `AgentBackedPrivateKey.signature(for:)` bridges NIOSSH's synchronous
    /// signing hook to the async agent round trip by blocking its caller's
    /// thread on a semaphore. In production that caller is an SSH event-loop
    /// thread, never the main actor — but the cost of ever calling it from
    /// the main actor is what this measures, because "it is not reachable"
    /// is a claim about call sites and call sites move.
    ///
    /// Invoked here DIRECTLY from the main actor with an agent that never
    /// answers. If the main actor stops for the whole `signTimeout`, the
    /// blocking wait is a real hazard that only the current call graph keeps
    /// harmless.
    ///
    /// The wait is kept short (0.4 s) so the block this test inflicts on the
    /// whole test run's main actor stays small; production's default is 15 s.
    @MainActor
    @Test func theAgentSignWaitBlocksWhoeverCallsIt() async {
        let key = AgentBackedPrivateKey<AgentAlgorithm.Ed25519>(
            identity: AgentIdentity(
                publicKeyBlob: Data(repeating: 7, count: 32),
                comment: "stalled",
                keyType: "ssh-ed25519",
                fingerprintSHA256: "SHA256:stalled"),
            client: SSHAgentClient(transport: NeverAnsweringAgentTransport()),
            signTimeout: 0.4)

        let (ticker, log) = await startTicker()
        // Let the ticker take at least one turn before the blocking call, so
        // a gap has something to be measured from.
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(50))
        _ = try? key.signature(for: Data("payload".utf8))
        // And at least one turn AFTER it: a gap exists only between two
        // stamps, so a ticker cancelled the instant the block ends records
        // nothing at all and the measurement silently reads as "no stall".
        // (Round 1 of this test did exactly that and reported a 25 ms
        // maximum for a 400 ms block.)
        await closeWindow(ticker)

        #expect(log.largestGap > .milliseconds(250))
    }

    // MARK: - 4. Resolution or connect?

    /// A host that swallows packets and a host whose DNS stalls are two
    /// different stalls, and only one of them is obviously covered by a
    /// parameter named `connectTimeout`. Citadel builds its bootstrap with
    /// `.connectTimeout(settings.connectTimeout)` and then calls
    /// `connect(host:port:)` (Citadel `ClientSession.swift`), which is NIO's
    /// Happy Eyeballs path — so the question is whether NIO's deadline is
    /// armed before resolution or only after it.
    ///
    /// Measured on that exact path with a resolver that never answers, so
    /// the connector cannot leave the resolving state. No query is issued
    /// and no address is contacted; the resolver returns a future nobody
    /// ever fulfills.
    @Test func theConnectDeadlineAlsoCoversNameResolution() async throws {
        let loops = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let resolver = NeverAnsweringResolver(group: loops)

        let started = ContinuousClock.now
        var thrown: Error?
        do {
            // Raced against a ceiling on purpose. The whole point of the
            // test is that NIO's deadline covers the resolving state; if it
            // did not, the resolver below would never answer and a bare
            // `await` here would hang the suite instead of failing it.
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    // Built here rather than outside: `ClientBootstrap` is
                    // not `Sendable`, and only the loop group and the
                    // resolver need to cross into this task.
                    let bootstrap = ClientBootstrap(group: loops)
                        .connectTimeout(.milliseconds(400))
                        .resolver(resolver)
                    let channel = try await bootstrap.connect(
                        host: "unresolvable.example", port: 22).get()
                    try await channel.close()
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(5))
                    throw DeadlineNotEnforced()
                }
                try await group.next()
                group.cancelAll()
            }
        } catch {
            thrown = error
        }
        let elapsed = ContinuousClock.now - started

        // The deadline fires while still resolving: it is armed in
        // `resolveAndConnect()` before the first query goes out, and
        // `(.resolving, .connectTimeoutElapsed)` is a handled transition of
        // the Happy Eyeballs state machine.
        #expect(thrown != nil)
        #expect(!(thrown is DeadlineNotEnforced), "the connect never ended: \(elapsed)")
        #expect(elapsed > .milliseconds(300))
        #expect(elapsed < .seconds(5))
        #expect(resolver.queriesStarted > 0)
        try await loops.shutdownGracefully()
    }
}

// MARK: - Fixtures

/// Whether the calling thread is the process's main thread. Synchronous on
/// purpose: `Thread.isMainThread` is unavailable from an async context, and
/// the question here is precisely which thread an async body landed on.
private func onMainThread() -> Bool { pthread_main_np() != 0 }

/// Holds the calling thread — not the calling `Task` — for the given time.
/// The worst thing a connector could do to whatever executor is running it.
private func blockThisThread(forMilliseconds milliseconds: UInt32) {
    usleep(milliseconds * 1000)
}

/// One-shot `Bool` box for a value written by a `@Sendable` closure on some
/// other thread and read after that closure has demonstrably finished.
private final class OneShotFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool?

    func set(_ newValue: Bool) {
        lock.lock()
        stored = newValue
        lock.unlock()
    }

    var value: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

/// Raised when `bootstrap.connect` outlives its own `connectTimeout` — the
/// outcome that would mean NIO's deadline does NOT cover name resolution.
private struct DeadlineNotEnforced: Error {}

/// A NIO resolver that starts queries and never answers them — a host whose
/// name resolution hangs, without any DNS traffic.
private final class NeverAnsweringResolver: Resolver, Sendable {
    private let group: EventLoopGroup
    private let started = NIOLockedValueBox(0)

    init(group: EventLoopGroup) { self.group = group }

    var queriesStarted: Int { started.withLockedValue { $0 } }

    func initiateAQuery(host: String, port: Int) -> EventLoopFuture<[SocketAddress]> {
        started.withLockedValue { $0 += 1 }
        return group.next().makePromise(of: [SocketAddress].self).futureResult
    }

    func initiateAAAAQuery(host: String, port: Int) -> EventLoopFuture<[SocketAddress]> {
        started.withLockedValue { $0 += 1 }
        return group.next().makePromise(of: [SocketAddress].self).futureResult
    }

    func cancelQueries() {}
}

/// An agent transport whose round trip never returns — the stalled
/// `ssh-add`/hardware-token case, without an agent.
private struct NeverAnsweringAgentTransport: SSHAgentTransport {
    func roundTrip(_ request: Data) async throws -> Data {
        try await Task.sleep(for: .seconds(3600))
        return Data()
    }

    func close() async {}
}

/// A loopback TCP endpoint that swallows connection attempts.
///
/// A listening socket whose accept queue is full and which never calls
/// `accept()` makes the kernel DROP further SYNs rather than reset them, so
/// a `connect()` to it hangs exactly like a host that swallows packets —
/// which is the reported case. Bound to 127.0.0.1: no packet leaves the
/// machine, and no name is resolved.
///
/// `isAvailable` builds and tears down one instance to confirm the kernel on
/// this machine actually behaves that way, so a host with a different
/// backlog policy skips the test rather than failing it or hanging.
final class StalledLoopbackEndpoint {
    enum SetupError: Error {
        /// The kernel answered a probe connect instead of dropping it — the
        /// fixture cannot produce a stall here.
        case doesNotStall
        case socketFailure(String)
    }

    let port: Int
    private let listenerFD: Int32
    private var fillerFDs: [Int32] = []

    init() throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw SetupError.socketFailure("socket") }
        var reuse: Int32 = 1
        setsockopt(
            listener, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0  // any free port
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            Darwin.close(listener)
            throw SetupError.socketFailure("bind")
        }
        // Smallest queue the kernel will grant, and nothing ever accepts
        // from it.
        guard listen(listener, 1) == 0 else {
            Darwin.close(listener)
            throw SetupError.socketFailure("listen")
        }

        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(listener, $0, &length)
            }
        }
        guard named == 0 else {
            Darwin.close(listener)
            throw SetupError.socketFailure("getsockname")
        }
        self.listenerFD = listener
        self.port = Int(UInt16(bigEndian: assigned.sin_port))

        // Fill the queue. Each of these is non-blocking, so a filler that is
        // itself dropped costs nothing; the point is only that after them,
        // the queue has no room left.
        for _ in 0..<8 {
            if let filler = Self.startConnect(toPort: port) { fillerFDs.append(filler) }
        }

        // Confirm the next attempt is dropped rather than answered.
        guard Self.connectStalls(toPort: port, within: 0.35) else {
            close()
            throw SetupError.doesNotStall
        }
    }

    func close() {
        for fd in fillerFDs { Darwin.close(fd) }
        fillerFDs = []
        Darwin.close(listenerFD)
    }

    /// Whether this machine's kernel produces the stall the fixture needs.
    static let isAvailable: Bool = {
        guard let probe = try? StalledLoopbackEndpoint() else { return false }
        probe.close()
        return true
    }()

    /// Starts a non-blocking connect and returns its descriptor, whatever
    /// state it ended up in.
    private static func startConnect(toPort port: Int) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return fd
    }

    /// `true` when a fresh connect to `port` is still unresolved after
    /// `seconds` — neither completed nor refused.
    private static func connectStalls(toPort port: Int, within seconds: Double) -> Bool {
        guard let fd = startConnect(toPort: port) else { return false }
        defer { Darwin.close(fd) }
        var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let ready = withUnsafeMutablePointer(to: &descriptor) {
            poll($0, 1, Int32(seconds * 1000))
        }
        return ready == 0  // timed out: neither writable nor errored
    }
}
