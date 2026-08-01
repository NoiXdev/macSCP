# M16 — Cross-Backend Transfer S3↔SSH Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** S3↔SSH-Transfers gated verifizieren und Cross-Backend-Transfers in der UI sichtbar machen (Ziel/Backend-Kennzeichnung + passive Resume-Warnung), ohne die Transfer-Engine anzufassen.

**Architecture:** Die Transfer-Engine ist bereits backend-agnostisch (verifiziert) — M16 fügt nur (1) einen gated S3↔SSH-Integrationstest, (2) additive Anzeige-Metadaten am Queue-`Item`, (3+4) UI hinzu. Die Metadaten leben **allein auf dem `Item`** (einmal bei Erstellung gesetzt, nie rekonstruiert); der `Job` bleibt unangetastet, weil nur er bei Interrupt/Retry neu gebaut wird und keine Anzeige-Daten braucht.

**Tech Stack:** Swift (SwiftPM, `.swiftLanguageMode(.v5)`), Swift Testing, SwiftUI+AppKit, macOS 15+, MinIO+sshd-Docker-Rig für gated Tests.

## Global Constraints

- Swift `.swiftLanguageMode(.v5)`, minimum macOS 15; **keine neue externe Dependency**.
- Tests: Swift Testing, TDD rot→grün.
- **KEINE Änderung an Signer/Transport/`TransferEngine`-Kopierlogik** — nur additive Metadaten + View.
- **Kein `if kind == .s3` in der Kopierlogik**; die Backend-Kennung im `Item` ist reine Anzeige.
- Resume-Guard (M13) bleibt unangetastet — der gated Test verifiziert ihn nur über die Backend-Grenze.
- Additive `Item`-Felder an **jeder** `Item`-Konstruktionsstelle explizit gesetzt (keine Struct-Defaults → der Compiler erzwingt Vollständigkeit).
- Secret ausschließlich im Keychain; nie in JSON/Logs/URLs.
- gated Tests `MACSCP_ITEST=1` (+ `MACSCP_KEYCHAIN=1`), **immer aus dem Haupt-Checkout, nie aus einem Worktree**; Rig `docker compose -f docker/test-server/compose.yml up -d` (sshd:2222, minio:19000/19001).
- Code/Kommentare/Tests **Englisch**; UI-Strings EN/DE/FR/PL mit **typografischen Anführungszeichen** in nicht-englischen Werten, FR/PL KI-generiert.
- Conventional Commits (CI-Gate); Footer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

## File Structure

- `Sources/macSCPCore/Presentation/TransferQueueViewModel.swift` — **modify**: `CrossBackendTarget`-Typ, `Item` um zwei Felder, `enqueue`/`enqueueTree`/`expandTree`/`addTerminalItem` um einen `crossBackendTarget`-Parameter, drei `Item(...)`-Konstruktionsstellen.
- `Tests/macSCPCoreTests/TransferQueueViewModelTests.swift` (oder die bestehende Queue-Test-Datei) — **modify**: Unit-Tests für die Metadaten.
- `Tests/macSCPCoreTests/CrossBackendTransferIntegrationTests.swift` — **create**: gated S3↔SSH-Test.
- `Sources/MacSCPApp/ContentView.swift` — **modify**: `CrossSessionTarget` um `kind`, `crossSessionTargets(for:)`, `transferToSession`, Submenü-Rendering.
- `Sources/MacSCPApp/TransferQueueBar.swift` — **modify**: `row(_:)` um Backend-Badge + Resume-⚠.
- `Sources/MacSCPApp/Resources/{en,de,fr,pl}.lproj/Localizable.strings` — **modify**: neue Strings.

---

## Task 1: Core — `CrossBackendTarget` + `Item`-Anzeige-Metadaten

**Files:**
- Modify: `Sources/macSCPCore/Presentation/TransferQueueViewModel.swift`
- Test: `Tests/macSCPCoreTests/TransferQueueViewModelTests.swift`

