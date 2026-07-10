import Foundation
import Observation

/// Wie ein Zielkonflikt (Datei existiert bereits) aufgelöst wird.
/// Bindend für die UI-Schicht (M5b/T4).
public enum ConflictResolution: Sendable, Equatable { case overwrite, skip, rename }

/// Beschreibt einen konkreten Zielkonflikt für den `ConflictDecider`.
public struct TransferConflict: Sendable, Equatable {
    public let fileName: String
    public let destinationDirectory: String
    public let direction: TransferDirection

    public init(fileName: String, destinationDirectory: String, direction: TransferDirection) {
        self.fileName = fileName
        self.destinationDirectory = destinationDirectory
        self.direction = direction
    }
}

/// UI-Entscheider. Rückgabe nil == "Abbrechen" (Item wird `.cancelled`).
/// `applyToAll == true` setzt die Entscheidung als Regel für den Rest der Queue.
public typealias ConflictDecider =
    @Sendable (TransferConflict) async -> (resolution: ConflictResolution, applyToAll: Bool)?

/// UI-Zustand einer seriellen Transfer-Warteschlange (FIFO).
///
/// Ersetzt das Einzeltransfer-`TransferViewModel`: `enqueue` verwirft nichts
/// mehr, sondern reiht immer ein und startet bei Bedarf einen schlafenden
/// Worker neu.
///
/// Parallelism (M5c/T4): up to `maxConcurrent` transfers run at once. Slots are
/// filled in strict FIFO order from `order`; a slot that frees up is handed to
/// the next queued item (never a later one). The class is `@MainActor`; each
/// transfer's `copyFile` runs in its own task in `runningTransferTasks` (keyed
/// by item id, so `cancelAll` can cancel every in-flight transfer) and yields
/// the MainActor while transferring. Conflict prompts still serialize: at most
/// one decider prompt is open at a time, gated FIFO across slots.
@Observable
@MainActor
public final class TransferQueueViewModel {
    public struct Item: Identifiable, Equatable {
        public enum Status: Equatable {
            case queued
            case running(TransferProgress)
            case finished
            case failed(String)      // deutsche Meldung
            case cancelled
            case skipped             // Konflikt mit `.skip` aufgelöst ("übersprungen")

            /// true, solange dieses Item aktiv überträgt — die UI braucht das.
            public var isRunning: Bool {
                if case .running = self { return true }
                return false
            }

            /// true, wenn dieses Item einen Endzustand erreicht hat. Die
            /// Gruppen-Buchhaltung (M5b/T3) dekrementiert genau beim Übergang
            /// nach terminal — deshalb ist dieser eine Prädikat der Dreh- und
            /// Angelpunkt.
            public var isTerminal: Bool {
                switch self {
                case .finished, .failed, .cancelled, .skipped: return true
                case .queued, .running: return false
                }
            }
        }
        public let id: UUID
        public internal(set) var fileName: String   // `.rename` aktualisiert den angezeigten Namen
        public let direction: TransferDirection
        public internal(set) var status: Status
    }

    public private(set) var items: [Item] = []

    /// true, solange irgendein Item queued/running ist (Sidebar-Gate).
    public var isActive: Bool {
        items.contains { $0.status == .queued || $0.status.isRunning }
    }

    /// Anzahl offener (queued+running) Items — fürs "n ausstehend"-Label.
    public var pendingCount: Int {
        items.reduce(into: 0) { count, item in
            if item.status == .queued || item.status.isRunning { count += 1 }
        }
    }

    /// UI-Entscheider für Zielkonflikte. `nil` (Default) ⇒ stilles Überschreiben
    /// wie in M5a. Wird seriell vom Worker awaited — genau EIN offener Prompt.
    public var conflictDecider: ConflictDecider?

    /// Maximum number of transfers that may run at once (clamped to 1...8,
    /// default 3). ContentView sets this from the SettingsStore at session start
    /// and on change. A change affects FUTURE slot assignments only — transfers
    /// already running are never interrupted; raising the limit fills any freed
    /// slots immediately, lowering it lets the extra transfers finish naturally.
    public var maxConcurrent: Int = 3 {
        didSet {
            let clamped = min(8, max(1, maxConcurrent))
            if maxConcurrent != clamped {
                maxConcurrent = clamped   // re-enters didSet; next pass is a no-op clamp
                return
            }
            // A raised limit may open new slots for queued items; kicking is a
            // safe no-op when nothing is waiting or all slots are busy.
            kickWorker()
        }
    }

