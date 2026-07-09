import Foundation
import Testing
@testable import macSCPCore

/// Steuerbare Mock-Shell: Output wird von außen gefüttert; send/resize/close
/// werden aufgezeichnet.
final class MockShell: RemoteShell, @unchecked Sendable {
    let output: AsyncThrowingStream<[UInt8], Error>
    let continuation: AsyncThrowingStream<[UInt8], Error>.Continuation
    private let lock = NSLock()
    private var _sent: [[UInt8]] = []
    private var _resizes: [(cols: Int, rows: Int)] = []
    private var _closed = false
    var sent: [[UInt8]] { lock.lock(); defer { lock.unlock() }; return _sent }
    var resizes: [(cols: Int, rows: Int)] { lock.lock(); defer { lock.unlock() }; return _resizes }
    var closed: Bool { lock.lock(); defer { lock.unlock() }; return _closed }

    init() {
        (output, continuation) = AsyncThrowingStream<[UInt8], Error>.makeStream()
    }
    func send(_ bytes: [UInt8]) async throws { lock.lock(); _sent.append(bytes); lock.unlock() }
    func resize(cols: Int, rows: Int) async throws { lock.lock(); _resizes.append((cols, rows)); lock.unlock() }
    func close() async { lock.lock(); _closed = true; lock.unlock(); continuation.finish() }
}