**Interfaces:**
- Consumes: `ConnectionKind` (`.ssh`/`.s3`), `any RemoteFileSystem` (`.supportsAppendResume: Bool`), bestehende `enqueue`/`enqueueTree`/`expandTree`/`addTerminalItem`.
- Produces:
  - `public struct CrossBackendTarget: Equatable, Sendable { public var name: String; public var kind: ConnectionKind; public init(name: String, kind: ConnectionKind) }`
  - `Item.destinationSupportsResume: Bool` (kein Struct-Default) + `Item.crossBackendTarget: CrossBackendTarget?` (kein Struct-Default)
  - `enqueue`/`enqueueTree` neuer Parameter `crossBackendTarget: CrossBackendTarget? = nil` (nach `crossRemote`)

**Wichtig (Architektur):** Der `Item` wird an genau drei Stellen konstruiert — `enqueue` (~425), `enqueueEditUpload` (~452), `addTerminalItem` (~1129) — und danach nie rekonstruiert (nur `setStatus` mutiert ihn). Deshalb tragen **nur diese drei Stellen** die neuen Felder; der `Job` und die Interrupt-/Retry-Pfade (~581, ~915) bleiben unverändert. `destinationSupportsResume` wird aus dem an der jeweiligen Stelle vorhandenen `destination` gelesen; wo kein `destination` existiert (`addTerminalItem` — Skip/Fehler-Items, die nie übertragen), ist es `true`.

- [ ] **Step 1: Failing-Test schreiben**

In `Tests/macSCPCoreTests/TransferQueueViewModelTests.swift` (die bestehende Queue-Test-Datei; falls anders benannt, die Datei mit `TransferQueueViewModel`-Tests nehmen) einen neuen Test-Block ans Ende der Suite einfügen. Nutze den in dieser Datei bereits vorhandenen FS-Fake (z. B. `RecordingFS`/`FakeFS` mit überschreibbarem `supportsAppendResume`) — den exakten Namen aus der Datei übernehmen; hier `StubFS` als Platzhalter, beim Schreiben durch den realen Fake ersetzen:

```swift
    // MARK: - Cross-backend display metadata (M16)

    @Test func enqueueToS3TargetMarksNoResumeAndCarriesTarget() async {
        let vm = TransferQueueViewModel(/* … gleiche Init wie die übrigen Tests dieser Datei … */)
        let source = StubFS(supportsAppendResume: true)
        let s3Dest = StubFS(supportsAppendResume: false)
        _ = vm.enqueue(
            fileName: "a.bin", direction: .upload,
            source: source, sourcePath: "/a.bin",
            destination: s3Dest, destinationDirectory: "/",
            onCompleted: nil, destinationTabID: UUID(), crossRemote: true,
            crossBackendTarget: CrossBackendTarget(name: "prod-bucket", kind: .s3))
        let item = vm.items.last!
        #expect(item.destinationSupportsResume == false)
        #expect(item.crossBackendTarget == CrossBackendTarget(name: "prod-bucket", kind: .s3))
    }

    @Test func enqueueToSSHTargetAllowsResume() async {
        let vm = TransferQueueViewModel(/* … */)
        let sshDest = StubFS(supportsAppendResume: true)
        _ = vm.enqueue(
            fileName: "b.bin", direction: .upload,
            source: StubFS(supportsAppendResume: true), sourcePath: "/b.bin",
            destination: sshDest, destinationDirectory: "/",
            onCompleted: nil, destinationTabID: UUID(), crossRemote: true,
            crossBackendTarget: CrossBackendTarget(name: "web", kind: .ssh))
        let item = vm.items.last!
        #expect(item.destinationSupportsResume == true)
        #expect(item.crossBackendTarget?.kind == .ssh)
    }

    @Test func sameSessionUploadToS3HasNoTargetButNoResume() async {
        let vm = TransferQueueViewModel(/* … */)
        _ = vm.enqueue(
            fileName: "c.bin", direction: .upload,
            source: StubFS(supportsAppendResume: true), sourcePath: "/c.bin",
            destination: StubFS(supportsAppendResume: false), destinationDirectory: "/",
            onCompleted: nil)
        let item = vm.items.last!
        #expect(item.destinationSupportsResume == false)
        #expect(item.crossBackendTarget == nil)
    }
```

