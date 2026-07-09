# macSCP M2d — Drag & Drop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Dateien per Drag & Drop übertragen — Finder/lokales Pane → Remote-Pane (Upload) und Remote-Zeile → Finder (Download via File Promise).

**Architecture:** Das Remote-`BrowserPane` wird SwiftUI-`onDrop`-Ziel für `.fileURL` (mit Tint-Highlight); gedroppte Dateien laufen **sequenziell** durch das vorhandene `TransferViewModel` (Review-Warnung aus M2c: der `isRunning`-Guard verschluckt parallele Aufrufe — die Drop-Schleife awaited deshalb jeden Transfer). Die AppKit-Tabelle wird Drag-Quelle über einen pane-spezifischen `NSPasteboardWriting`-Provider: lokal liefert `NSURL` (Finder kopiert selbst; Drop aufs Remote-Pane nutzt denselben Upload-Pfad), remote liefert einen `NSFilePromiseProvider`, dessen Delegate die Datei bei Einlösung direkt über die `TransferEngine` an die vom Finder vorgegebene URL lädt.

**Abhängigkeiten:** Task 1 → Task 2 → Task 3 → Task 4 (alle enden in `ContentView` — KEINE Parallel-Phase in diesem Plan).

**Tech Stack:** wie M2c; zusätzlich UniformTypeIdentifiers (`UTType.fileURL`) und `NSFilePromiseProvider` (AppKit).

## Global Constraints

- swift-tools-version 6.0, Language Mode v5; macOS 14; UI-Texte Deutsch
- Conventional Commits, Footer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`; niemals pushen (macht der Koordinator)
- YAGNIs für M2d: KEINE Verzeichnis-Drops (Ordner werden still übersprungen), KEIN Fortschritt im Finder für Promises (NSProgress-Registrierung → M5), KEIN Drop aufs LOKALE Pane (Finder→lokal wäre lokales Kopieren — nicht unsere Aufgabe), KEINE Konfliktdialoge (Überschreiben, wie M2c)
- Drops laufen strikt sequenziell durch `TransferViewModel.run` (awaited-Schleife); Promise-Downloads laufen bewusst AN der TransferBar VORBEI direkt über die Engine (dokumentiert; Queue-Integration → M5)
- Nach jedem Task: `swift test` grün (ohne Docker)

## Datei-Landkarte (Delta M2d)

```
Sources/macSCPCore/Presentation/TransferViewModel.swift  (unverändert — Sequenz-Test neu in Tests)
Sources/MacSCPApp/
  BrowserPane.swift            (Task 1 — onDropURLs + Drop-Highlight; Task 2 — pasteboardWriter durchreichen)
  RemoteFileTableView.swift    (Task 2 — pasteboardWriterForRow)
  RemoteFilePromise.swift      (Task 3 — neu: Provider + Delegate)
  ContentView.swift            (Task 1 Drop-Handler; Task 2 lokaler Writer; Task 3 remote Writer)
Tests/macSCPCoreTests/
  TransferEngineTests.swift    (Task 1 — +1 Sequenz-Test)
```

---

### Task 1: Sequenzieller Drop-Upload aufs Remote-Pane

**Files:**
- Modify: `Sources/MacSCPApp/BrowserPane.swift`
- Modify: `Sources/MacSCPApp/ContentView.swift`
- Test: `Tests/macSCPCoreTests/TransferEngineTests.swift` (+1 Test)

**Interfaces:**
- Produces: `BrowserPane(title:tint:viewModel:onDropURLs:)` mit `onDropURLs: (([URL]) -> Void)? = nil` — nur das Remote-Pane bekommt einen Handler; Panes ohne Handler lehnen Drops ab.

- [ ] **Step 1: Fehlschlagender Test (Sequenz-Garantie im VM)** — in `TransferEngineTests` ergänzen:

```swift
    @Test func sequentialAwaitedRunsBothExecute() async {
        let content = Data("zwei".utf8)
        let source = MockRemoteFileSystem(
            tree: ["/": [
                RemoteFileItem(name: "eins.txt", path: "/eins.txt", kind: .file, size: 4),
                RemoteFileItem(name: "zwei.txt", path: "/zwei.txt", kind: .file, size: 4),
            ]],
            files: ["/eins.txt": content, "/zwei.txt": content]
        )
        let destination = MockRemoteFileSystem(tree: ["/ziel": []])
        let vm = await TransferViewModel()

        for name in ["eins.txt", "zwei.txt"] {
            await vm.run(
                fileName: name, direction: .upload,
                source: source, sourcePath: "/\(name)",
                destination: destination, destinationDirectory: "/ziel",
                onCompleted: {}
            )
        }
        #expect(await destination.writtenData(at: "/ziel/eins.txt") == content)
        #expect(await destination.writtenData(at: "/ziel/zwei.txt") == content)
        #expect(await vm.state == .finished(fileName: "zwei.txt", direction: .upload))
    }
