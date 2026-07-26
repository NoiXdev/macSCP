# M6a — Polish-Backlog Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Alle offenen Ledger-Backlog-Punkte schließen: globaler Bandbreiten-Bucket (ersetzt die virtuelle Drossel-Uhr), Gruppen-Abbruch im Konflikt-Dialog, Edit-Integrations-Fixes, Formular-/Session-Refactorings, a11y und Code-Hygiene — danach ist der Code release-fertig für M6b.

**Architecture:** Neuer Core-Actor `BandwidthBucket` (Token-Bucket, echte injizierbare Uhr) wird von `TransferQueueViewModel` pro Richtung besessen und an `TransferEngine.copyFile` durchgereicht (Signaturwechsel: `throttle: BandwidthBucket?` statt `bytesPerSecondLimit`+`sleep`). Gruppen-Abbruch als neuer Sweep `cancelGroup` in der Queue, gebaut nach dem exactly-once-Muster von `cancelAll`. Alle übrigen Punkte sind lokale Fixes in App- und Core-Layer ohne neue Abstraktionen.

**Tech Stack:** Swift 6 Toolchain / `.swiftLanguageMode(.v5)`, Swift Testing (`@Test`/`#expect`), SwiftUI, macOS 15+.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-26-m6a-polish-backlog-design.md` — bindend.
- Sicherheits-/Architektur-Invarianten unangetastet: TOFU-Härte, Secrets nur im Keychain, UI-owned Lifecycles, FIFO-Startordnung, exactly-once-Waiter/onCompleted.
- Queue-Invarianten beim Gruppen-Abbruch: `onCompleted` exactly-once, kein Item doppelt terminalisiert, kein Waiter doppelt resumed, bereits kopierte Dateien bleiben liegen.
- Code + Kommentare NUR Englisch; neue UI-/Fehlertexte katalogisiert in `en.lproj`/`de.lproj` (App: `Sources/MacSCPApp/Resources/`, Core: `Sources/macSCPCore/Resources/`).
- Conventional Commits (Englisch), Footer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- `swift build` und volle `swift test` nach jedem Task grün (Ausgangslage 295 Tests; gated Suiten laufen NUR beim Abschluss mit Docker-Rig).
- TDD: neue Logik erst rot beweisen, dann grün.
- Umgebungs-Hinweis: Bash-Fehler „claude-opus-4-8 is temporarily unavailable … cannot determine the safety" sind KEINE Permission-Denials — warten und identisch wiederholen.

## Schedule

T1 → T2 → T3 → T4 → T5 sequenziell (T2–T4 teilen `TransferQueueViewModel.swift`). T6 = Abschluss (Koordinator).

---

### Task 1: BandwidthBucket (Core)

**Files:**
- Create: `Sources/macSCPCore/RemoteFS/BandwidthBucket.swift`
- Test: `Tests/macSCPCoreTests/BandwidthBucketTests.swift`

**Interfaces:**
- Consumes: nichts Neues (nur `ContinuousClock`, `Duration.secondsAsDouble`/`seconds(fromDouble:)` aus `TransferEngine.swift` — beide `internal` im selben Modul).
- Produces: `public actor BandwidthBucket` mit `init(bytesPerSecond: Int, now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }, sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) })`, `func consume(_ bytes: Int) async throws`, `func setRate(bytesPerSecond: Int)`. T2 verlässt sich exakt auf diese Namen.

**Semantik (bindend):**
- Kapazität (Burst) = 1 Sekunde Rate. Tokens starten voll.
- `consume` wartet, solange `tokens <= 0`; sobald `tokens > 0`, zieht es die VOLLEN `bytes` ab (darf negativ werden). Damit funktionieren auch Chunks größer als die Kapazität (64-KiB-Chunks bei Limit < 64 KB/s) ohne Verhungern; die Durchschnittsrate bleibt exakt das Limit, der Burst ist durch Kapazität + einen Chunk begrenzt.
- Refill kontinuierlich: bei jedem `consume`/Warte-Durchlauf `tokens = min(capacity, tokens + elapsedSeconds * rate)` anhand der injizierten Uhr.
- Wartedauer pro Schleifendurchlauf: `(-tokens + 1) / rate` Sekunden (bis die Tokens wieder positiv würden). Nach jedem `sleep` wird neu gerefillt und die Bedingung erneut geprüft (mehrere Konsumenten: Actor-Reentranz ist ok, die Schleife re-checkt).
- `consume` ist kooperativ cancelbar: der injizierte `sleep` wirft bei Task-Cancellation (`Task.sleep`-Default); zusätzlich prüft die Schleife `try Task.checkCancellation()` vor jedem Durchlauf.
- `setRate` setzt Rate und Kapazität neu und klemmt `tokens` auf die neue Kapazität (nach oben); negative Tokens bleiben (Schulden werden nicht erlassen).
- `bytesPerSecond <= 0` im Init/`setRate` ist Programmierfehler des Aufrufers — die Queue erzeugt für „0 = aus" gar keinen Bucket. Klemme defensiv auf mindestens 1.

- [ ] **Step 1: Failing Tests schreiben** — `Tests/macSCPCoreTests/BandwidthBucketTests.swift`:

```swift
import Foundation
import Testing
@testable import macSCPCore

/// Deterministic clock driver for BandwidthBucket tests: `sleep` advances the
/// virtual instant instead of actually sleeping, so tests never wait.
private final class VirtualTime: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now
    private(set) var totalSlept = Duration.zero

    var now: @Sendable () -> ContinuousClock.Instant {
        { [self] in lock.withLock { instant } }
    }

    var sleep: @Sendable (Duration) async throws -> Void {
        { [self] duration in
            try Task.checkCancellation()
            lock.withLock {
                instant = instant.advanced(by: duration)
                totalSlept += duration
            }
        }
    }
}