Falls der Datei-Fake kein `init(supportsAppendResume:)` hat: gib ihm ein solches (überschreibbares) Property nach dem Muster, das die M13-Resume-Tests dieser Datei bereits verwenden (dort wird `supportsAppendResume` schon variiert) — nichts erfinden, das vorhandene Muster übernehmen.

- [ ] **Step 2: Test rot**

Run: `swift test --filter TransferQueueViewModelTests`
Expected: FAIL — „cannot find 'CrossBackendTarget'" bzw. „extra argument 'crossBackendTarget'".

- [ ] **Step 3: `CrossBackendTarget` + `Item`-Felder**

In `TransferQueueViewModel.swift`: den Typ auf Datei-Ebene (oder direkt vor der Klasse) einfügen:

```swift
/// A cross-backend transfer's destination label (M16): the target session's
/// display name and protocol kind. Set only for cross-session transfers so
/// the transfer row can show where a file is going and with which backend.
public struct CrossBackendTarget: Equatable, Sendable {
    public var name: String
    public var kind: ConnectionKind
    public init(name: String, kind: ConnectionKind) {
        self.name = name
        self.kind = kind
    }
}
```

Im `Item`-Struct (nach `destinationDirectory`) zwei Felder OHNE Default hinzufügen:

```swift
        /// Whether the destination backend supports append-based resume (M16).
        /// Read from `destination.supportsAppendResume` at enqueue; `false`
        /// for an S3 destination. Drives the passive resume warning in the
        /// transfer row. `true` for terminal skip/error items (no transfer).
        public let destinationSupportsResume: Bool
        /// Cross-backend destination label (M16): the target session's name +
        /// kind, `nil` for same-session transfers. The queue holds only the
        /// opaque `destinationTabID`, so the App supplies this at enqueue.
        public let crossBackendTarget: CrossBackendTarget?
```

- [ ] **Step 4: Parameter durchreichen + drei `Item(...)`-Stellen setzen**

(a) `enqueue` (~411): Parameter `crossBackendTarget: CrossBackendTarget? = nil` nach `crossRemote` ergänzen; die `Item(...)`-Konstruktion (~425) um:

```swift
        items.append(Item(
            id: id, fileName: fileName, direction: direction, status: .queued,
            destinationTabID: destinationTabID, isEditUpload: false,
            destinationDirectory: destinationDirectory,
            destinationSupportsResume: destination.supportsAppendResume,
            crossBackendTarget: crossBackendTarget))
```

(b) `enqueueEditUpload` (~440): die `Item(...)`-Konstruktion (~452) um:

```swift
        items.append(Item(
            id: id, fileName: fileName, direction: .upload, status: .queued,
            destinationTabID: nil, isEditUpload: true,
            destinationDirectory: remoteDirectory,
            destinationSupportsResume: destination.supportsAppendResume,
            crossBackendTarget: nil))
```

(c) `addTerminalItem` (~1123): Signatur um `crossBackendTarget: CrossBackendTarget? = nil` ergänzen; die `Item(...)`-Konstruktion (~1129) um:

```swift
        items.append(Item(
            id: id, fileName: name, direction: direction, status: .queued,
            destinationTabID: destinationTabID, isEditUpload: false,
            destinationDirectory: destinationDirectory,
            destinationSupportsResume: true,
            crossBackendTarget: crossBackendTarget))
```

(d) `enqueueTree` (~525): Parameter `crossBackendTarget: CrossBackendTarget? = nil` ergänzen und an `expandTree` weiterreichen.

(e) `expandTree` (~1044): Parameter `crossBackendTarget: CrossBackendTarget? = nil` ergänzen; im `.file`-Zweig an `enqueue(...)` durchreichen (`crossBackendTarget: crossBackendTarget`); im rekursiven `.directory`-Zweig an `expandTree(...)` durchreichen; in den drei `addTerminalItem(...)`-Aufrufen (Dir-Create-Fehler, List-Fehler, Symlink-Skip) `crossBackendTarget: crossBackendTarget` mitgeben.

- [ ] **Step 5: Test grün**

Run: `swift test --filter TransferQueueViewModelTests`
Expected: PASS — die drei neuen Tests grün, alle bestehenden Queue-Tests weiter grün.