/// Pollt bis `condition` wahr ist (max ~2 s) — Muster wie in den anderen VM-Tests.
@MainActor
private func waitUntil(_ condition: @autoclosure () -> Bool) async throws {
    for _ in 0..<200 where !condition() {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(condition())
}

@Suite("TerminalPanelViewModel")
@MainActor
struct TerminalPanelViewModelTests {
    @Test func toggleOpensShellAndForwardsOutput() async throws {
        let shell = MockShell()
        let vm = TerminalPanelViewModel(openShell: { _, _, _ in shell })
        var received: [[UInt8]] = []
        vm.onOutput = { received.append($0) }

        vm.toggle()
        #expect(vm.isVisible)
        try await waitUntil(vm.state == .running)

        shell.continuation.yield(Array("hallo".utf8))
        try await waitUntil(!received.isEmpty)
        #expect(received.first.map { String(decoding: $0, as: UTF8.self) } == "hallo")
    }

    @Test func toggleTwiceDoesNotOpenTwice() async throws {
        let counter = Counter()
        let vm = TerminalPanelViewModel(openShell: { _, _, _ in
            await counter.increment()
            return MockShell()
        })
        vm.toggle()   // sichtbar + öffnet
        vm.toggle()   // unsichtbar
        vm.toggle()   // sichtbar — Shell läuft schon, NICHT neu öffnen
        try await waitUntil(vm.state == .running)
        #expect(await counter.value == 1)
    }

    @Test func streamEndSetsEnded() async throws {
        let shell = MockShell()
        let vm = TerminalPanelViewModel(openShell: { _, _, _ in shell })
        vm.toggle()
        try await waitUntil(vm.state == .running)
        shell.continuation.finish()
        try await waitUntil(vm.state == .ended(nil))
    }

    @Test func streamErrorSetsEndedWithMessage() async throws {
        let shell = MockShell()
        let vm = TerminalPanelViewModel(openShell: { _, _, _ in shell })
        vm.toggle()
        try await waitUntil(vm.state == .running)
        shell.continuation.finish(throwing: RemoteFSError.protocolError(reason: "kaputt"))
        try await waitUntil({
            if case .ended(let msg) = vm.state { return msg != nil } else { return false }
        }())
    }

    @Test func openFailureSetsEnded() async throws {
        let vm = TerminalPanelViewModel(openShell: { _, _, _ in
            throw RemoteFSError.connectionFailed(reason: "nein")
        })
        vm.toggle()
        try await waitUntil({
            if case .ended(let msg) = vm.state { return msg != nil } else { return false }
        }())
    }

    @Test func reopenAfterEndedWorks() async throws {
        let shells = ShellFactory()
        let vm = TerminalPanelViewModel(openShell: { _, _, _ in await shells.next() })
        vm.toggle()
        try await waitUntil(vm.state == .running)
        await shells.current.close()
        try await waitUntil(vm.state == .ended(nil))
        vm.openIfNeeded()  // "Neu öffnen"-Button
        try await waitUntil(vm.state == .running)
        #expect(await shells.count == 2)
    }

    @Test func sendForwardsToShell() async throws {
        let shell = MockShell()
        let vm = TerminalPanelViewModel(openShell: { _, _, _ in shell })
        vm.toggle()
        try await waitUntil(vm.state == .running)
        vm.send(Array("ls\n".utf8))
        try await waitUntil(!shell.sent.isEmpty)
        #expect(shell.sent.first == Array("ls\n".utf8))
    }

    @Test func shutdownClosesShellAndHides() async throws {
        let shell = MockShell()
        let vm = TerminalPanelViewModel(openShell: { _, _, _ in shell })
        vm.toggle()
        try await waitUntil(vm.state == .running)
        await vm.shutdown()
        #expect(shell.closed)
        #expect(vm.state == .closed)
        #expect(!vm.isVisible)
    }

    /// Regression: shutdown() während `.opening` durfte den in-flight `openShell`
    /// Aufruf nicht ignorieren — sonst überschreibt das spät auflösende Öffnen
    /// den `.closed`-Zustand und die dabei erzeugte Shell bleibt als Orphan offen.
    @Test func shutdownWhileOpeningLeavesClosedAndClosesOrphan() async throws {
        let shell = MockShell()
        let openerReturned = Flag()
        let vm = TerminalPanelViewModel(openShell: { _, _, _ in
            try await Task.sleep(for: .milliseconds(100))
            await openerReturned.set()
            return shell
        })

        vm.toggle()
        #expect(vm.state == .opening)

        await vm.shutdown()
        #expect(!vm.isVisible)

        // Genug Zeit für den verzögerten Opener, um aufzulösen.
        try await Task.sleep(for: .milliseconds(300))

        #expect(vm.state == .closed)
        if await openerReturned.value {
            #expect(shell.closed)
        }
    }

    /// Regression: ein Lese-Loop, der erst nach shutdown() endet (spätes
    /// `continuation.finish()`, nachdem `close()` schon zurückgekehrt ist),
    /// darf `.closed` nicht nachträglich mit `.ended` überschreiben.
    @Test func staleReadLoopCannotOverwriteState() async throws {
        let shell = LateFinishShell()
        let vm = TerminalPanelViewModel(openShell: { _, _, _ in shell })
        vm.toggle()
        try await waitUntil(vm.state == .running)

        Task {
            try await Task.sleep(for: .milliseconds(50))
            shell.finish()
        }

        await vm.shutdown()
        #expect(vm.state == .closed)

        try await Task.sleep(for: .milliseconds(150))
        #expect(vm.state == .closed)
    }
}

actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

actor Flag {
    private(set) var value = false
    func set() { value = true }
}

/// Shell, deren `close()` sofort zurückkehrt, ohne den Ausgabe-Stream zu
/// beenden. `output` ignoriert bewusst Task-Cancellation (busy-poll auf ein
/// manuelles Flag) — reale `AsyncThrowingStream`-Continuations beenden die
/// Iteration schon bei `Task.cancel()`, was den eigentlichen Race maskieren
/// würde. Hier endet der Lese-Loop ausschließlich über das explizite,
/// verzögerte `finish()`, um zu testen, dass ein spät endender Lese-Loop den
/// bereits gesetzten Zustand nicht überschreibt.
final class LateFinishShell: RemoteShell, @unchecked Sendable {
    private let lock = NSLock()
    private var _closed = false
    private var _finished = false
    var closed: Bool { lock.lock(); defer { lock.unlock() }; return _closed }

    var output: AsyncThrowingStream<[UInt8], Error> {
        AsyncThrowingStream<[UInt8], Error> { [weak self] in
            while true {
                guard let self else { return nil }
                self.lock.lock()
                let finished = self._finished
                self.lock.unlock()
                if finished { return nil }
                // Schluckt CancellationError absichtlich — simuliert einen
                // Datenstrom, der Task-Cancellation nicht selbst beobachtet
                // (z.B. eine echte Netzwerkverbindung).
                _ = try? await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    func send(_ bytes: [UInt8]) async throws {}
    func resize(cols: Int, rows: Int) async throws {}
    func close() async {
        lock.lock(); _closed = true; lock.unlock()
    }
    func finish() {
        lock.lock(); _finished = true; lock.unlock()
    }
}

actor ShellFactory {
    private var shells: [MockShell] = []
    var count: Int { shells.count }
    var current: MockShell { shells.last! }
    func next() -> MockShell {
        let shell = MockShell()
        shells.append(shell)
        return shell
    }
}