@Suite("BandwidthBucket")
struct BandwidthBucketTests {
    @Test("first consume within the burst capacity passes without sleeping")
    func burstPassesImmediately() async throws {
        let time = VirtualTime()
        let bucket = BandwidthBucket(bytesPerSecond: 1000, now: time.now, sleep: time.sleep)
        try await bucket.consume(800)
        #expect(time.totalSlept == .zero)
    }

    @Test("sustained consumption is paced to the configured rate")
    func sustainedRateIsPaced() async throws {
        let time = VirtualTime()
        let bucket = BandwidthBucket(bytesPerSecond: 1000, now: time.now, sleep: time.sleep)
        // 10 chunks of 1000 bytes = 10_000 bytes at 1000 B/s. The first
        // 1000 ride the initial burst, the remaining 9000 must be paced:
        // total sleep ≈ 9 seconds (tolerance for the +1-byte rounding).
        for _ in 0..<10 { try await bucket.consume(1000) }
        let slept = time.totalSlept.secondsAsDouble
        #expect(slept > 8.9 && slept < 9.2)
    }

    @Test("a chunk larger than the capacity does not starve")
    func oversizedChunkPasses() async throws {
        let time = VirtualTime()
        let bucket = BandwidthBucket(bytesPerSecond: 100, now: time.now, sleep: time.sleep)
        // Capacity is 100 tokens; a 500-byte chunk must still pass (debt
        // model) and the NEXT consume pays it off by waiting ≈ 5 seconds.
        try await bucket.consume(500)
        try await bucket.consume(100)
        let slept = time.totalSlept.secondsAsDouble
        #expect(slept > 3.9 && slept < 5.2)
    }

    @Test("two consumers share one bucket at the aggregate rate")
    func sharedBucketPacesAggregate() async throws {
        let time = VirtualTime()
        let bucket = BandwidthBucket(bytesPerSecond: 1000, now: time.now, sleep: time.sleep)
        // 2 × 5 × 1000 bytes = 10_000 bytes through ONE bucket: same math
        // as `sustainedRateIsPaced` — total virtual sleep ≈ 9 s, NOT ≈ 4.5 s
        // per consumer in parallel wall-clock (they serialize on the actor).
        async let first: Void = {
            for _ in 0..<5 { try await bucket.consume(1000) }
        }()
        async let second: Void = {
            for _ in 0..<5 { try await bucket.consume(1000) }
        }()
        _ = try await (first, second)
        let slept = time.totalSlept.secondsAsDouble
        #expect(slept > 8.9 && slept < 9.3)
    }

    @Test("setRate applies to subsequent pacing")
    func setRateApplies() async throws {
        let time = VirtualTime()
        let bucket = BandwidthBucket(bytesPerSecond: 1000, now: time.now, sleep: time.sleep)
        try await bucket.consume(1000)              // eat the initial burst
        await bucket.setRate(bytesPerSecond: 2000)  // double the rate
        try await bucket.consume(2000)              // debt from chunk 1 + this
        try await bucket.consume(2000)
        // After the burst everything is paced at 2000 B/s: 4000 bytes ≈ 2 s
        // (plus paying off the 0-token state left by the burst chunk).
        let slept = time.totalSlept.secondsAsDouble
        #expect(slept > 1.9 && slept < 2.3)
    }

    @Test("consume throws on task cancellation instead of sleeping forever")
    func consumeIsCancellable() async {
        let time = VirtualTime()
        let bucket = BandwidthBucket(
            bytesPerSecond: 1, now: time.now,
            // Never advances time: without cancellation this would loop.
            sleep: { _ in try Task.checkCancellation() })
        let task = Task {
            try await bucket.consume(1_000_000)   // burst passes (tokens 1 > 0)
            try await bucket.consume(1)           // now deep in debt → waits
        }
        task.cancel()
        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
    }
}
```

- [ ] **Step 2: Rot beweisen** — `swift test --filter BandwidthBucketTests` ⇒ FAIL (Typ existiert nicht / Compile-Error zählt als rot).

- [ ] **Step 3: Implementieren** — `Sources/macSCPCore/RemoteFS/BandwidthBucket.swift`:

```swift
import Foundation