- [ ] **Step 6: Retry-Persistenz-Guard (Test)**

Ergänze einen Test, der beweist, dass ein Item seine Metadaten über einen Interrupt→Retry-Zyklus behält (weil der Item NICHT rekonstruiert wird). Falls die Datei bereits einen Interrupt/Retry-Test-Helfer hat, dessen Muster nutzen; minimal:

```swift
    @Test func interruptedItemKeepsCrossBackendMetadata() async {
        let vm = TransferQueueViewModel(/* … */)
        _ = vm.enqueue(
            fileName: "d.bin", direction: .upload,
            source: StubFS(supportsAppendResume: true), sourcePath: "/d.bin",
            destination: StubFS(supportsAppendResume: false), destinationDirectory: "/",
            onCompleted: nil, destinationTabID: UUID(), crossRemote: true,
            crossBackendTarget: CrossBackendTarget(name: "prod-bucket", kind: .s3))
        let id = vm.items.last!.id
        vm.setStatusForTesting(id, .interrupted)   // <- realen Test-Hook/Weg dieser Datei nutzen
        let item = vm.items.first { $0.id == id }!
        #expect(item.crossBackendTarget?.kind == .s3)
        #expect(item.destinationSupportsResume == false)
    }
```

Gibt es keinen Test-Hook, um `.interrupted` zu setzen, entfalle dieser Test — die Persistenz ist strukturell garantiert (Item wird nie neu gebaut); dann in der Commit-Message vermerken, dass die Persistenz strukturell (nicht per Test) gesichert ist. **Keinen** privaten Zugriff erfinden.

Run: `swift test --filter TransferQueueViewModelTests`
Expected: PASS (oder Test weggelassen wie beschrieben).

- [ ] **Step 7: Volle Core-Suite + 0 Warnungen**

Run: `swift build && swift test`
Expected: Build 0 Warnungen; alle Tests grün.

- [ ] **Step 8: Commit**

```bash
git add Sources/macSCPCore/Presentation/TransferQueueViewModel.swift Tests/macSCPCoreTests/TransferQueueViewModelTests.swift
git commit -m "feat: carry cross-backend display metadata on transfer items

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 2: Gated S3↔SSH-Integrationstest

**Files:**
- Create: `Tests/macSCPCoreTests/CrossBackendTransferIntegrationTests.swift`

**Interfaces:**
- Consumes: `TransferEngine.copyFile(...)` (Signatur aus `Sources/macSCPCore/RemoteFS/TransferEngine.swift:93` lesen), `S3FileSystem.connect(config)` + `S3ConnectionConfig` (aus `S3FileSystemIntegrationTests.swift` das `connect()`-Muster), `CitadelFileSystem`-Connect Port 2222 (aus `CitadelFileSystemIntegrationTests.swift`, `remoteToRemoteStreamCopiesByteIdentical` ~1195 als Vorlage), `readStream`/`write`/`createDirectory`/`list` des `RemoteFileSystem`-Protokolls.
- Produces: nur Tests.

**Verifizierte Rig-Werte:** S3 — accessKeyID `"macscp"`, secret `"macscpsecretkey"`, region `"us-east-1"`, endpoint `"http://127.0.0.1:19000"`, bucket `"macscp-seed"`, usePathStyle `true`. SSH — Host `127.0.0.1`, Port `2222`, user `testuser`, pass `testpass`. Suite-Gate `.enabled(if: ProcessInfo.processInfo.environment["MACSCP_ITEST"] == "1")`.

- [ ] **Step 1: Test-Datei-Gerüst**

`Tests/macSCPCoreTests/CrossBackendTransferIntegrationTests.swift` anlegen. Kopf + Connect-Helfer aus den zwei bestehenden Integrationstest-Dateien übernehmen (verbatim die Init-/Connect-Signaturen dort — `S3FileSystem.connect(config)` positional, `S3ConnectionConfig(...)` wie in `S3FileSystemIntegrationTests.connect()`, Citadel-Connect wie in `CitadelFileSystemIntegrationTests`). `TransferEngine`-Instanziierung + `copyFile`-Aufruf exakt so bauen, wie `remoteToRemoteStreamCopiesByteIdentical` es tut (dortiges Muster für Engine-Setup, Fortschritts-Closure, resume-Flag).

```swift
import Foundation
import Testing
@testable import macSCPCore