```

Run: `swift test --filter TransferEngineTests` — der Test ist NEU und muss beim ersten Lauf GRÜN sein (er dokumentiert die Sequenz-Garantie, die der Drop-Handler nutzt; falls er ROT ist, liegt ein echter Bug im isRunning-Guard vor — dann STOPP und melden).

- [ ] **Step 2: BrowserPane um Drop-Ziel erweitern**

`Sources/MacSCPApp/BrowserPane.swift` — Datei komplett ersetzen:

```swift
import SwiftUI
import UniformTypeIdentifiers
import macSCPCore

/// Ein Datei-Pane (lokal oder remote): Kopfzeile mit Seiten-Badge in der
/// Markenfarbe, Pfad, Hoch/Aktualisieren — darunter die AppKit-Tabelle.
/// Mit onDropURLs wird das Pane Drop-Ziel für Datei-URLs (Tint-Highlight).
struct BrowserPane: View {
    let title: String
    let tint: Color
    let viewModel: RemoteBrowserViewModel
    var onDropURLs: (([URL]) -> Void)? = nil

    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(title.uppercased())
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 5))
                    .foregroundStyle(tint)

                Text(viewModel.currentPath)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    Task { await viewModel.goUp() }
                } label: {
                    Image(systemName: "arrow.up")
                }
                .disabled(!viewModel.canGoUp || viewModel.state == .loading)
                .help("Übergeordnetes Verzeichnis")

                Button {
                    Task { await viewModel.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(viewModel.state == .loading)
                .help("Aktualisieren")
            }
            .padding(8)

            Divider()

            ZStack {
                RemoteFileTableView(
                    items: viewModel.items,
                    selectedPath: viewModel.selectedItem?.path,
                    onOpen: { item in Task { await viewModel.open(item) } },
                    onSelect: { item in viewModel.selectedItem = item }
                )
                .allowsHitTesting(viewModel.state == .loaded)

                if viewModel.state == .loading {
                    ProgressView()
                }

                if case .failed(let message) = viewModel.state {
                    VStack(spacing: 8) {
                        Text(message)
                            .foregroundStyle(.red)
                        Button("Erneut versuchen") {
                            Task { await viewModel.refresh() }
                        }
                    }
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(tint, lineWidth: isDropTargeted ? 2.5 : 0)
                    .padding(2)
            )
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                guard let onDropURLs else { return false }
                Task {
                    var urls: [URL] = []
                    for provider in providers {
                        if let url = await provider.macscpFileURL() {
                            urls.append(url)
                        }
                    }
                    await MainActor.run { onDropURLs(urls) }
                }
                return true
            }
        }
        .task { await viewModel.load() }
    }
}