/// Shared token bucket pacing all transfers of one direction to a single
/// aggregate bandwidth limit (M6a). Owned per direction by
/// `TransferQueueViewModel`; every concurrent `copyFile` calls
/// `consume(_:)` before each chunk, so N parallel transfers share exactly
/// one limit instead of getting N × limit (the M5c per-transfer virtual
/// clock this replaces).
///
/// Debt model: `consume` waits only until the token balance is POSITIVE,
/// then deducts the full chunk size — the balance may go negative. That
/// keeps chunks larger than the burst capacity (64 KiB chunks under a
/// sub-64-KB/s limit) from starving while still pacing the average rate
/// exactly to the limit; the burst is bounded by capacity + one chunk.
///
/// Clock and sleep are injectable so tests drive a virtual timeline and
/// never actually sleep. The defaults use the real `ContinuousClock` and
/// `Task.sleep` — unlike the replaced virtual clock, real elapsed transfer
/// time refills tokens, so an already-slow link is no longer throttled
/// additionally (the M5c over-throttling).
public actor BandwidthBucket {
    private var rate: Double            // tokens (bytes) per second
    private var capacity: Double        // burst bound: 1 second of rate
    private var tokens: Double
    private var lastRefill: ContinuousClock.Instant
    private let now: @Sendable () -> ContinuousClock.Instant
    private let sleep: @Sendable (Duration) async throws -> Void

    public init(
        bytesPerSecond: Int,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        // A non-positive rate is a caller bug (the queue creates no bucket
        // for "0 = unlimited") — clamp defensively rather than trap.
        self.rate = Double(max(1, bytesPerSecond))
        self.capacity = self.rate
        self.tokens = self.rate         // start with a full burst
        self.now = now
        self.sleep = sleep
        self.lastRefill = now()
    }

    /// Updates the rate (Settings change at runtime). Tokens are clamped to
    /// the new capacity; a negative balance (debt) is deliberately kept.
    public func setRate(bytesPerSecond: Int) {
        refill()
        rate = Double(max(1, bytesPerSecond))
        capacity = rate
        tokens = min(tokens, capacity)
    }

    /// Waits until the token balance is positive, then deducts `bytes`.
    /// Cooperatively cancellable: throws `CancellationError` from the
    /// injected `sleep` (Task.sleep default) or the explicit check.
    public func consume(_ bytes: Int) async throws {
        while true {
            try Task.checkCancellation()
            refill()
            if tokens > 0 {
                tokens -= Double(bytes)
                return
            }
            // Sleep until the balance would turn positive again (+1 token
            // against rounding), then re-check — several consumers may have
            // been admitted meanwhile (actor reentrancy), so this loops.
            let waitSeconds = (-tokens + 1) / rate
            try await sleep(Duration.seconds(fromDouble: waitSeconds))
        }
    }

    private func refill() {
        let instant = now()
        let elapsed = (instant - lastRefill).secondsAsDouble
        lastRefill = instant
        guard elapsed > 0 else { return }
        tokens = min(capacity, tokens + elapsed * rate)
    }
}
```

- [ ] **Step 4: Grün beweisen** — `swift test --filter BandwidthBucketTests` ⇒ alle PASS; danach volle Suite `swift test` ⇒ 295 + neue grün.
- [ ] **Step 5: Commit** — `feat: add the shared bandwidth token bucket`.

---

### Task 2: Engine + Queue auf den Bucket umstellen

**Files:**
- Modify: `Sources/macSCPCore/RemoteFS/TransferEngine.swift` (Signatur + Drossel-Block, Zeilen 83–164)
- Modify: `Sources/macSCPCore/Presentation/TransferQueueViewModel.swift` (Limit-Properties Zeilen 122–130, `process`-Engine-Aufruf Zeilen 605–622)
- Test: `Tests/macSCPCoreTests/TransferEngineTests.swift` (Drossel-Tests migrieren), `Tests/macSCPCoreTests/TransferQueueViewModelTests.swift` (Richtungs-Zuordnung)

**Interfaces:**
- Consumes: `BandwidthBucket` aus T1 (`consume(_:)`, `init(bytesPerSecond:now:sleep:)`).
- Produces: `TransferEngine.copyFile(from:sourcePath:to:destinationDirectory:fileName:resume:throttle:onProgress:)` — Parameter `bytesPerSecondLimit: Int` und `sleep:` ENTFALLEN ersatzlos, neu `throttle: BandwidthBucket? = nil`. `TransferQueueViewModel` behält die öffentlichen Properties `uploadLimitBytesPerSec`/`downloadLimitBytesPerSec: Int` (API-kompatibel für ContentView), hält intern aber `uploadBucket`/`downloadBucket: BandwidthBucket?` (internal, für Tests sichtbar via `@testable`).

**Engine-Änderungen im Detail:**
1. Doku-Kommentar der Parameter `bytesPerSecondLimit`/`sleep` (Zeilen 83–87) ersetzen durch einen `throttle`-Absatz: shared bucket, nil = unlimitiert, Verweis auf `BandwidthBucket`-Doku.
2. Signatur: `resume: Bool = false, throttle: BandwidthBucket? = nil,` (kein `sleep`-Hook mehr).
3. Den gesamten Virtual-Clock-Block entfernen: die Variable `throttledElapsed` (Zeile 143 inkl. Kommentarblock 129–142) und den `if bytesPerSecondLimit > 0 { … }`-Block (Zeilen 151–164). Stattdessen im `unfolding`-Closure nach dem `onProgress`-Aufruf:

```swift
            // Shared throttle (M6a): every chunk asks the direction's bucket
            // before being handed to the destination. `consume` also throws
            // on task cancellation — in addition to the check above, not in
            // place of it.
            if let throttle {
                try await throttle.consume(chunk.count)
            }
```

4. Die `Duration`-Extension (Zeilen 34–50) bleibt — `BandwidthBucket` und `RateWindow` nutzen sie weiter.

**Queue-Änderungen im Detail:**
1. Property-Block (Zeilen 122–130) ersetzen:

```swift
    /// Bandwidth ceilings in bytes/second, direction-dependent; `0` (default)
    /// = unlimited. Backed by ONE shared `BandwidthBucket` per direction
    /// (M6a): all concurrent transfers of a direction share the limit in
    /// aggregate. CHANGING a non-zero limit re-rates the existing bucket, so
    /// it applies live even to running transfers; ENABLING/DISABLING (0 ↔ n)
    /// swaps the bucket reference and therefore only applies to transfers
    /// starting afterwards (running ones keep the reference they resolved).
    public var uploadLimitBytesPerSec: Int = 0 {
        didSet { uploadBucket = Self.updatedBucket(uploadBucket, bytesPerSecond: uploadLimitBytesPerSec) }
    }
    public var downloadLimitBytesPerSec: Int = 0 {
        didSet { downloadBucket = Self.updatedBucket(downloadBucket, bytesPerSecond: downloadLimitBytesPerSec) }
    }

    /// The per-direction shared buckets handed to `TransferEngine.copyFile`.
    /// Internal for test visibility.
    private(set) var uploadBucket: BandwidthBucket?
    private(set) var downloadBucket: BandwidthBucket?

    private static func updatedBucket(
        _ bucket: BandwidthBucket?, bytesPerSecond: Int
    ) -> BandwidthBucket? {
        guard bytesPerSecond > 0 else { return nil }
        guard let bucket else { return BandwidthBucket(bytesPerSecond: bytesPerSecond) }
        // Keep the instance (running transfers hold it) and re-rate it. The
        // hop is fire-and-forget by design: pacing catches up on the next
        // consume, there is nothing to await for correctness.
        Task { await bucket.setRate(bytesPerSecond: bytesPerSecond) }
        return bucket
    }