/// Cross-backend transfers between MinIO (S3) and the SSH rig (SFTP), M16.
/// Runs only with MACSCP_ITEST=1 and the Docker rig up
/// (`docker compose -f docker/test-server/compose.yml up -d`).
@Suite(
    "Cross-backend S3↔SSH transfer",
    .enabled(if: ProcessInfo.processInfo.environment["MACSCP_ITEST"] == "1"),
    .serialized
)
struct CrossBackendTransferIntegrationTests {
    // connectS3() / connectSSH() Helfer hier — 1:1 aus den beiden bestehenden
    // Integrationstest-Dateien übernehmen (Werte oben).
}
```

- [ ] **Step 2: SSH→S3 byte-identisch**

Test: eine Datei mit bekanntem Zufallsinhalt auf dem sshd anlegen (via `sshFS.write`), dann `TransferEngine.copyFile(source: sshFS, sourcePath: …, destination: s3FS, destinationPath: …)` (Signatur aus TransferEngine.swift:93), dann das S3-Objekt via `s3FS.readStream(...)` komplett lesen und `#expect(readBack == original)`. Zieldatei/-key nach dem Test aufräumen (best effort, wie die anderen Integrationstests).

- [ ] **Step 3: S3→SSH byte-identisch**

Test: ein Objekt in MinIO anlegen (`s3FS.write`), `copyFile(source: s3FS, destination: sshFS)`, dann via `sshFS.readStream` zurücklesen und `#expect` byte-identisch.

- [ ] **Step 4: Ordner-Baum cross-backend (eine Richtung)**

Test (SSH→S3 oder S3→SSH): ein Verzeichnis mit einer Datei und einem Unterordner-mit-Datei auf der Quelle anlegen; den Baum kopieren (über den Engine-/Queue-Baumweg oder rekursiv per `list`+`createDirectory`+`copyFile`, so wie ein Tree-Transfer es tut) und prüfen, dass auf der Zielseite beide Dateien in der richtigen Ordnerstruktur ankommen. Bei S3-Ziel: `createDirectory` legt den 0-Byte-Marker an; bei S3-Quelle: `list` liefert den Unterordner als `.directory` (CommonPrefix). `#expect` auf die gelisteten Zieleinträge.

- [ ] **Step 5: Resume-Guard über die Grenze**

Test: einen SSH→S3-`copyFile` mit `resume: true` starten (die `copyFile`-Signatur trägt ein resume/offset-Argument — aus TransferEngine.swift:93 ff. lesen); verifizieren, dass die Übertragung erfolgreich byte-identisch durchläuft (S3 kann kein Append; der M13-Guard erzwingt `.overwrite`). Der Nachweis ist ein erfolgreicher, vollständiger Transfer trotz `resume: true` — kein 416/kein Korruptions-Byte-Mismatch. (Direkter Zugriff auf den internen write-mode ist nicht nötig/verfügbar; das byte-identische Ergebnis IST der Guard-Beweis.)

- [ ] **Step 6: Rig hoch + gated Lauf**

Run:
```bash
docker compose -f docker/test-server/compose.yml up -d
MACSCP_ITEST=1 MACSCP_KEYCHAIN=1 swift test --filter CrossBackendTransferIntegrationTests
```
Expected: alle vier/fünf Tests laufen (nicht geskippt) und sind grün. Ein 403/Byte-Mismatch deutet auf ein echtes Signatur-/Pfad-Problem (dann in M16 fixen — wie der M13-Trailing-Slash-Fund).

- [ ] **Step 7: Commit**