    // MARK: - Privater Zustand

    private struct Job {
        let id: UUID
        let source: any RemoteFileSystem
        let sourcePath: String
        let destination: any RemoteFileSystem
        let destinationDirectory: String
        let fileName: String
        let direction: TransferDirection
        let onCompleted: (@MainActor () async -> Void)?
    }

    /// Fehler ohne freien Umbenennungs-Namen (Rule 5, Obergrenze erreicht).
    private struct NoFreeNameError: Error {}

    /// Ergebnis der Konfliktprüfung vor dem Engine-Aufruf.
    private enum Outcome {
        case proceed(fileName: String)      // (evtl. umbenannter) Zielname
        case skip                            // Item → .skipped, kein Write
        case cancel                          // Item → .cancelled
        case failed(message: String, error: Error)
    }

    private var jobs: [UUID: Job] = [:]
    private var order: [UUID] = []                                  // FIFO der queued-IDs
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    /// Active `process` tasks, keyed by item id — one per occupied slot. Their
    /// count is the number of slots in use; `cancelAll` awaits them all.
    private var processTasks: [UUID: Task<Void, Never>] = [:]
    /// In-flight `copyFile` tasks, keyed by item id — one per transferring slot.
    /// `cancelAll` cancels every one (cooperative cancellation via T2).
    private var runningTransferTasks: [UUID: Task<Void, Error>] = [:]
    private var queueRule: ConflictResolution?                     // aktive "Für alle"-Regel; Reset bei Drain

    /// A minimal FIFO gate serializing conflict-decider prompts across slots:
    /// at most one prompt is open at a time, and waiters are woken in arrival
    /// order (no unfair wakeups). Only the `await decider(...)` call is gated —
    /// the rule/no-decider fast paths don't touch it.
    private let conflictGate = FIFOGate()

    /// IDs of items CURRENTLY in `resolveConflictIfNeeded` (stat probe, decider
    /// prompt, rename probing) — dequeued but not yet registered in
    /// `runningTransferTasks`. Without tracking this window, `cancelAll` would
    /// miss these items (M5b/T2 review fix). An id is inserted right after
    /// dequeue and removed once its transfer is registered OR a terminal state
    /// is reached. A `Set` because multiple slots may resolve at once (M5c/T4).
    private var resolvingJobIDs: Set<UUID> = []

    // MARK: - Baum-/Gruppen-Zustand (M5b/T3)

    /// Buchhaltung für einen rekursiven Ordner-Transfer. Referenztyp, damit
    /// verstreute Mutationen (aus `setStatus`, der Expansion und `finishExpansion`)
    /// ohne Rück-Zuweisung in `groups` sichtbar werden.
    private final class TreeGroup {
        /// Noch nicht-terminale Items dieser Gruppe.
        var remaining = 0
        /// Expansion hat aufgehört zu laufen (regulär ODER via Cancel).
        var expansionDone = false
        /// Expansion hat den Baum vollständig durchlaufen (NICHT gecancelt).
        var expansionSucceeded = false
        /// Mindestens ein Item ist `.finished` geworden.
        var anyFinished = false
        /// onCompleted bereits gefeuert — Exactly-once-Riegel.
        var fired = false
        let onCompleted: (@MainActor () async -> Void)?
        init(onCompleted: (@MainActor () async -> Void)?) { self.onCompleted = onCompleted }
    }

    private var groups: [UUID: TreeGroup] = [:]
    private var itemGroup: [UUID: UUID] = [:]                       // Item-ID → Gruppen-ID
    private var expansionTasks: [UUID: Task<Void, Never>] = [:]     // Gruppen-ID → Expansions-Task

    public init() {}

    // MARK: - Öffentliche API

    /// Reiht ein und startet den Worker, falls er schläft. Läuft IMMER an —
    /// kein `isRunning`-Verwerfen mehr.
    @discardableResult
    public func enqueue(
        fileName: String, direction: TransferDirection,
        source: any RemoteFileSystem, sourcePath: String,
        destination: any RemoteFileSystem, destinationDirectory: String,
        onCompleted: (@MainActor () async -> Void)?
    ) -> UUID {
        let id = UUID()
        jobs[id] = Job(
            id: id, source: source, sourcePath: sourcePath,
            destination: destination, destinationDirectory: destinationDirectory,
            fileName: fileName, direction: direction, onCompleted: onCompleted)
        order.append(id)
        items.append(Item(id: id, fileName: fileName, direction: direction, status: .queued))
        kickWorker()
        return id
    }

