import Foundation
import Testing
@testable import macSCPCore

@Suite("TransferQueueViewModel")
@MainActor
struct TransferQueueViewModelTests {

    // MARK: - Test-Doubles (signalbasiert, ohne Sleeps)

    /// Einmal-Signal: `wait()` blockiert, bis `fire()` gerufen wird; wird die
    /// wartende Task gecancelt, wirft `wait()` `CancellationError`. So kann ein
    /// gegateter Transfer per Cancel abgebrochen werden, ohne dass `fire()`
    /// jemals kommt.
    actor TestSignal {
        private var fired = false
        private var continuations: [UUID: CheckedContinuation<Void, Error>] = [:]

        func fire() {
            fired = true
            let pending = continuations
            continuations.removeAll()
            for continuation in pending.values { continuation.resume() }
        }

        func wait() async throws {
            if fired { return }
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    if fired {
                        continuation.resume()
                    } else if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuations[id] = continuation
                    }
                }
            } onCancel: {
                Task { await self.cancelWaiter(id) }
            }
        }

        private func cancelWaiter(_ id: UUID) {
            if let continuation = continuations.removeValue(forKey: id) {
                continuation.resume(throwing: CancellationError())
            }
        }
    }

    /// Kontrollierbares Dateisystem: pro Quellpfad Inhalt + optionale Signale
    /// (`started` feuert beim ersten Chunk-Pull, `gate` blockiert davor).
    /// Nicht registrierte Pfade lassen `stat` `RemoteFSError.notFound` werfen.
    /// Schreibvorgänge werden in Reihenfolge protokolliert.
    actor QueueTestFS: RemoteFileSystem {
        struct Read {
            var content: Data
            var started: TestSignal?
            var gate: TestSignal?
        }

        private var reads: [String: Read]
        private var written: [String: Data] = [:]
        private(set) var writeOrder: [String] = []

        init(reads: [String: Read]) { self.reads = reads }

        func list(path: String) async throws -> [RemoteFileItem] { [] }

        func stat(path: String) async throws -> RemoteFileItem {
            guard let read = reads[path] else { throw RemoteFSError.notFound(path: path) }
            let name = String(path.split(separator: "/").last ?? Substring(path))
            return RemoteFileItem(name: name, path: path, kind: .file, size: UInt64(read.content.count))
        }

        func readStream(path: String) async throws -> AsyncThrowingStream<Data, Error> {
            guard let read = reads[path] else { throw RemoteFSError.notFound(path: path) }
            let chunks = QueueTestFS.chunked(read.content)
            let started = read.started
            let gate = read.gate
            var index = 0
            var opened = false
            return AsyncThrowingStream<Data, Error>(unfolding: {
                if !opened {
                    opened = true
                    await started?.fire()
                    if let gate { try await gate.wait() }
                }
                guard index < chunks.count else { return nil }
                defer { index += 1 }
                return chunks[index]
            })
        }

        func write(path: String, contents: AsyncThrowingStream<Data, Error>) async throws {
            var collected = Data()
            for try await chunk in contents { collected.append(chunk) }
            written[path] = collected
            writeOrder.append(path)
        }

        func writtenData(at path: String) -> Data? { written[path] }

        func disconnect() async {}

        private static func chunked(_ data: Data) -> [Data] {
            guard !data.isEmpty else { return [] }
            var chunks: [Data] = []
            var offset = 0
            while offset < data.count {
                let end = min(offset + TransferChunk.size, data.count)
                chunks.append(data.subdata(in: offset..<end))
                offset = end
            }
            return chunks
        }
    }

    // MARK: - Kleine Helfer

    /// MainActor-Zähler für `onCompleted`-Aufrufe.
    @MainActor final class Counter {
        private(set) var value = 0
        func increment() { value += 1 }
    }

    /// Pollt (mit `Task.yield`) auf eine Bedingung, damit Tests nicht auf feste
    /// Sleeps angewiesen sind. Nur für Zustände ohne eigenes Signal.
    @MainActor func waitUntil(
        _ condition: @MainActor () -> Bool,
        limit: Int = 100_000
    ) async {
        var iterations = 0
        while !condition() && iterations < limit {
            await Task.yield()
            iterations += 1
        }
    }

    // MARK: - 1

    @Test func enqueueRunsTransferAndFinishes() async throws {
        let content = Data("hallo welt".utf8)
        let started = TestSignal()
        let gate = TestSignal()
        let source = QueueTestFS(reads: ["/a.txt": .init(content: content, started: started, gate: gate)])
        let destination = QueueTestFS(reads: [:])
        let counter = Counter()
        let done = TestSignal()

        let vm = TransferQueueViewModel()
        vm.enqueue(
            fileName: "a.txt", direction: .download,
            source: source, sourcePath: "/a.txt",
            destination: destination, destinationDirectory: "/ziel",
            onCompleted: { counter.increment(); await done.fire() })

        // Direkt nach enqueue (noch kein await): deterministisch queued.
        #expect(vm.items.count == 1)
        #expect(vm.items[0].status == .queued)

        try await started.wait()
        #expect(vm.items[0].status.isRunning)

        await gate.fire()
        try await done.wait()

        #expect(vm.items[0].status == .finished)
        #expect(counter.value == 1)
        #expect(await destination.writtenData(at: "/ziel/a.txt") == content)
    }

    // MARK: - 2

    @Test func secondEnqueueDuringRunningIsQueuedNotDropped() async throws {
        let content = Data("x".utf8)
        let started1 = TestSignal()
        let gate1 = TestSignal()
        let source = QueueTestFS(reads: [
            "/1.txt": .init(content: content, started: started1, gate: gate1),
            "/2.txt": .init(content: content),
        ])
        let destination = QueueTestFS(reads: [:])
        let done1 = TestSignal()
        let done2 = TestSignal()

        let vm = TransferQueueViewModel()
        vm.enqueue(
            fileName: "1.txt", direction: .upload,
            source: source, sourcePath: "/1.txt",
            destination: destination, destinationDirectory: "/ziel",
            onCompleted: { await done1.fire() })
        vm.enqueue(
            fileName: "2.txt", direction: .upload,
            source: source, sourcePath: "/2.txt",
            destination: destination, destinationDirectory: "/ziel",
            onCompleted: { await done2.fire() })

        try await started1.wait()
        // Item 1 läuft, Item 2 wurde NICHT verworfen, sondern wartet.
        #expect(vm.items[0].status.isRunning)
        #expect(vm.items[1].status == .queued)

        await gate1.fire()
        try await done1.wait()
        try await done2.wait()

        #expect(vm.items[0].status == .finished)
        #expect(vm.items[1].status == .finished)
        #expect(await destination.writtenData(at: "/ziel/1.txt") == content)
        #expect(await destination.writtenData(at: "/ziel/2.txt") == content)
    }

    // MARK: - 3

    @Test func itemsRunInFIFOOrder() async throws {
        let content = Data("y".utf8)
        let source = QueueTestFS(reads: [
            "/1.txt": .init(content: content),
            "/2.txt": .init(content: content),
            "/3.txt": .init(content: content),
        ])
        let destination = QueueTestFS(reads: [:])
        let done = TestSignal()

        let vm = TransferQueueViewModel()
        for name in ["1.txt", "2.txt"] {
            vm.enqueue(
                fileName: name, direction: .upload,
                source: source, sourcePath: "/\(name)",
                destination: destination, destinationDirectory: "/ziel",
                onCompleted: nil)
        }
        vm.enqueue(
            fileName: "3.txt", direction: .upload,
            source: source, sourcePath: "/3.txt",
            destination: destination, destinationDirectory: "/ziel",
            onCompleted: { await done.fire() })

        try await done.wait()

        #expect(await destination.writeOrder == ["/ziel/1.txt", "/ziel/2.txt", "/ziel/3.txt"])
    }

    // MARK: - 4

    @Test func failedItemDoesNotBlockQueue() async throws {
        let content = Data("z".utf8)
        // /1.txt ist NICHT registriert → stat wirft notFound.
        let source = QueueTestFS(reads: ["/2.txt": .init(content: content)])
        let destination = QueueTestFS(reads: [:])
        let done2 = TestSignal()

        let vm = TransferQueueViewModel()
        vm.enqueue(
            fileName: "1.txt", direction: .download,
            source: source, sourcePath: "/1.txt",
            destination: destination, destinationDirectory: "/ziel",
            onCompleted: nil)
        vm.enqueue(
            fileName: "2.txt", direction: .download,
            source: source, sourcePath: "/2.txt",
            destination: destination, destinationDirectory: "/ziel",
            onCompleted: { await done2.fire() })

        try await done2.wait()

        #expect(vm.items[0].status == .failed("Datei nicht gefunden: /1.txt"))
        #expect(vm.items[1].status == .finished)
        #expect(await destination.writtenData(at: "/ziel/2.txt") == content)
    }

    // MARK: - 5

    @Test func enqueueAndWaitReturnsAfterCompletion() async throws {
        let content = Data("w".utf8)
        let started = TestSignal()
        let gate = TestSignal()
        let source = QueueTestFS(reads: ["/a.txt": .init(content: content, started: started, gate: gate)])
        let destination = QueueTestFS(reads: [:])

        let vm = TransferQueueViewModel()
        let returned = Counter()
        let waitTask = Task { @MainActor in
            try await vm.enqueueAndWait(
                fileName: "a.txt", direction: .download,
                source: source, sourcePath: "/a.txt",
                destination: destination, destinationDirectory: "/ziel")
            returned.increment()
        }

        try await started.wait()
        // Läuft noch → enqueueAndWait ist NICHT zurückgekehrt.
        #expect(returned.value == 0)
        #expect(vm.items[0].status.isRunning)

        await gate.fire()
        try await waitTask.value

        #expect(returned.value == 1)
        #expect(vm.items[0].status == .finished)
    }

    // MARK: - 6

    @Test func enqueueAndWaitThrowsOnFailure() async throws {
        // /a.txt nicht registriert → stat wirft notFound → enqueueAndWait wirft.
        let source = QueueTestFS(reads: [:])
        let destination = QueueTestFS(reads: [:])

        let vm = TransferQueueViewModel()
        await #expect(throws: RemoteFSError.self) {
            try await vm.enqueueAndWait(
                fileName: "a.txt", direction: .download,
                source: source, sourcePath: "/a.txt",
                destination: destination, destinationDirectory: "/ziel")
        }
        #expect(vm.items[0].status == .failed("Datei nicht gefunden: /a.txt"))
    }

    // MARK: - 7

    @Test func cancelAllCancelsQueuedAndRunning() async throws {
        let content = Data("c".utf8)
        let started1 = TestSignal()
        let gate1 = TestSignal()   // wird nie gefeuert; Cancel muss ihn lösen
        let source = QueueTestFS(reads: [
            "/1.txt": .init(content: content, started: started1, gate: gate1),
            "/2.txt": .init(content: content),
            "/3.txt": .init(content: content),
        ])
        let destination = QueueTestFS(reads: [:])

        let vm = TransferQueueViewModel()
        vm.enqueue(
            fileName: "1.txt", direction: .upload,
            source: source, sourcePath: "/1.txt",
            destination: destination, destinationDirectory: "/ziel",
            onCompleted: nil)
        // Item 2 mit einem wartenden enqueueAndWait — muss beim Cancel werfen.
        let waiterThrew = Counter()
        let waitTask = Task { @MainActor in
            do {
                try await vm.enqueueAndWait(
                    fileName: "2.txt", direction: .upload,
                    source: source, sourcePath: "/2.txt",
                    destination: destination, destinationDirectory: "/ziel")
            } catch {
                waiterThrew.increment()
            }
        }

        // Warten, bis Item 1 läuft UND Item 2 eingereiht ist.
        try await started1.wait()
        await waitUntil { vm.items.count == 2 && vm.items[1].status == .queued }

        await vm.cancelAll()

        #expect(vm.items[1].status == .cancelled)          // queued → sofort cancelled
        #expect(vm.items[0].status == .cancelled)          // laufend → cancelled, NICHT failed
        await waitTask.value
        #expect(waiterThrew.value == 1)                     // wartender enqueueAndWait warf
        #expect(vm.isActive == false)

        // Worker-Neustart nach cancelAll: neues enqueue läuft wieder an.
        let done3 = TestSignal()
        vm.enqueue(
            fileName: "3.txt", direction: .upload,
            source: source, sourcePath: "/3.txt",
            destination: destination, destinationDirectory: "/ziel",
            onCompleted: { await done3.fire() })
        try await done3.wait()
        #expect(vm.items.last?.status == .finished)
        #expect(vm.isActive == false)
    }

    // MARK: - 8

    @Test func clearCompletedRemovesOnlyDone() async throws {
        let content = Data("d".utf8)
        let startedX = TestSignal()
        let gateX = TestSignal()
        let startedC = TestSignal()
        let gateC = TestSignal()
        let source = QueueTestFS(reads: [
            "/x.txt": .init(content: content, started: startedX, gate: gateX),   // wird cancelled
            "/a.txt": .init(content: content),                                    // finished
            // /b.txt fehlt → failed
            "/c.txt": .init(content: content, started: startedC, gate: gateC),   // bleibt running
            "/d.txt": .init(content: content),                                    // bleibt queued
        ])
        let destination = QueueTestFS(reads: [:])
        let vm = TransferQueueViewModel()

        // cancelled: X starten, dann cancelAll.
        vm.enqueue(
            fileName: "x.txt", direction: .upload,
            source: source, sourcePath: "/x.txt",
            destination: destination, destinationDirectory: "/ziel", onCompleted: nil)
        try await startedX.wait()
        await vm.cancelAll()
        #expect(vm.items[0].status == .cancelled)

        // finished: A per enqueueAndWait.
        try await vm.enqueueAndWait(
            fileName: "a.txt", direction: .upload,
            source: source, sourcePath: "/a.txt",
            destination: destination, destinationDirectory: "/ziel")

        // failed: B per enqueueAndWait (wirft), Status failed.
        _ = try? await vm.enqueueAndWait(
            fileName: "b.txt", direction: .upload,
            source: source, sourcePath: "/b.txt",
            destination: destination, destinationDirectory: "/ziel")

        // running C + queued D.
        vm.enqueue(
            fileName: "c.txt", direction: .upload,
            source: source, sourcePath: "/c.txt",
            destination: destination, destinationDirectory: "/ziel", onCompleted: nil)
        try await startedC.wait()
        vm.enqueue(
            fileName: "d.txt", direction: .upload,
            source: source, sourcePath: "/d.txt",
            destination: destination, destinationDirectory: "/ziel", onCompleted: nil)

        // Zustand vor dem Aufräumen: cancelled, finished, failed, running, queued.
        #expect(vm.items.count == 5)
        #expect(vm.items[3].status.isRunning)
        #expect(vm.items[4].status == .queued)

        vm.clearCompleted()

        // Nur running + queued bleiben.
        #expect(vm.items.count == 2)
        #expect(vm.items[0].fileName == "c.txt")
        #expect(vm.items[0].status.isRunning)
        #expect(vm.items[1].fileName == "d.txt")
        #expect(vm.items[1].status == .queued)

        // Aufräumen: C/D abbrechen, damit keine Task hängen bleibt.
        await vm.cancelAll()
    }

    // MARK: - 9

    @Test func isActiveReflectsPendingWork() async throws {
        let content = Data("e".utf8)
        let started = TestSignal()
        let gate = TestSignal()
        let source = QueueTestFS(reads: ["/a.txt": .init(content: content, started: started, gate: gate)])
        let destination = QueueTestFS(reads: [:])
        let done = TestSignal()

        let vm = TransferQueueViewModel()
        #expect(vm.isActive == false)

        vm.enqueue(
            fileName: "a.txt", direction: .download,
            source: source, sourcePath: "/a.txt",
            destination: destination, destinationDirectory: "/ziel",
            onCompleted: { await done.fire() })
        #expect(vm.isActive == true)

        try await started.wait()
        #expect(vm.isActive == true)
        #expect(vm.pendingCount == 1)

        await gate.fire()
        try await done.wait()
        await waitUntil { vm.isActive == false }
        #expect(vm.isActive == false)
        #expect(vm.pendingCount == 0)
    }

    // MARK: - Konflikt-Tests (M5b/T2)

    /// Actor-Zähler für Decider-Aufrufe aus einer `@Sendable`-Closure.
    actor CallCounter {
        private(set) var count = 0
        func increment() { count += 1 }
    }

    // MARK: - 10

    /// Ohne gesetzten Decider verhält sich ein Konflikt wie M5a: überschreiben.
    @Test func conflictWithoutDeciderOverwrites() async throws {
        let content = Data("neu".utf8)
        let source = QueueTestFS(reads: ["/a.txt": .init(content: content)])
        // Ziel existiert bereits → Konflikt.
        let destination = QueueTestFS(reads: ["/ziel/a.txt": .init(content: Data("alt".utf8))])

        let vm = TransferQueueViewModel()
        try await vm.enqueueAndWait(
            fileName: "a.txt", direction: .upload,
            source: source, sourcePath: "/a.txt",
            destination: destination, destinationDirectory: "/ziel")

        #expect(vm.items[0].status == .finished)
        #expect(await destination.writtenData(at: "/ziel/a.txt") == content)
    }

    // MARK: - 11

    /// `.skip` markiert das Item `.skipped`, schreibt nicht und ruft kein onCompleted.
    @Test func deciderSkipMarksSkippedAndSkipsWrite() async throws {
        let content = Data("x".utf8)
        let source = QueueTestFS(reads: ["/a.txt": .init(content: content)])
        let destination = QueueTestFS(reads: ["/ziel/a.txt": .init(content: Data("alt".utf8))])
        let counter = Counter()

        let vm = TransferQueueViewModel()
        vm.conflictDecider = { _ in (.skip, false) }
        vm.enqueue(
            fileName: "a.txt", direction: .upload,
            source: source, sourcePath: "/a.txt",
            destination: destination, destinationDirectory: "/ziel",
            onCompleted: { counter.increment() })

        await waitUntil { vm.items[0].status == .skipped }
        #expect(vm.items[0].status == .skipped)
        #expect(counter.value == 0)
        #expect(await destination.writtenData(at: "/ziel/a.txt") == nil)   // kein Write
    }

    // MARK: - 12

    /// `.overwrite` schreibt das Ziel neu.
    @Test func deciderOverwriteWrites() async throws {
        let content = Data("neu".utf8)
        let source = QueueTestFS(reads: ["/a.txt": .init(content: content)])
        let destination = QueueTestFS(reads: ["/ziel/a.txt": .init(content: Data("alt".utf8))])

        let vm = TransferQueueViewModel()
        vm.conflictDecider = { _ in (.overwrite, false) }
        try await vm.enqueueAndWait(
            fileName: "a.txt", direction: .upload,
            source: source, sourcePath: "/a.txt",
            destination: destination, destinationDirectory: "/ziel")

        #expect(vm.items[0].status == .finished)
        #expect(await destination.writtenData(at: "/ziel/a.txt") == content)
    }

    // MARK: - 13

    /// `.rename` sucht den nächsten freien Namen: "(2)" belegt → landet bei "(3)".
    @Test func deciderRenameWritesUnderFreeName() async throws {
        let content = Data("neu".utf8)
        let source = QueueTestFS(reads: ["/a.txt": .init(content: content)])
        let destination = QueueTestFS(reads: [
            "/ziel/a.txt": .init(content: Data("alt".utf8)),        // Konflikt
            "/ziel/a (2).txt": .init(content: Data("belegt".utf8)), // (2) belegt
        ])

        let vm = TransferQueueViewModel()
        vm.conflictDecider = { _ in (.rename, false) }
        try await vm.enqueueAndWait(
            fileName: "a.txt", direction: .upload,
            source: source, sourcePath: "/a.txt",
            destination: destination, destinationDirectory: "/ziel")

        #expect(vm.items[0].status == .finished)
        #expect(vm.items[0].fileName == "a (3).txt")
        #expect(await destination.writtenData(at: "/ziel/a (3).txt") == content)
        #expect(await destination.writtenData(at: "/ziel/a.txt") == nil)   // Original unangetastet
    }

    // MARK: - 14

    /// Decider gibt nil (Abbrechen) → Item `.cancelled`, enqueueAndWait wirft.
    @Test func deciderCancelCancelsItem() async throws {
        let content = Data("x".utf8)
        let source = QueueTestFS(reads: ["/a.txt": .init(content: content)])
        let destination = QueueTestFS(reads: ["/ziel/a.txt": .init(content: Data("alt".utf8))])

        let vm = TransferQueueViewModel()
        vm.conflictDecider = { _ in nil }
        await #expect(throws: CancellationError.self) {
            try await vm.enqueueAndWait(
                fileName: "a.txt", direction: .upload,
                source: source, sourcePath: "/a.txt",
                destination: destination, destinationDirectory: "/ziel")
        }
        #expect(vm.items[0].status == .cancelled)
        #expect(await destination.writtenData(at: "/ziel/a.txt") == nil)   // kein Write
    }

    // MARK: - 15

    /// `applyToAll == true` setzt eine Regel: der zweite Konflikt fragt nicht erneut.
    @Test func applyToAllAsksOnlyOnce() async throws {
        let content = Data("x".utf8)
        let source = QueueTestFS(reads: [
            "/1.txt": .init(content: content),
            "/2.txt": .init(content: content),
        ])
        let destination = QueueTestFS(reads: [
            "/ziel/1.txt": .init(content: Data("alt".utf8)),
            "/ziel/2.txt": .init(content: Data("alt".utf8)),
        ])
        let calls = CallCounter()

        let vm = TransferQueueViewModel()
        vm.conflictDecider = { _ in await calls.increment(); return (.overwrite, true) }
        for name in ["1.txt", "2.txt"] {
            vm.enqueue(
                fileName: name, direction: .upload,
                source: source, sourcePath: "/\(name)",
                destination: destination, destinationDirectory: "/ziel",
                onCompleted: nil)
        }

        await waitUntil { vm.items.count == 2 && vm.items.allSatisfy { $0.status == .finished } }
        #expect(await calls.count == 1)
        #expect(await destination.writtenData(at: "/ziel/1.txt") == content)
        #expect(await destination.writtenData(at: "/ziel/2.txt") == content)
    }

    // MARK: - 16

    /// Die Regel gilt nur bis zum Drain: ein späterer Batch fragt wieder.
    @Test func ruleResetsAfterDrain() async throws {
        let content = Data("x".utf8)
        let source = QueueTestFS(reads: [
            "/1.txt": .init(content: content),
            "/2.txt": .init(content: content),
        ])
        let destination = QueueTestFS(reads: [
            "/ziel/1.txt": .init(content: Data("alt".utf8)),
            "/ziel/2.txt": .init(content: Data("alt".utf8)),
        ])
        let calls = CallCounter()

        let vm = TransferQueueViewModel()
        vm.conflictDecider = { _ in await calls.increment(); return (.overwrite, true) }

        // Batch 1 mit applyToAll.
        try await vm.enqueueAndWait(
            fileName: "1.txt", direction: .upload,
            source: source, sourcePath: "/1.txt",
            destination: destination, destinationDirectory: "/ziel")
        #expect(await calls.count == 1)
        await waitUntil { vm.isActive == false }   // Worker leergelaufen → Regel zurückgesetzt

        // Batch 2: Decider wird WIEDER gefragt.
        try await vm.enqueueAndWait(
            fileName: "2.txt", direction: .upload,
            source: source, sourcePath: "/2.txt",
            destination: destination, destinationDirectory: "/ziel")
        #expect(await calls.count == 2)
    }

    // MARK: - 17

    /// Existiert das Ziel nicht, wird der Decider gar nicht erst gefragt.
    @Test func noConflictDoesNotAskDecider() async throws {
        let content = Data("x".utf8)
        let source = QueueTestFS(reads: ["/a.txt": .init(content: content)])
        let destination = QueueTestFS(reads: [:])   // Ziel existiert NICHT
        let calls = CallCounter()

        let vm = TransferQueueViewModel()
        vm.conflictDecider = { _ in await calls.increment(); return (.overwrite, false) }
        try await vm.enqueueAndWait(
            fileName: "a.txt", direction: .download,
            source: source, sourcePath: "/a.txt",
            destination: destination, destinationDirectory: "/ziel")

        #expect(vm.items[0].status == .finished)
        #expect(await calls.count == 0)
        #expect(await destination.writtenData(at: "/ziel/a.txt") == content)
    }
}