```bash
git add Tests/macSCPCoreTests/CrossBackendTransferIntegrationTests.swift
git commit -m "test: verify cross-backend S3 and SSH transfers against the rig

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 3: App — Transfer-Zeile mit Ziel/Backend-Badge + Resume-⚠

**Files:**
- Modify: `Sources/MacSCPApp/ContentView.swift` (`CrossSessionTarget` ~vor 2579, `crossSessionTargets(for:)` ~2579, `transferToSession` ~2596)
- Modify: `Sources/MacSCPApp/TransferQueueBar.swift` (`row(_:)` 66–122)
- Modify: `Sources/MacSCPApp/Resources/{en,de,fr,pl}.lproj/Localizable.strings`

**Interfaces:**
- Consumes (aus Task 1): `Item.destinationSupportsResume: Bool`, `Item.crossBackendTarget: CrossBackendTarget?`, `CrossBackendTarget.name`/`.kind`, `enqueue`/`enqueueTree` mit `crossBackendTarget:`-Parameter.
- Consumes: `other.connectionViewModel.kind` (Backend-`kind` einer Ziel-Session, wie in ContentView.swift:1059 verwendet), `other.displayTitle`, `session.remote.currentPath`.
- Produces: `CrossSessionTarget.kind: ConnectionKind`.

Reine SwiftUI/App-Verkabelung — build-verifiziert.

- [ ] **Step 1: `CrossSessionTarget` um `kind` + `crossSessionTargets` ableiten**

`CrossSessionTarget` (die `struct`, direkt vor `crossSessionTargets(for:)`) um `let kind: ConnectionKind` erweitern. In `crossSessionTargets(for:)` (~2582) den Konstruktor um `kind: other.connectionViewModel.kind` ergänzen:

```swift
            return CrossSessionTarget(
                id: other.id, title: other.displayTitle,
                remotePath: session.remote.currentPath,
                kind: other.connectionViewModel.kind)
```

- [ ] **Step 2: `transferToSession` gibt `crossBackendTarget` mit**

In `transferToSession` (~2596) an **allen vier** enqueue/enqueueTree-Aufrufen `crossBackendTarget: CrossBackendTarget(name: target.title, kind: target.kind)` ergänzen (die vier Aufrufe: local-dir → `enqueueTree`, local-file → `enqueue`, remote-dir → `enqueueTree` mit `crossRemote: true`, remote-file → `enqueue` mit `crossRemote: true`). Beispiel für den remote-file-Zweig:

```swift
                queue.enqueue(
                    fileName: item.name, direction: .upload,
                    source: session.remoteFS, sourcePath: item.path,
                    destination: targetSession.remoteFS,
                    destinationDirectory: target.remotePath,
                    onCompleted: { [weak remote = targetSession.remote] in await remote?.refresh() },
                    destinationTabID: target.id, crossRemote: true,
                    crossBackendTarget: CrossBackendTarget(name: target.title, kind: target.kind))
