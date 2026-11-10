import Foundation
import MacSCPTestSupport
import Synchronization
import Testing

@testable import MacSCPAppKit
@testable import macSCPCore

/// `FileActionShell.typeLines(_:)`: a file action types one line per file,
/// and the first line the terminal refuses stops the rest. Without that stop
/// a later, shorter line would be typed with the refused one missing before
/// it, and the pane would answer "this connection has none" about a shell
/// that exists.
@Suite("File action shell typing", .timeLimit(.minutes(5)))
struct FileActionShellTypingTests {
    /// Records what reached the "terminal", and refuses from a chosen call on.
    private final class Terminal: Sendable {
        private let state = Mutex<[[UInt8]]>([])
        private let refuseFrom: Int?
        init(refuseFrom: Int?) { self.refuseFrom = refuseFrom }
        var taken: [[UInt8]] { state.withLock { $0 } }
        func type(_ bytes: [UInt8]) -> Bool {
            state.withLock { taken in
                if let refuseFrom, taken.count >= refuseFrom { return false }
                taken.append(bytes)
                return true
            }
        }
    }

    private func shell(_ terminal: Terminal, refusing: Bool) -> FileActionShell {
        FileActionShell(
            wantsBracketedPaste: { false },
            type: { terminal.type($0) },
            refusedInput: { refusing })
    }

    @Test func aRefusedLineStopsTheActionAtThatLineAndIsReportedAsARefusal() {
        let terminal = Terminal(refuseFrom: 2)
        let outcome = shell(terminal, refusing: true)
            .typeLines(["one", "two", "three", "four"])
        #expect(outcome == .refusedByTerminal)
        // Two lines were taken; the refused third and the fourth, which
        // would have fitted, were not typed.
        #expect(terminal.taken.count == 2)
    }

    @Test func aMissingShellIsStillReportedAsOne() {
        let terminal = Terminal(refuseFrom: 0)
        let outcome = shell(terminal, refusing: false).typeLines(["one", "two"])
        #expect(outcome == .noShell)
        #expect(terminal.taken.isEmpty)
    }

    @Test func everyLineTypedIsReportedAsTyped() {
        let terminal = Terminal(refuseFrom: nil)
        let outcome = shell(terminal, refusing: false).typeLines(["one", "two"])
        #expect(outcome == .typed)
        #expect(terminal.taken.count == 2)
    }

    /// The whole path against the real view model: lines big enough to fill
    /// its opening buffer. The third is refused, the small fourth never
    /// reaches it, the refusal is observable, and what the shell finally
    /// receives is the first two lines only.
    @MainActor
    @Test func aRefusedLineIsNotTypedAndTheTerminalSaysSo() async throws {
        final class Recorder: RemoteShell, Sendable {
            private let received = Mutex<[UInt8]>([])
            let output: AsyncThrowingStream<[UInt8], Error>
            private let keepOpen: AsyncThrowingStream<[UInt8], Error>.Continuation
            init() { (output, keepOpen) = AsyncThrowingStream<[UInt8], Error>.makeStream() }
            var count: Int { received.withLock { $0.count } }
            func send(_ bytes: [UInt8]) async throws { received.withLock { $0 += bytes } }
            func resize(cols: Int, rows: Int) async throws {}
            func close() async { keepOpen.finish() }
        }
        let recorder = Recorder()
        let release = AsyncStream<Void>.makeStream()
        let vm = TerminalPanelViewModel(openShell: { _, _, _ in
            for await _ in release.stream { break }
            return recorder
        })
        vm.openIfNeeded()
        let actionShell = FileActionShell(
            wantsBracketedPaste: { false },
            type: { vm.send($0) },
            refusedInput: { vm.inputRefused })

        let big = String(repeating: "a", count: 30_000)
        let outcome = actionShell.typeLines([big, big, big, "ls"])
        #expect(outcome == .refusedByTerminal)
        #expect(vm.inputRefused)

        release.continuation.yield()
        try await pollUntil("the shell is running") { vm.state == .running }
        try await pollUntil("the held lines reached the shell") {
            recorder.count >= 60_000
        }
        let count = recorder.count
        #expect(count == 2 * (30_000 + 1))
        await vm.shutdown()
    }
}