```

2. In `process` (Zeilen 605–622): den `bytesPerSecondLimit`-Let (Zeilen 605–610 inkl. Kommentar) ersetzen durch

```swift
        // Direction-dependent shared bucket (M6a): resolved HERE, at the
        // moment the transfer actually starts — a Settings change rebuilds
        // the bucket and therefore only applies to items starting next.
        let throttle = job.direction == .upload ? uploadBucket : downloadBucket
```

   und im `TransferEngine.copyFile`-Aufruf `bytesPerSecondLimit: bytesPerSecondLimit,` durch `throttle: throttle,` ersetzen.

**Test-Migration (bestehende Drossel-Tests in `TransferEngineTests.swift`):** Die M5c/T5-Tests injizieren heute einen zählenden `sleep` in `copyFile`. Sie werden auf T1s Muster umgestellt: einen `BandwidthBucket` mit `VirtualTime`-Treiber (Helper aus T1s Testdatei in eine geteilte Datei ziehen: **Create** `Tests/macSCPCoreTests/VirtualTime.swift`, aus `BandwidthBucketTests.swift` dorthin verschieben, `final class VirtualTime` ohne `private`) an `copyFile(throttle:)` übergeben und die aufsummierte virtuelle Schlafzeit asserten (gleiche Größenordnung wie vorher: transferierte Bytes ÷ Limit, abzüglich 1 s Burst). Tests, die nur „kein Limit ⇒ kein Sleep" prüften, asserten jetzt `throttle: nil` ⇒ `totalSlept == .zero` via Bucket-Stub entfällt — ohne Bucket gibt es nichts zu asserten; solche Tests auf sinnvolle Varianten reduzieren oder streichen (im Report begründen).

**Neuer Queue-Test (`TransferQueueViewModelTests.swift`):**

```swift
    @Test("direction limits build one shared bucket per direction")
    @MainActor
    func directionLimitsBuildBuckets() {
        let queue = TransferQueueViewModel()
        #expect(queue.uploadBucket == nil && queue.downloadBucket == nil)
        queue.uploadLimitBytesPerSec = 1024
        #expect(queue.uploadBucket != nil && queue.downloadBucket == nil)
        queue.downloadLimitBytesPerSec = 2048
        #expect(queue.downloadBucket != nil)
        // Changing a non-zero limit keeps the SAME bucket instance (running
        // transfers hold it — the change must reach them live).
        let bucketBefore = queue.uploadBucket
        queue.uploadLimitBytesPerSec = 4096
        #expect(queue.uploadBucket === bucketBefore)
        queue.uploadLimitBytesPerSec = 0
        #expect(queue.uploadBucket == nil)
    }
```

- [ ] **Step 1: Queue-Test + ein migrierter Engine-Test rot** — neue Signatur noch nicht da ⇒ Compile-Fehler zählt als rot (`swift test --filter directionLimitsBuildBuckets`).
- [ ] **Step 2: Engine umbauen** (Signatur, Drossel-Block, Doku wie oben).
- [ ] **Step 3: Queue umbauen** (Properties, `process`, Doku wie oben).
- [ ] **Step 4: Drossel-Tests migrieren** (`VirtualTime` nach `Tests/macSCPCoreTests/VirtualTime.swift`, Engine-Tests auf Bucket, tote sleep-Hook-Stubs entfernen).
- [ ] **Step 5: Volle Suite grün** — `swift test` ⇒ alles PASS (Anzahl kann sich durch die Migration leicht ändern; im Report dokumentieren).
- [ ] **Step 6: Commit** — `feat: pace transfers through a shared per-direction bandwidth bucket`.

---

### Task 3: Gruppen-Abbruch + Konflikt-Hygiene (Queue, RISK)

**Files:**
- Modify: `Sources/macSCPCore/Presentation/TransferQueueViewModel.swift` (`process` Zeilen 544–568, `resolveConflictIfNeeded` Zeilen 684–710, neue Methode `cancelGroup`)
- Modify: `Sources/macSCPCore/SSH/CitadelFileSystem.swift:313`, `Sources/macSCPCore/RemoteFS/LocalFileSystem.swift:133`
- Test: `Tests/macSCPCoreTests/TransferQueueViewModelTests.swift`

**Interfaces:**
- Consumes: bestehende private Queue-Maschinerie (`itemGroup`, `order`, `resolvingJobIDs`, `runningTransferTasks`, `expansionTasks`, `setStatus`, `resumeWaiter`) — Namen exakt wie in der Datei.
- Produces: keine neue öffentliche API. Verhalten: Decider-`nil` (Cancel) auf einem Gruppen-Item bricht die ganze Gruppe ab.

**Teil A — `cancelGroup`:** Neue private Methode direkt unter `cancelAll` (nach Zeile 468):

```swift
    /// Conflict-dialog "Cancel" on a tree item aborts the WHOLE folder
    /// transfer (M6a): sweeps this group's queued items, cancels its
    /// in-flight transfers cooperatively, and stops its expansion so no new
    /// items appear. Already-copied files stay in place (nothing is
    /// deleted). Built on the same exactly-once pattern as `cancelAll`:
    /// every swept id has its job cleared synchronously, so a later
    /// `process` guard (`jobs[id] != nil`) cannot double-terminalize it.
    /// Items of OTHER groups and ungrouped items are untouched.
    private func cancelGroup(_ groupID: UUID) {
        // Stop the expansion first — its task observes the cancellation at
        // its next checkpoint and runs `finishExpansion(succeeded: false)`.
        expansionTasks[groupID]?.cancel()
        // Sweep this group's queued (not yet started) items.
        let queuedGroupIDs = order.filter { itemGroup[$0] == groupID }
        order.removeAll { itemGroup[$0] == groupID }
        for id in queuedGroupIDs {
            setStatus(id, .cancelled)
            jobs[id] = nil
            resumeWaiter(id, with: .failure(CancellationError()))
        }
        // Sweep this group's items currently resolving a conflict in another
        // slot (their `process` bails on the missing job, exactly-once).
        let resolving = resolvingJobIDs.filter { itemGroup[$0] == groupID }
        resolvingJobIDs.subtract(resolving)
        for id in resolving {
            setStatus(id, .cancelled)
            jobs[id] = nil
            resumeWaiter(id, with: .failure(CancellationError()))
        }
        // Cancel this group's in-flight transfers cooperatively — each
        // `copyFile` throws `CancellationError` and its `process` marks the
        // item `.cancelled` (partial files stay, as in `cancelAll`).
        for (id, task) in runningTransferTasks where itemGroup[id] == groupID {
            task.cancel()
        }
    }