    /// Wie `enqueue`, kehrt aber erst zurück, wenn GENAU dieses Item fertig ist.
    /// Wirft bei failed/cancelled (Promise-Pfad: der Finder braucht die Datei).
    public func enqueueAndWait(
        fileName: String, direction: TransferDirection,
        source: any RemoteFileSystem, sourcePath: String,
        destination: any RemoteFileSystem, destinationDirectory: String
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // Synchron auf dem MainActor: erst einreihen, dann Waiter hinterlegen,
            // bevor der Worker überhaupt loslaufen kann — so kann kein Ergebnis
            // den Waiter verpassen.
            let id = enqueue(
                fileName: fileName, direction: direction,
                source: source, sourcePath: sourcePath,
                destination: destination, destinationDirectory: destinationDirectory,
                onCompleted: nil)
            waiters[id] = continuation
        }
    }

    /// Reiht einen kompletten Ordner ein: legt Zielverzeichnisse an (top-down)
    /// und enqueued jede Datei als eigenes Queue-Item. `onCompleted` feuert genau
    /// einmal, wenn ALLE Items des Baums terminal sind (finished/failed/skipped/
    /// cancelled) — auch bei Teilfehlern. Symlinks werden übersprungen (Item mit
    /// Status `.skipped` und Namensuffix " →"). Expansions-Fehler (list/mkdir)
    /// erscheinen als `.failed`-Item unter dem Ordnernamen mit "/"-Suffix.
    ///
    /// Die Expansion läuft als eigene MainActor-Task VOR den Transfers (BFS/DFS
    /// top-down): erst `createDirectory(dest/dirName)`, dann `list(source)` —
    /// Dateien via `enqueue` (samt T2-Konfliktlogik), Unterverzeichnisse rekursiv.
    ///
    /// onCompleted-Regel bei Abbruch: Wird die Queue via `cancelAll` VOLLSTÄNDIG
    /// abgebrochen (kein Item hat `.finished` erreicht UND die Expansion wurde
    /// gecancelt statt regulär beendet), feuert onCompleted NICHT — ein Refresh
    /// nach kompletter Stornierung wäre sinnlos. Sobald aber mindestens ein Item
    /// fertig wurde ODER die Expansion regulär durchlief, feuert es.
    public func enqueueTree(
        directoryName: String, direction: TransferDirection,
        source: any RemoteFileSystem, sourceDirectory: String,
        destination: any RemoteFileSystem, destinationDirectory: String,
        onCompleted: (@MainActor () async -> Void)?
    ) {
        let groupID = UUID()
        groups[groupID] = TreeGroup(onCompleted: onCompleted)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.expandTree(
                    directoryName: directoryName, direction: direction,
                    source: source, sourceDirectory: sourceDirectory,
                    destination: destination, destinationDirectory: destinationDirectory,
                    group: groupID)
                self.finishExpansion(groupID, succeeded: true)
            } catch {
                // Nur Cancellation propagiert bis hierher — Zweig-Fehler werden
                // in `expandTree` lokal in `.failed`-Items übersetzt.
                self.finishExpansion(groupID, succeeded: false)
            }
        }
        expansionTasks[groupID] = task
    }

    /// Bricht alles ab: laufenden Transfer canceln, queued → `.cancelled`,
    /// wartende Continuations werfen. Kehrt erst nach Worker-Stopp zurück.
    public func cancelAll() async {
        // 0. Laufende Baum-Expansion(en) stoppen und abwarten, BEVOR queued Items
        //    abgeräumt werden — so entstehen ab hier keine neuen Items mehr
        //    (M5b/T3). `finishExpansion(succeeded: false)` markiert die Gruppen als
        //    gecancelt; deren onCompleted feuert dann nur, falls doch schon ein
        //    Item `.finished` war (s. `maybeFireGroup`).
        let expansions = expansionTasks
        expansionTasks.removeAll()
        for task in expansions.values { task.cancel() }
        for task in expansions.values { await task.value }
        // 1. Alle noch nicht gestarteten (queued) IDs abräumen.
        let queued = order
        order.removeAll()
        for id in queued {
            setStatus(id, .cancelled)
            jobs[id] = nil
            resumeWaiter(id, with: .failure(CancellationError()))
        }
        // 1b. Every slot CURRENTLY in `resolveConflictIfNeeded` (stat probe,
        //     decider prompt, rename probing): dequeued but not yet registered
        //     in `runningTransferTasks` — this window is covered here (M5b/T2
        //     review fix), now a set because several slots may resolve at once.
        //     Exactly-once: `process` sees the missing `jobs[id]` entry and does
        //     NOT touch status/waiter again.
        let resolving = resolvingJobIDs
        resolvingJobIDs.removeAll()
        for id in resolving {
            setStatus(id, .cancelled)
            jobs[id] = nil
            resumeWaiter(id, with: .failure(CancellationError()))
        }
        // 2. Cancel every active transfer — each copyFile ends with
        //    CancellationError (cooperative, T2) and `process` marks its item
        //    `.cancelled`.
        for task in runningTransferTasks.values { task.cancel() }
        // 3. Await all slot tasks to unwind. `order` is now empty, so no slot
        //    re-fills; each `process` runs out and calls `slotFinished`. May
        //    block until an open decider prompt returns (documented/accepted) —
        //    but no slot transfers after cancel (see above). A snapshot of the
        //    task handles is stable even as `slotFinished` mutates the dict.
        let active = Array(processTasks.values)
        for task in active { await task.value }
    }

    /// Entfernt finished/failed/cancelled/skipped aus der Liste.
    public func clearCompleted() {
        items.removeAll { item in
            switch item.status {
            case .finished, .failed, .cancelled, .skipped: return true
            case .queued, .running: return false
            }
        }
    }

    // MARK: - Worker

    /// Fills free slots with queued items in strict FIFO order, up to
    /// `maxConcurrent`. Idempotent and safe to call repeatedly — from `enqueue`,
    /// when a slot frees (`slotFinished`), or when the limit is raised.
    ///
    /// The dequeued id is inserted into `resolvingJobIDs` SYNCHRONOUSLY here, at
    /// the moment the slot is committed. That closes the window between spawning
    /// a slot's task and its `process` body actually running: `cancelAll` can
    /// only interleave at an await, so from this synchronous commit onward the
    /// item is always covered by exactly one of the `cancelAll` sweeps
    /// (resolving → then running).
    private func kickWorker() {
        while processTasks.count < maxConcurrent, let jobID = nextQueuedID() {
            resolvingJobIDs.insert(jobID)
            let task = Task { @MainActor [weak self] in
                await self?.process(jobID)
                self?.slotFinished(jobID)
            }
            processTasks[jobID] = task
        }
    }

    /// A slot's `process` returned: free the slot and try to fill it with the
    /// next queued item (FIFO). Once nothing is left running or waiting, the
    /// batch-scoped "apply to all" rule expires (as in the old serial drain).
    private func slotFinished(_ jobID: UUID) {
        processTasks[jobID] = nil
        kickWorker()
        if processTasks.isEmpty && order.isEmpty {
            queueRule = nil
        }
    }

    private func nextQueuedID() -> UUID? {
        order.isEmpty ? nil : order.removeFirst()
    }

    private func process(_ jobID: UUID) async {
        // `resolvingJobIDs` already holds `jobID` (inserted in `kickWorker` when
        // the slot was committed). If `cancelAll` already cleared this job, bail
        // — status/waiter were handled there (exactly-once).
        guard let job = jobs[jobID] else { return }

        // Konfliktprüfung VOR dem Engine-Aufruf; Prompts serialisieren FIFO.
        let outcome = await resolveConflictIfNeeded(job: job)

        // `cancelAll` kann während des obigen Awaits (stat-Probe, Decider,
        // Rename-Probing) bereits zugeschlagen haben: Status ist dann schon
        // `.cancelled`, der Waiter schon geworfen, `jobs[jobID]` schon weg.
        // Exactly-once: hier NICHT nochmal auflösen und NICHT transferieren.
        guard jobs[jobID] != nil else { return }
        // The slot moves from "resolving" to "transferring" synchronously below
        // (no await in between) — `cancelAll`'s running-sweep covers it from here.
        resolvingJobIDs.remove(jobID)

        let effectiveFileName: String
        switch outcome {
        case .proceed(let name):
            effectiveFileName = name
            // Bei `.rename` den angezeigten Namen aktualisieren.
            if name != job.fileName, let index = items.firstIndex(where: { $0.id == jobID }) {
                items[index].fileName = name
            }
        case .skip:
            setStatus(jobID, .skipped)
            jobs[jobID] = nil
            // onCompleted wird NICHT gerufen; Waiter wirft (Datei kam nicht an).
            resumeWaiter(jobID, with: .failure(CancellationError()))
            return
        case .cancel:
            setStatus(jobID, .cancelled)
            jobs[jobID] = nil
            resumeWaiter(jobID, with: .failure(CancellationError()))
            return
        case .failed(let message, let error):
            setStatus(jobID, .failed(message))
            jobs[jobID] = nil
            resumeWaiter(jobID, with: .failure(error))
            return
        }

        setStatus(jobID, .running(TransferProgress(bytesTransferred: 0, totalBytes: nil)))

        // Geordnete Zustellung: AsyncStream puffert in Reihenfolge, EIN Konsument
        // aktualisiert den Status — kein Task-pro-Chunk, kein Race mit .finished.
        let (progressStream, progressContinuation) = AsyncStream<TransferProgress>.makeStream()
        let consumer = Task { @MainActor [weak self] in
            for await progress in progressStream {
                self?.setStatus(jobID, .running(progress))
            }
        }

        // Nur Sendable-Werte in die Transfer-Task ziehen (kein Job/onCompleted).
        let source = job.source
        let sourcePath = job.sourcePath
        let destination = job.destination
        let destinationDirectory = job.destinationDirectory
        let fileName = effectiveFileName
        let transfer = Task<Void, Error> {
            try await TransferEngine.copyFile(
                from: source, sourcePath: sourcePath,
                to: destination, destinationDirectory: destinationDirectory, fileName: fileName,
                onProgress: { progressContinuation.yield($0) }
            )
        }
        runningTransferTasks[jobID] = transfer

        do {
            try await transfer.value
            progressContinuation.finish()
            await consumer.value
            setStatus(jobID, .finished)
            jobs[jobID] = nil
            runningTransferTasks[jobID] = nil
            if let onCompleted = job.onCompleted { await onCompleted() }
            resumeWaiter(jobID, with: .success(()))
        } catch is CancellationError {
            progressContinuation.finish()
            await consumer.value
            setStatus(jobID, .cancelled)
            jobs[jobID] = nil
            runningTransferTasks[jobID] = nil
            resumeWaiter(jobID, with: .failure(CancellationError()))
        } catch {
            progressContinuation.finish()
            await consumer.value
            setStatus(jobID, .failed(Self.message(for: error)))
            jobs[jobID] = nil
            runningTransferTasks[jobID] = nil
            resumeWaiter(jobID, with: .failure(error))
        }
    }

    // MARK: - Konfliktlogik

    /// Prüft vor dem Transfer, ob das Ziel schon existiert, und löst einen
    /// etwaigen Konflikt gemäß Queue-Regel bzw. `conflictDecider` auf.
    private func resolveConflictIfNeeded(job: Job) async -> Outcome {
        // Pfad-Join IDENTISCH zu TransferEngine.copyFile (RemotePath.join).
        let destinationPath = RemotePath.join(job.destinationDirectory, job.fileName)
        do {
            _ = try await job.destination.stat(path: destinationPath)
        } catch RemoteFSError.notFound {
            return .proceed(fileName: job.fileName)   // kein Konflikt
        } catch {
            return .failed(message: Self.message(for: error), error: error)
        }

        // Ziel existiert → Konflikt. Auflösung bestimmen.
        let resolution: ConflictResolution
        if let rule = queueRule {
            resolution = rule                         // aktive Regel: keine Rückfrage
        } else if let decider = conflictDecider {
            let conflict = TransferConflict(
                fileName: job.fileName,
                destinationDirectory: job.destinationDirectory,
                direction: job.direction)
            // Serialize prompts across parallel slots: at most one decider is
            // open at a time, FIFO. Only the prompt itself is gated.
            await conflictGate.acquire()
            // Re-check: `cancelAll` may have fired while we waited for the gate.
            // Bail without prompting (and always release, so the gate never leaks).
            guard jobs[job.id] != nil else {
                conflictGate.release()
                return .cancel
            }
            let decision = await decider(conflict)
            conflictGate.release()
            guard let decision else {
                return .cancel                        // nil == Abbrechen
            }
            resolution = decision.resolution
            if decision.applyToAll { queueRule = decision.resolution }
        } else {
            resolution = .overwrite                   // Default: stilles Überschreiben (M5a)
        }

        switch resolution {
        case .overwrite:
            return .proceed(fileName: job.fileName)
        case .skip:
            return .skip
        case .rename:
            return await freeRenameOutcome(job: job)
        }
    }

    /// Sucht einen freien Namen "name (2).ext", "name (3).ext", … per `stat`-Probe.
    private func freeRenameOutcome(job: Job) async -> Outcome {
        let (stem, ext) = Self.splitName(job.fileName)
        var counter = 2
        while counter <= 999 {
            let candidate = "\(stem) (\(counter))\(ext)"
            let candidatePath = RemotePath.join(job.destinationDirectory, candidate)
            do {
                _ = try await job.destination.stat(path: candidatePath)
                // existiert → nächster Kandidat
            } catch RemoteFSError.notFound {
                return .proceed(fileName: candidate)  // frei
            } catch {
                return .failed(message: Self.message(for: error), error: error)
            }
            counter += 1
        }
        return .failed(message: "Kein freier Name gefunden.", error: NoFreeNameError())
    }

    /// Zerlegt einen Dateinamen am LETZTEN Punkt in Basisname und Extension
    /// (inklusive Punkt). Ohne Punkt (oder führender Punkt) ⇒ leere Extension.
    static func splitName(_ fileName: String) -> (stem: String, ext: String) {
        guard let dotIndex = fileName.lastIndex(of: "."), dotIndex != fileName.startIndex else {
            return (fileName, "")
        }
        return (String(fileName[..<dotIndex]), String(fileName[dotIndex...]))
    }

    // MARK: - Baum-Expansion (M5b/T3)

    /// Rekursiver Top-down-Abstieg: legt zuerst `dest/dirName` an, listet dann
    /// `sourceDirectory` und arbeitet die Einträge ab (Dateien → `enqueue`,
    /// Unterverzeichnisse → rekursiv, Symlinks → terminales `.skipped`-Item).
    /// Wirft ausschließlich `CancellationError`; Zweig-lokale list/mkdir-Fehler
    /// werden in `.failed`-Items übersetzt und beenden nur diesen Zweig.
    private func expandTree(
        directoryName: String, direction: TransferDirection,
        source: any RemoteFileSystem, sourceDirectory: String,
        destination: any RemoteFileSystem, destinationDirectory: String,
        group groupID: UUID
    ) async throws {
        try Task.checkCancellation()
        let destDir = RemotePath.join(destinationDirectory, directoryName)

        // Zielverzeichnis top-down anlegen.
        do {
            try await destination.createDirectory(at: destDir)
        } catch {
            try Task.checkCancellation()   // war es Cancellation, propagieren
            addTerminalItem(
                group: groupID, name: directoryName + "/",
                direction: direction, status: .failed(Self.message(for: error)))
            return
        }

        // Quellverzeichnis auflisten.
        let entries: [RemoteFileItem]
        do {
            entries = try await source.list(path: sourceDirectory)
        } catch {
            try Task.checkCancellation()
            addTerminalItem(
                group: groupID, name: directoryName + "/",
                direction: direction, status: .failed(Self.message(for: error)))
            return
        }

        for entry in entries {
            try Task.checkCancellation()
            switch entry.kind {
            case .file:
                // Datei-Items durchlaufen die normale enqueue-/Konfliktlogik.
                let id = enqueue(
                    fileName: entry.name, direction: direction,
                    source: source, sourcePath: entry.path,
                    destination: destination, destinationDirectory: destDir,
                    onCompleted: nil)
                registerGroupItem(id, group: groupID)
            case .directory:
                try await expandTree(
                    directoryName: entry.name, direction: direction,
                    source: source, sourceDirectory: entry.path,
                    destination: destination, destinationDirectory: destDir,
                    group: groupID)
            case .symlink, .other:
                // Nicht folgen: terminales `.skipped`-Item mit " →"-Suffix.
                addTerminalItem(
                    group: groupID, name: entry.name + " →",
                    direction: direction, status: .skipped)
            }
        }
    }

    // MARK: - Gruppen-Buchhaltung (M5b/T3)

    /// Ordnet ein bereits eingereites Item einer Gruppe zu und zählt es als
    /// offen. Muss synchron direkt nach `enqueue` laufen (kein Await dazwischen),
    /// sonst könnte der Worker das Item vor der Registrierung terminalisieren.
    private func registerGroupItem(_ id: UUID, group groupID: UUID) {
        guard let group = groups[groupID] else { return }
        group.remaining += 1
        itemGroup[id] = groupID
    }

    /// Hängt ein SOFORT terminales Item an (Symlink-Skip oder Expansions-Fehler)
    /// und routet es durch denselben Choke-Point wie alle anderen.
    private func addTerminalItem(
        group groupID: UUID, name: String,
        direction: TransferDirection, status: Item.Status
    ) {
        let id = UUID()
        items.append(Item(id: id, fileName: name, direction: direction, status: .queued))
        registerGroupItem(id, group: groupID)
        setStatus(id, status)   // löst groupItemBecameTerminal aus
    }

    /// Vom `setStatus`-Choke-Point aufgerufen, sobald ein Gruppen-Item terminal
    /// wird: dekrementiert und prüft auf Gruppen-Abschluss.
    private func groupItemBecameTerminal(_ id: UUID, status: Item.Status) {
        guard let groupID = itemGroup.removeValue(forKey: id), let group = groups[groupID] else { return }
        group.remaining -= 1
        if case .finished = status { group.anyFinished = true }
        maybeFireGroup(groupID)
    }

    /// Markiert die Expansion einer Gruppe als beendet (regulär oder gecancelt)
    /// und prüft auf Abschluss — Items könnten schon vorher alle terminal sein.
    private func finishExpansion(_ groupID: UUID, succeeded: Bool) {
        expansionTasks[groupID] = nil
        guard let group = groups[groupID] else { return }
        group.expansionDone = true
        group.expansionSucceeded = succeeded
        maybeFireGroup(groupID)
    }

    /// Feuert `onCompleted` genau einmal, wenn ALLE Items terminal sind UND die
    /// Expansion nicht mehr läuft. Bei Voll-Abbruch (nichts fertig, Expansion
    /// gecancelt) wird nur aufgeräumt, ohne zu feuern.
    private func maybeFireGroup(_ groupID: UUID) {
        guard let group = groups[groupID], !group.fired else { return }
        guard group.expansionDone, group.remaining == 0 else { return }
        guard group.anyFinished || group.expansionSucceeded else {
            groups[groupID] = nil   // Voll-Abbruch: kein Refresh nötig
            return
        }
        group.fired = true
        let onCompleted = group.onCompleted
        groups[groupID] = nil
        if let onCompleted {
            Task { @MainActor in await onCompleted() }
        }
    }

    // MARK: - Helfer

    private func setStatus(_ id: UUID, _ status: Item.Status) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let wasTerminal = items[index].status.isTerminal
        items[index].status = status
        // Einziger Choke-Point der Gruppen-Buchhaltung: genau beim Übergang
        // nicht-terminal → terminal dekrementieren (M5b/T3). Verstreute
        // Dekrements würden Fälle verpassen.
        if status.isTerminal && !wasTerminal {
            groupItemBecameTerminal(id, status: status)
        }
    }

    private func resumeWaiter(_ id: UUID, with result: Result<Void, Error>) {
        guard let continuation = waiters.removeValue(forKey: id) else { return }
        continuation.resume(with: result)
    }

    static func message(for error: Error) -> String {
        switch error {
        case RemoteFSError.notFound(let path):
            return "Datei nicht gefunden: \(path)"
        case RemoteFSError.permissionDenied(let path):
            return "Keine Berechtigung für: \(path)"
        case RemoteFSError.connectionFailed(let reason):
            return "Verbindung verloren: \(reason)"
        case RemoteFSError.protocolError(let reason):
            return "Übertragung fehlgeschlagen: \(reason)"
        default:
            return "Übertragung fehlgeschlagen: \(String(describing: error))"
        }
    }
}

/// Minimal FIFO async gate (binary semaphore). `acquire()` suspends callers in
/// arrival order when the gate is held; each `release()` wakes exactly the
/// longest-waiting caller — strictly fair, no unfair wakeups. Confined to the
/// `TransferQueueViewModel`'s MainActor, so its mutable state is race-free.
@MainActor
final class FIFOGate {
    private var available = true
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if available {
            available = false
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            available = true
        } else {
            // Hand the gate directly to the next waiter (stays held, FIFO).
            waiters.removeFirst().resume()
        }
    }
}