```

- [ ] **Step 3: Transfer-Zeile — Badge + ⚠**

In `TransferQueueBar.row(_:)` (66–122) direkt nach dem `Text(item.fileName)`-Block (und vor `Spacer(minLength: 8)`) zwei bedingte Elemente einfügen:

```swift
            if let target = item.crossBackendTarget {
                Text(backendBadgeLabel(target.kind))
                    .font(.system(size: 9.5, weight: .semibold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(DesignTokens.remoteSoft, in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(DesignTokens.inkSecondary)
                Text("→ \(target.name)")
                    .font(.caption)
                    .foregroundStyle(DesignTokens.inkSecondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            if !item.destinationSupportsResume, item.status == .queued || item.status.isRunning {
                Image(systemName: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help(L10n.string(
                        "transfers.noResume.hint",
                        "If interrupted, this upload restarts from the beginning."))
            }
```

Und einen kleinen Helfer in derselben View ergänzen (Backend-Badge-Label; die Kürzel „SSH"/„S3" stammen aus M12 — dieselbe Quelle wie Sidebar/Tab, hier direkt gemappt):

```swift
    private func backendBadgeLabel(_ kind: ConnectionKind) -> String {
        switch kind {
        case .ssh: return L10n.string("backend.badge.ssh", "SSH")
        case .s3: return L10n.string("backend.badge.s3", "S3")
        }
    }
```

Prüfen: heißen die M12-Badge-L10n-Keys bereits `backend.badge.ssh`/`backend.badge.s3` (Sidebar/TabStrip)? Falls ja, **diese** wiederverwenden statt neue anzulegen; falls die vorhandenen Keys anders heißen, die vorhandenen nehmen. `item.status.isRunning` gegen den realen Accessor prüfen (in dieser Datei/Item verwendet, siehe `isActive`/`isRunning`).

- [ ] **Step 4: L10n (nur wirklich neue Keys)**

`transfers.noResume.hint` in alle vier Kataloge; die Backend-Badge-Keys nur, falls sie nicht schon existieren.

EN:
```
"transfers.noResume.hint" = "If interrupted, this upload restarts from the beginning.";
```
DE:
```
"transfers.noResume.hint" = "Bei Abbruch startet dieser Upload von vorn.";
```
FR:
```
"transfers.noResume.hint" = "En cas d’interruption, ce téléversement redémarre du début.";
```
PL:
```
"transfers.noResume.hint" = "W razie przerwania to wysyłanie zacznie się od nowa.";
```
(Typografische Apostrophe im FR-Wert; keine ASCII-Quotes.)

- [ ] **Step 5: Build + Behaviour-Check**

Run: `swift build`
Expected: 0 Warnungen. Verhalten per Codelesen: (1) Same-Session-Transfer unverändert (kein Badge); (2) Cross-Session zeigt Backend-Badge + `→ Ziel`; (3) jedes S3-Ziel (auch same-session lokal→S3) zeigt ⚠ solange aktiv, weg bei Abschluss.

- [ ] **Step 6: Commit**

```bash
git add Sources/MacSCPApp/ContentView.swift Sources/MacSCPApp/TransferQueueBar.swift Sources/MacSCPApp/Resources
git commit -m "feat: show target backend and resume warning in the transfer bar

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 4: App — Ziel-Session-Submenü mit Backend-Badge + Pfad

**Files:**
- Modify: `Sources/MacSCPApp/ContentView.swift` (das M8b-„An Session übertragen"-Submenü, das `crossSessionTargets(for:)` rendert)
- Modify: `Sources/MacSCPApp/Resources/{en,de,fr,pl}.lproj/Localizable.strings` (nur falls ein Format-String nötig)

**Interfaces:**
- Consumes (aus Task 3): `CrossSessionTarget.kind`, `CrossSessionTarget.title`, `CrossSessionTarget.remotePath`, `backendBadgeLabel(_:)`-Idee (im Menü ggf. eigener kleiner Helfer, da andere View).

Reine App-View — build-verifiziert.

- [ ] **Step 1: Submenü-Eintrag um Backend-Kürzel + Pfad**

Die Stelle finden, die die `crossSessionTargets(for:)`-Liste in Menüeinträge rendert (das „An Session übertragen"/„Transfer to session"-Submenü aus M8b; via `menuNeedsUpdate`/`NSMenuItem` oder SwiftUI-`Menu` — die reale Render-Stelle im Code lokalisieren). Den Eintragstitel von reinem `target.title` auf ein kompaktes `„<KIND> · <title> — <remotePath>"` umstellen, z. B.:

```swift
let kindLabel = target.kind == .s3
    ? L10n.string("backend.badge.s3", "S3")
    : L10n.string("backend.badge.ssh", "SSH")
let title = String(
    format: L10n.string("transfers.targetMenu.item %@ %@ %@", "%@ · %@ — %@"),
    kindLabel, target.title, target.remotePath)
```

Trägt das konkrete Menü-Widget einen zweizeiligen/attribuierten Eintrag sauber (z. B. `NSMenuItem.attributedTitle`), darf der Pfad stattdessen als kleinere zweite Zeile gesetzt werden — Entscheidung nach dem, was die reale Render-Stelle hergibt; sonst die kompakte einzeilige Form oben.

- [ ] **Step 2: L10n**

`transfers.targetMenu.item %@ %@ %@` (Format `"%@ · %@ — %@"`) in alle vier Kataloge, identischer Format-String (die Reihenfolge der Platzhalter ist sprachneutral). Falls die reale Render-Stelle die zweizeilige Variante nutzt, den passenden Key stattdessen.

EN/DE/FR/PL jeweils:
```
"transfers.targetMenu.item %@ %@ %@" = "%@ · %@ — %@";
```

- [ ] **Step 3: Build + Behaviour-Check**

Run: `swift build`
Expected: 0 Warnungen. Verhalten: das „An Session übertragen"-Submenü zeigt pro Ziel `S3 · prod-bucket — /uploads` bzw. `SSH · web — /var/www`.

- [ ] **Step 4: Commit**

```bash
git add Sources/MacSCPApp/ContentView.swift Sources/MacSCPApp/Resources
git commit -m "feat: label the transfer-target submenu with backend and path

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 5: Abschluss — gated Suite, Review, Push/Deploy

**Files:** keine (Verifikation + Milestone-Closeout).

- [ ] **Step 1: Rig hoch + volle gated Suite**

Run:
```bash
docker compose -f docker/test-server/compose.yml up -d
MACSCP_ITEST=1 MACSCP_KEYCHAIN=1 swift test
```
Expected: gesamte Suite grün, inkl. der neuen `CrossBackendTransferIntegrationTests` (nicht geskippt) und der neuen Queue-Unit-Tests; SSH/S3/Keychain-Suiten laufen mit.

- [ ] **Step 2: Ungated Suite + 0 Warnungen**

Run: `swift build && swift test`
Expected: Build 0 Warnungen; ungated Suite grün.

- [ ] **Step 3: Runtime-Idle-CPU-Smoke**

Dev-Build starten und Idle-CPU prüfen (Lektion M11n: neue GUI-Elemente vor Auslieferung per Idle-CPU-Rauchtest, da Reviews/CI die GUI nicht starten). Die neuen Elemente sind statische Labels/Badges — es darf keinen Layout-Sturm/Dauer-CPU geben.

- [ ] **Step 4: Whole-Milestone-Review**

Opus-Whole-Branch-Review über den gesamten M16-Diff (`git merge-base develop HEAD`..HEAD — Basis = M15-HEAD `9e6179f`), Fokus auf die Global Constraints (keine Engine-/Signer-Änderung, kein `if kind==.s3` in der Kopierlogik, Item-Metadaten korrekt an allen drei Stellen, Resume-Guard nur verifiziert).

- [ ] **Step 5: Push + CI + Dev-Build (auf Maintainer-Anordnung)**

Nach grünem Review — auf Maintainer-Anordnung: Push nach `develop`, `gh run watch`, Dev-Build v1.6.0-dev nach `~/Desktop/macSCP-dev.app`. Kein Release/Tag.

---

## Self-Review

**1. Spec coverage:**
- Spec §1 (gated S3↔SSH-Test + Härtung) → Task 2. ✅
- Spec §2 (Queue-Item-Metadaten `destinationSupportsResume` + `crossBackendTarget`, 4 Unit-Fälle inkl. Retry) → Task 1 (Steps 1–6). ✅ (Refinement: nur `Item`, kein `Job` — begründet, Retry-Persistenz strukturell/getestet.)
- Spec §3 (Transfer-Zeile Badge + passive ⚠) → Task 3. ✅
- Spec §4 (Ziel-Submenü Backend-Badge + Pfad) → Task 4. ✅
- Spec §Tests (Core-Unit + gated + Idle-CPU) → Task 1/2 + Task 5. ✅
- Spec §Sicherheit/Invarianten → Global Constraints + Task-5-Review. ✅

**2. Placeholder scan:** Bewusst offene Stellen: Fake-Name (`StubFS`) und `setStatusForTesting`-Hook in Task 1, Rig-Connect-Helfer/`copyFile`-Signatur in Task 2, reale Menü-Render-Stelle + M12-Badge-Key-Namen in Task 3/4 — alle mit klarer Anweisung, den realen Namen aus der genannten Quelldatei zu übernehmen, kein erfundener Wert. Kein „TBD/TODO".

**3. Type consistency:** `CrossBackendTarget(name:kind:)`, `Item.destinationSupportsResume`/`.crossBackendTarget`, `enqueue`/`enqueueTree`/`expandTree`/`addTerminalItem` `crossBackendTarget`-Parameter, `CrossSessionTarget.kind`, `backendBadgeLabel(_:)` — über alle Tasks konsistent. `ConnectionKind` (.ssh/.s3) einheitlich.