```

**Teil B — Aufruf im `.cancel`-Zweig von `process`:** Der bestehende Zweig (Zeilen 558–561) wird zu:

```swift
        case .cancel:
            // Capture the group BEFORE setStatus — the terminal transition
            // removes the item's `itemGroup` entry.
            let groupID = itemGroup[jobID]
            setStatus(jobID, .cancelled)
            jobs[jobID] = nil
            resumeWaiter(jobID, with: .failure(CancellationError()))
            // Tree item: cancelling ONE conflict aborts the whole folder
            // transfer (M6a). Single-file items (no group) keep the old
            // behavior — only this item is cancelled.
            if let groupID { cancelGroup(groupID) }
            return
```

**WICHTIG (Begründung für den Reviewer):** `resolveConflictIfNeeded` liefert `.cancel` auch auf dem `cancelAll`-Bail-Pfad (Zeile 699) — dort ist `jobs[job.id]` aber bereits `nil`, `process` kehrt am Guard (Zeile 539) vorher um und erreicht den `.cancel`-Zweig nie. `cancelGroup` läuft also nur für echte Decider-Cancels.

**Teil C — applyToAll-Recheck nach Gate-Acquire:** In `resolveConflictIfNeeded` deckt der Re-Check nach `conflictGate.acquire()` (Zeilen 695–700) nur `cancelAll` ab. Eine Regel, die gesetzt wurde, WÄHREND dieses Item am Gate wartete, wird heute ignoriert ⇒ überflüssiger zweiter Prompt. Den Block (Zeilen 694–707) ersetzen:

```swift
            // Serialize prompts across parallel slots: at most one decider is
            // open at a time, FIFO. Only the prompt itself is gated.
            await conflictGate.acquire()
            // Re-check: `cancelAll` may have fired while we waited for the gate.
            // Bail without prompting (and always release, so the gate never leaks).
            guard jobs[job.id] != nil else {
                conflictGate.release()
                return .cancel
            }
            // Re-check the rule too (M6a): an "apply to all" decision made
            // while this item waited at the gate answers its conflict as
            // well — prompting again would contradict the just-made rule.
            if let rule = queueRule {
                conflictGate.release()
                resolution = rule
            } else {
                let decision = await decider(conflict)
                conflictGate.release()
                guard let decision else {
                    return .cancel                        // nil == cancel
                }
                resolution = decision.resolution
                if decision.applyToAll { queueRule = decision.resolution }
            }