extension NSItemProvider {
    /// Extrahiert eine Datei-URL aus dem Provider (Drop-Payload).
    func macscpFileURL() async -> URL? {
        await withCheckedContinuation { continuation in
            _ = loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    continuation.resume(returning: url)
                } else if let url = item as? URL {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
```

- [ ] **Step 3: Drop-Handler in ContentView**

In `Sources/MacSCPApp/ContentView.swift`: das Remote-`BrowserPane` im `HSplitView` erweitern (das lokale Pane bleibt OHNE `onDropURLs`):

```swift
                    BrowserPane(
                        title: "Remote",
                        tint: DesignTokens.remoteBlue,
                        viewModel: session.remote,
                        onDropURLs: { urls in
                            uploadDropped(urls, session: session)
                        }
                    )
                    .frame(minWidth: 280)
```

und als private Methode in `ContentView` ergänzen:

```swift
    /// Gedroppte Datei-URLs sequenziell hochladen (Ordner werden übersprungen).
    /// WICHTIG: awaited-Schleife — TransferViewModel.run verwirft parallele
    /// Aufrufe (isRunning-Guard); erst M5 bringt eine echte Queue.
    private func uploadDropped(_ urls: [URL], session: BrowserSession) {
        let files = urls.filter { url in
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(
                atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
            return exists && !isDirectory.boolValue
        }
        guard !files.isEmpty else { return }
        Task {
            for url in files {
                await transferViewModel.run(
                    fileName: url.lastPathComponent, direction: .upload,
                    source: session.localFS, sourcePath: url.path(percentEncoded: false),
                    destination: session.remoteFS,
                    destinationDirectory: session.remote.currentPath,
                    onCompleted: { await session.remote.refresh() }
                )
            }
        }
    }
```

- [ ] **Step 4: Bauen + Gesamtsuite** — `swift build && swift test`: 67 Tests grün (66 + 1).

- [ ] **Step 5: Commit**

```bash
git add Sources/MacSCPApp/BrowserPane.swift Sources/MacSCPApp/ContentView.swift Tests/macSCPCoreTests/TransferEngineTests.swift
git commit -m "feat: accept file drops on the remote pane with sequential upload

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Drag-Quelle (lokales Pane liefert Datei-URLs)

**Files:**
- Modify: `Sources/MacSCPApp/RemoteFileTableView.swift`
- Modify: `Sources/MacSCPApp/BrowserPane.swift` (Parameter durchreichen)
- Modify: `Sources/MacSCPApp/ContentView.swift` (Writer fürs lokale Pane)

**Interfaces:**
- Produces: `RemoteFileTableView(items:selectedPath:onOpen:onSelect:pasteboardWriter:)` mit `pasteboardWriter: ((RemoteFileItem) -> NSPasteboardWriting?)? = nil`; `BrowserPane(..., pasteboardWriter:)` reicht durch. Damit: lokale Zeile → Finder (Kopie durch Finder) und lokale Zeile → Remote-Pane (Upload über Task-1-Drop).

Kein Unit-Test (AppKit-Drag); Verifikation: Build + visueller Test in Task 4.

- [ ] **Step 1: Tabelle als Drag-Quelle**

In `Sources/MacSCPApp/RemoteFileTableView.swift`:

1. Property nach `onSelect` ergänzen:

```swift
    var pasteboardWriter: ((RemoteFileItem) -> NSPasteboardWriting?)? = nil
```

2. In `makeCoordinator()`/`updateNSView` den Writer an den Coordinator geben (analog zu `onOpen`/`onSelect`): Coordinator-Property `var pasteboardWriter: ((RemoteFileItem) -> NSPasteboardWriting?)?`, Zuweisung in beiden Methoden.

3. Im `Coordinator` die DataSource-Methode ergänzen:

```swift
        func tableView(
            _ tableView: NSTableView,
            pasteboardWriterForRow row: Int
        ) -> NSPasteboardWriting? {
            guard row >= 0, row < items.count else { return nil }
            return pasteboardWriter?(items[row])
        }
```

4. In `makeNSView` nach `table.doubleAction = ...` ergänzen (Drag nach außerhalb der App erlauben):

```swift
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
```

- [ ] **Step 2: BrowserPane durchreichen** — Property `var pasteboardWriter: ((RemoteFileItem) -> NSPasteboardWriting?)? = nil` ergänzen und im `RemoteFileTableView`-Aufruf `pasteboardWriter: pasteboardWriter` übergeben.

- [ ] **Step 3: Lokales Pane in ContentView** — das lokale `BrowserPane` erweitern:

```swift
                    BrowserPane(
                        title: "Lokal",
                        tint: DesignTokens.localAmber,
                        viewModel: session.local,
                        pasteboardWriter: { item in
                            item.kind == .file
                                ? NSURL(fileURLWithPath: item.path)
                                : nil
                        }
                    )
                    .frame(minWidth: 280)
```

(`import AppKit` in ContentView ergänzen, falls der Compiler `NSURL`/`NSPasteboardWriting` nicht sieht.)

- [ ] **Step 4: Bauen + Gesamtsuite** — `swift build && swift test`: 67 Tests grün.

- [ ] **Step 5: Commit**

```bash
git add Sources/MacSCPApp/
git commit -m "feat: make local pane rows draggable as file URLs

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Remote → Finder via NSFilePromiseProvider

**Files:**
- Create: `Sources/MacSCPApp/RemoteFilePromise.swift`
- Modify: `Sources/MacSCPApp/ContentView.swift` (Writer fürs Remote-Pane)

**Interfaces:**
- Produces: `RemoteFilePromiseProvider(item:download:)` — `download: @Sendable (RemoteFileItem, URL) async throws -> Void` wird beim Einlösen der Promise mit der Ziel-URL des Finders aufgerufen.

Kein Unit-Test (AppKit-Pasteboard); Verifikation: Build + visueller Test in Task 4.

- [ ] **Step 1: Promise-Provider**

`Sources/MacSCPApp/RemoteFilePromise.swift`:

```swift
import AppKit
import UniformTypeIdentifiers
import macSCPCore

/// File Promise für Remote-Zeilen: Der Finder erhält ein Versprechen und ruft
/// beim Ablegen writePromiseTo auf — erst dann wird die Datei heruntergeladen.
/// Läuft bewusst direkt über die TransferEngine (ohne TransferBar/Queue → M5).
final class RemoteFilePromiseProvider: NSFilePromiseProvider {
    private let strongDelegate: RemoteFilePromiseDelegate

    init(item: RemoteFileItem, download: @escaping @Sendable (RemoteFileItem, URL) async throws -> Void) {
        self.strongDelegate = RemoteFilePromiseDelegate(item: item, download: download)
        super.init()
        let ext = (item.name as NSString).pathExtension
        self.fileType = UTType(filenameExtension: ext)?.identifier ?? UTType.data.identifier
        self.delegate = strongDelegate
    }
}

private final class RemoteFilePromiseDelegate: NSObject, NSFilePromiseProviderDelegate {
    private let item: RemoteFileItem
    private let download: @Sendable (RemoteFileItem, URL) async throws -> Void

    init(item: RemoteFileItem, download: @escaping @Sendable (RemoteFileItem, URL) async throws -> Void) {
        self.item = item
        self.download = download
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        fileNameForType fileType: String
    ) -> String {
        item.name
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let item = self.item
        let download = self.download
        Task {
            do {
                try await download(item, url)
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }
    }
}
```

- [ ] **Step 2: Remote-Pane-Writer in ContentView**

Das Remote-`BrowserPane` um den Writer erweitern (zusätzlich zum `onDropURLs` aus Task 1):

```swift
                        pasteboardWriter: { item in
                            guard item.kind == .file else { return nil }
                            return RemoteFilePromiseProvider(item: item) { item, url in
                                try await TransferEngine.copyFile(
                                    from: session.remoteFS, sourcePath: item.path,
                                    to: LocalFileSystem(),
                                    destinationDirectory: url.deletingLastPathComponent()
                                        .path(percentEncoded: false),
                                    fileName: url.lastPathComponent,
                                    onProgress: { _ in }
                                )
                            }
                        },
```

(Reihenfolge der Parameter: `viewModel`, dann `onDropURLs`, dann `pasteboardWriter` — an die tatsächliche Property-Reihenfolge in `BrowserPane` anpassen.)

- [ ] **Step 3: Bauen + Gesamtsuite** — `swift build && swift test`: 67 Tests grün.

- [ ] **Step 4: Commit**

```bash
git add Sources/MacSCPApp/RemoteFilePromise.swift Sources/MacSCPApp/ContentView.swift
git commit -m "feat: drag remote files out as file promises

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Abschluss-Verifikation

- [ ] **Step 1:** `swift test` — 67 Tests grün
- [ ] **Step 2:** Docker-Rig hoch, `MACSCP_ITEST=1 swift test --filter CitadelFileSystem` — 6/6, Rig laufen lassen (visueller Test braucht ihn)
- [ ] **Step 3: Visueller Smoke-Test** (Koordinator am Bildschirm):
  1. Lokale Datei-Zeile aufs Remote-Pane ziehen → blaues Drop-Highlight beim Hover, Upload läuft (TransferBar Bernstein), Remote-Pane refresht
  2. Mehrere Dateien nacheinander droppen → alle kommen an (Sequenz)
  3. Ordner-Zeile ziehen → Drop wird ignoriert (kein Transfer, kein Crash)
  4. Remote-Zeile in den Finder ziehen (Desktop/Ordner) → Datei erscheint mit korrektem Inhalt (Promise-Download; Finder-Zugriff für den Test nötig — sonst diesen Punkt vom Maintainer verifizieren lassen)
  5. Rig danach: `docker compose -f docker/test-server/compose.yml down`
- [ ] **Step 4:** Checkboxen abhaken, Commit `docs: mark M2d plan tasks as completed` (mit Footer)

## Ausblick

Mit M2d ist **Meilenstein M2 (Browser) komplett**. Danach M3 — Sessions: Session-Manager (JSON in Application Support), Schlüsselbund für Geheimnisse, Key-/Agent-Auth, TOFU-Host-Keys, `~/.ssh/config`-Import, Sessions-Sidebar.