```

(Das `let conflict = TransferConflict(...)` davor bleibt unverändert stehen.)

**Teil D — Meldungs-Fix:** In beiden Dateien den Reason-String `"path exists as a file: \(path)"` ersetzen durch `"path exists and is not a directory: \(path)"` (trifft Datei UND Symlink/Sonstiges korrekt; Reason-Strings sind englische Interna, kein Katalog).

**Neue Tests (in `TransferQueueViewModelTests.swift`; vorhandene Mocks/Muster der Datei wiederverwenden — dort existieren bereits ein Test-FS mit steuerbaren `stat`/Streams und Decider-Helfer; exakt deren Konventionen folgen):**

1. `treeConflictCancelAbortsWholeGroup` — Baum mit 3 Dateien, Datei 2 kollidiert, Decider antwortet `nil`: Datei 2 `.cancelled`, Datei 3 (queued) `.cancelled`, Datei 1 (bereits `.finished`) bleibt `.finished`; `onCompleted` der Gruppe feuert danach genau einmal (anyFinished).
2. `treeConflictCancelLeavesOtherItemsAlone` — gleiche Lage plus ein UNGRUPPIERTES queued Item und eine ZWEITE Gruppe: beide unberührt (`.queued` bzw. laufen weiter durch).
3. `treeConflictCancelCancelsRunningGroupTransfers` — Gruppe mit einem laufenden (blockierten) Transfer + Konflikt-Cancel auf einem zweiten Item: der laufende endet `.cancelled` (kooperativ), `onCompleted` exactly-once.
4. `singleFileConflictCancelKeepsOldBehavior` — Einzeldatei-Konflikt, Decider `nil`: nur dieses Item `.cancelled`, andere queued Items laufen weiter.
5. `queueRuleSetWhileWaitingAtGateIsApplied` — zwei parallele Slots, beide kollidieren; Slot 1 antwortet `overwrite` + applyToAll, Slot 2 wartet am Gate: der Decider wird insgesamt nur EINMAL aufgerufen (Zähler im Decider), Slot 2 folgt der Regel.

- [ ] **Step 1: Tests 1–5 schreiben, rot beweisen** (`swift test --filter TransferQueueViewModelTests` — die neuen schlagen fehl, Bestand bleibt grün).
- [ ] **Step 2: Teil A+B implementieren**, Tests 1–4 grün.
- [ ] **Step 3: Teil C implementieren**, Test 5 grün.
- [ ] **Step 4: Teil D** (zwei Strings), betroffene Bestands-Tests (grep nach `exists as a file` in Tests) anpassen.
- [ ] **Step 5: Volle Suite grün** — `swift test`.
- [ ] **Step 6: Commit** — `feat: cancel the whole folder transfer from a tree conflict dialog` (Teil A+B), bzw. ein zweiter Commit `fix: honor an apply-to-all rule set while waiting at the conflict gate` für Teil C+D, falls getrennt committet wird (beide Formen ok, im Report nennen).

---

### Task 4: Edit-Integration-Fixes

**Files:**
- Modify: `Sources/macSCPCore/Presentation/EditSessionManager.swift` (neue statische Sweep-Funktion)
- Modify: `Sources/macSCPCore/Presentation/TransferQueueViewModel.swift` (`process`-Catch `connectionFailure` Zeilen 641–657; `message(for:)` Zeile 895 `public` machen)
- Modify: `Sources/MacSCPApp/MacSCPApp.swift` (Sweep-Aufruf im `init`)
- Modify: `Sources/MacSCPApp/ContentView.swift` (`openInEditor`-Catch Zeilen 767–771)
- Modify: `Sources/MacSCPApp/Resources/en.lproj/Localizable.strings` + `de.lproj` (ein neuer Key)
- Test: `Tests/macSCPCoreTests/EditSessionManagerTests.swift`, `Tests/macSCPCoreTests/TransferQueueViewModelTests.swift`

**Interfaces:**
- Consumes: `Job.bypassConflictCheck` (existiert; `true` NUR für Edit-Uploads — Resume-Retries nutzen `resume`, nicht dieses Flag), `CoreL10n.string("core.transfer.interrupted")` (Key existiert in beiden Core-Katalogen).
- Produces: `EditSessionManager.sweepOrphanedTempDirectories()` (`public static func`), `TransferQueueViewModel.message(for:)` wird `public static`.

**Teil A — Startup-Sweep:** In `EditSessionManager` (unter dem `init`):

```swift
    /// Removes the entire `macscp-edit` temp tree at app launch (M6a). Only
    /// `stopAll` cleans a session's subtree, so hard-killed app runs leave
    /// orphaned directories behind forever. At launch no edit can be active
    /// (single-instance app, sessions start later), so sweeping the whole
    /// tree is safe. Idempotent; a missing tree is a no-op.
    public static func sweepOrphanedTempDirectories() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macscp-edit", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
    }
```

In `MacSCPApp.init()` als erste Zeile: `EditSessionManager.sweepOrphanedTempDirectories()`.

Test (in `EditSessionManagerTests.swift`): Verzeichnis `macscp-edit/<uuid>/probe.txt` unter `FileManager.default.temporaryDirectory` anlegen, `sweepOrphanedTempDirectories()` aufrufen, `#expect` dass `macscp-edit` nicht mehr existiert; zweiter Aufruf wirft nicht (Idempotenz).

**Teil B — Resume-Ausschluss für Edit-Uploads:** Im `connectionFailure`-Catch von `process` den Zweig konditionieren — VOR dem bestehenden Code:

```swift
        } catch let error as RemoteFSError where error.isConnectionFailure {
            progressContinuation.finish()
            await consumer.value
            if job.bypassConflictCheck {
                // Editor write-back (M6a): NOT resumable — its temp source is
                // deleted by `stopAll` on disconnect, so a later resume would
                // visibly fail. Surface it as a plain failure instead; the
                // next editor save enqueues a fresh upload anyway.
                setStatus(jobID, .failed(CoreL10n.string("core.transfer.interrupted")))
                jobs[jobID] = nil
                runningTransferTasks[jobID] = nil
                resumeWaiter(jobID, with: .failure(error))
            } else {
                // Connection lost mid-transfer (M5d/T3): mark `.interrupted` …
                [bestehender Code der Zeilen 648–657 unverändert einrücken]
            }
        }
```

Test (in `TransferQueueViewModelTests.swift`): `editUploadConnectionFailureIsFailedNotInterrupted` — Edit-Upload via `enqueueEditUpload`, FS wirft `RemoteFSError.connectionFailed`; `#expect`: Status `.failed` (nicht `.interrupted`), `hasInterrupted == false`. Gegenprobe im selben Test: ein NORMALER Transfer mit demselben Fehler wird weiterhin `.interrupted`.

**Teil C — lokalisierter Edit-Fehlertext:** `TransferQueueViewModel.message(for:)` von `static func` zu `public static func` (Doku-Satz ergänzen: „Public: the App layer reuses this mapping for editor-open failures (M6a)."). In `ContentView.openInEditor` den Catch ersetzen:

```swift
            } catch is CancellationError {
                // Teardown cancelled the download (disconnect while opening) —
                // the session is going away; a stale banner on the NEXT
                // session would be misattributed. Show nothing.
            } catch {
                editErrorMessage = String(format: L10n.string(
                    "edit.openFailed", "Could not open file for editing: %@"),
                    TransferQueueViewModel.message(for: error))
            }
```

Hinweis: `enqueueAndWait` wirft `CancellationError` auch für Skip/Cancel-Konflikte — Edit-Downloads laufen aber über `beginEditing` ohne Konflikt-Prompt (Temp-Ziel), der einzige `CancellationError`-Pfad ist der Teardown. Kein neuer Katalog-Key nötig, wenn der Cancel-Fall stumm bleibt — der zunächst angedachte `edit.cancelled`-Key ENTFÄLLT damit (YAGNI); die Strings-Dateien bleiben unangetastet, sofern kein neuer Text gebraucht wird.

Test: Mapper selbst ist durch Bestands-Tests von `message(for:)` gedeckt (falls keiner existiert: einen Lookup-Test ergänzen, der für `RemoteFSError.notFound(path:)` den Katalogtext via `CoreL10n.string` vergleicht — locale-fest, gleiches Muster wie bestehende L10n-Tests).

- [ ] **Step 1: Tests (Sweep, Resume-Ausschluss, ggf. Mapper) rot.**
- [ ] **Step 2: Teile A–C implementieren.**
- [ ] **Step 3: Volle Suite grün** — `swift test`.
- [ ] **Step 4: Commit** — `fix: edit-upload interruptions, orphaned temp dirs, localized edit errors`.

---

### Task 5: Formular, Session, a11y, Hygiene (App + Core)

**Files:**
- Modify: `Sources/macSCPCore/Presentation/ConnectionViewModel.swift` (`endEditing` Zeilen 200–212)
- Modify: `Sources/macSCPCore/Sessions/SessionStore.swift` (`load()` Zeilen 41–44)
- Modify: `Sources/MacSCPApp/ContentView.swift` (`onNew:` Zeile 200, neue Methode neben `disconnectToForm`)
- Modify: `Sources/MacSCPApp/ConnectionFormView.swift` (FormRow, L10n-Bindung, errorHighlight-Kommentar)
- Modify: `Sources/MacSCPApp/PolishedButtonStyle.swift` (Fokus-Ring)
- Modify: `Sources/MacSCPApp/DesignTokens.swift` (paper löschen, Kommentare)
- Test: `Tests/macSCPCoreTests/ConnectionViewModelTests.swift` (endEditing-Konsolidierung), Bestand für SessionStore

**Interfaces:**
- Consumes: T4 abgeschlossen (gleiche Dateien App-seitig).
- Produces: keine neuen öffentlichen Namen; `ConnectionViewModel.endEditing()` ruft intern `exitEditMode()`.

**Teil A — endEditing/exitEditMode-Konsolidierung** (`ConnectionViewModel`):

```swift
    /// Leaves edit mode and resets the form to the same blank state
    /// `teardownSession` leaves it in for a new connection. Built on
    /// `exitEditMode()` (mode + group reset) plus the full field reset —
    /// the two used to duplicate the mode handling (M6a).
    public func endEditing() {
        exitEditMode()
        host = ""
        port = "22"
        username = ""
        password = ""
        authChoice = .password
        keyPath = ""
        shouldSaveSession = false
        saveName = ""
        state = .idle
    }
```

(`selectedGroupID = nil` steckt jetzt in `exitEditMode()` — die explizite Zeile entfällt.) Test: `endEditingResetsEverything` — Form via `beginEditing` füllen, `endEditing()`, `#expect` alle Felder blank, `mode == .new`, `selectedGroupID == nil`.

**Teil B — „Neue Verbindung" leert die Felder** (`ContentView`): Zeile 200 `onNew: { disconnectToForm() }` wird `onNew: { newConnection() }`; neue Methode direkt über `disconnectToForm`:

```swift
    /// Sidebar "New connection": tear down any current session AND blank the
    /// form (M6a) — without this, host/username/name from a previous edit or
    /// connection stay prefilled. The toolbar "Disconnect" deliberately keeps
    /// the fields (reconnect convenience) — only this path blanks them.
    private func newConnection() {
        guard !isReconnecting else { return }
        isReconnecting = true // synchronous — prevents double teardown
        Task {
            defer { isReconnecting = false }
            await teardownSession()
            connectionViewModel.endEditing()
        }
    }
```

**Teil C — SessionStore-Lesbarkeit** (Zeilen 41–44 ersetzen):

```swift
        // Defensive: a groupID whose group no longer exists behaves like nil.
        let knownIDs = Set(file.groups.map(\.id))
        for index in file.sessions.indices {
            guard let groupID = file.sessions[index].groupID,
                  !knownIDs.contains(groupID) else { continue }
            file.sessions[index].groupID = nil
        }
```

(Verhalten identisch — bestehende `SessionStoreTests` bleiben unverändert grün und BEWEISEN das.)

**Teil D — FormRow a11y + Dimmen** (`ConnectionFormView`, Zeilen 275–288 ersetzen):

```swift
/// Mockup form row (M5k): fixed 110pt right-aligned label column in
/// inkSecondary, 10pt gap to the field. The visible label lives here;
/// the wrapped controls keep their own label parameters for accessibility —
/// which is why the visible label is hidden from VoiceOver (M6a): without
/// that, every row is announced twice. The label also dims with the row's
/// enabled state, matching the system Form behavior the grid replaced.
private struct FormRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(DesignTokens.inkSecondary)
                .opacity(isEnabled ? 1 : 0.5)
                .frame(width: 110, alignment: .trailing)
                .accessibilityHidden(true)
            content
        }
    }
}
```

**Teil E — L10n-Bindung** (`ConnectionFormView.formContent`): Für die acht Doppelaufrufe (Host, Port, Username, Authentication, Password, Key path, Passphrase, Session name) je ein `let` im ViewBuilder-Body VOR der betreffenden Zeile, z. B.:

```swift
            let hostLabel = L10n.string("connection.field.host", "Host")
            // …
                FormRow(label: hostLabel) {
                    TextField(
                        hostLabel, text: $viewModel.host,
                        prompt: Text(L10n.string("connection.field.host.placeholder", "server.example.com"))
                    )
                }
```

Gleiches Muster für alle acht; Keys und Default-Strings UNVERÄNDERT übernehmen (nur die Duplikation binden). Der Group-Picker (nur ein Aufruf) bleibt wie er ist.

**Teil F — errorHighlight-Kommentar** (Zeilen 291–293 ersetzen):

```swift
    /// Red outline for the form row whose validation failed. The stroke
    /// wraps label AND field, sitting 10pt horizontally / 5pt vertically
    /// outside the row's bounds so the content keeps breathing room.
```

**Teil G — Fokus-Ring** (`PolishedButtonStyle`): `makeBody` delegiert an eine private View, damit `@Environment` nutzbar ist:

```swift
struct PolishedButtonStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        PolishedButtonBody(prominent: prominent, configuration: configuration)
    }
}

/// Split out so the style can read environment values (M6a focus ring).
private struct PolishedButtonBody: View {
    let prominent: Bool
    let configuration: ButtonStyle.Configuration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .font(.system(size: 12.5, weight: prominent ? .semibold : .regular))
            .padding(.vertical, 5)
            .padding(.horizontal, 14)
            .foregroundStyle(prominent ? Color.white : DesignTokens.inkSecondary)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(prominent ? DesignTokens.remoteBlue : DesignTokens.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(DesignTokens.hairline, lineWidth: prominent ? 0 : 1)
            )
            // Full Keyboard Access: custom button styles suppress the system
            // focus ring, so draw one — 2pt remote blue, slightly outset so
            // it never collides with the secondary variant's hairline (M6a).
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(DesignTokens.remoteBlue, lineWidth: isFocused ? 2 : 0)
                    .padding(-3)
            )
            .opacity(configuration.isPressed ? 0.85 : (isEnabled ? 1 : 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 7))
    }
}
```

Die `extension ButtonStyle where Self == PolishedButtonStyle` bleibt unverändert. VERIFIKATIONS-PFLICHT (im Report): `@Environment(\.isFocused)` muss im Button-Label-Kontext tatsächlich feuern — falls es beim T6-Smoke nicht sichtbar wird, ist der dokumentierte Fallback, den Ring über `.focusable(interactions: .activate)` + `@FocusState` am Button-Callsite zu lösen; NICHT stillschweigend weglassen.

**Teil H — paper-Token löschen + Kommentare** (`DesignTokens.swift`): Die Zeilen 67–71 werden zu:

```swift
    // Surface hierarchy (mockup: card content surface on the window ground).
    // `paper` (the mockup's page ground) had no consumer after the polish
    // rounds and was dropped (M6a, YAGNI).
    static let card = Color(nsColor: dynamicNS(light: 0xFFFFFF, dark: 0x14212E))
```

Und die stale Zeilen 56–57 („staged for the sidebar polish round") werden zu:

```swift
    /// SwiftUI wrappers alongside the NS variants — the file table consumes
    /// the NS colors directly, SwiftUI views the wrappers.
```

- [ ] **Step 1: `endEditingResetsEverything` rot** (Assertion auf `selectedGroupID == nil` nach `beginEditing` mit Gruppe schlägt fehl, solange die alte Doppel-Implementierung… — falls der Test sofort grün ist: er pinnt das Verhalten, im Report als Charakterisierungs-Test ausweisen; Refactoring danach beweist Verhaltenserhalt).
- [ ] **Step 2: Teile A–H implementieren.**
- [ ] **Step 3: Volle Suite grün** — `swift test`; `swift build` warnungsfrei bzgl. der geänderten Dateien.
- [ ] **Step 4: Commit** — `fix: form a11y, blank new-connection form, focus ring, code hygiene`.

---

### Task 6: Abschluss-Verifikation (Koordinator, kein Subagent)

- [ ] Docker-Rig starten (`docker compose -f docker/test-server/compose.yml start` — NUR aus dem Haupt-Checkout), dann `MACSCP_ITEST=1 MACSCP_KEYCHAIN=1 swift test` ⇒ komplett grün.
- [ ] Visueller Smoke (App-Wrapper neu bauen): (1) Drossel global — Limit 300 KB/s, ZWEI parallele Downloads: Summe der Raten ≈ 300 (nicht 600); (2) Ordner-Konflikt → „Abbrechen" stoppt die ganze Gruppe, Einzeldatei-Cancel nur das Item; (3) „Neue Verbindung" nach Edit-Modus: Formular leer; (4) Tab auf die Formular-Buttons (Full Keyboard Access an): blauer Fokus-Ring sichtbar — sonst Fallback aus T5/Teil G nachziehen; (5) VoiceOver-Stichprobe: Formularzeile wird EINMAL genannt; (6) Disabled-Dimmen der Labels während Connect (10.255.255.1-Trick); (7) Edit-Roundtrip kurz (Doppelklick → TextEdit → Save → Upload) als Regressionsprobe.
- [ ] Plan-Checkboxen abhaken, Ledger-Einträge, Opus-Whole-Branch-Final-Review (Base = Commit vor T1), Fixes, Push, `gh run watch`, Rig `stop`, Memory-Update.
