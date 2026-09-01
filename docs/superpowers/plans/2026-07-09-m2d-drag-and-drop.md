# macSCP M2d — Drag & Drop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Transfer files via drag & drop — Finder/local pane → remote pane (upload) and remote row → Finder (download via File Promise).

**Architecture:** The remote `BrowserPane` becomes a SwiftUI `onDrop` target for `.fileURL` (with tint highlight); dropped files run **sequentially** through the existing `TransferViewModel` (review warning from M2c: the `isRunning` guard swallows concurrent calls — the drop loop therefore awaits each transfer). The AppKit table becomes a drag source via a pane-specific `NSPasteboardWriting` provider: locally it supplies `NSURL` (Finder copies it itself; dropping onto the remote pane uses the same upload path), remote supplies an `NSFilePromiseProvider` whose delegate downloads the file straight through the `TransferEngine` to the URL Finder hands it, once redeemed.

**Dependencies:** Task 1 → Task 2 → Task 3 → Task 4 (all end in `ContentView` — NO parallel phase in this plan).

**Tech Stack:** as M2c; plus UniformTypeIdentifiers (`UTType.fileURL`) and `NSFilePromiseProvider` (AppKit).

## Global Constraints

- swift-tools-version 6.0, Language Mode v5; macOS 14; UI text German
- Conventional Commits, footer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`; never push (the coordinator does that)
- YAGNIs for M2d: NO directory drops (folders are silently skipped), NO Finder progress for promises (NSProgress registration → M5), NO drop onto the LOCAL pane (Finder→local would be a local copy — not our job), NO conflict dialogs (overwrite, as in M2c)
- Drops run strictly sequentially through `TransferViewModel.run` (awaited loop); promise downloads deliberately run PAST the TransferBar directly through the engine (documented; queue integration → M5)
- After every task: `swift test` green (without Docker)

## File Map (Delta M2d)

```
Sources/macSCPCore/Presentation/TransferViewModel.swift  (unchanged — new sequence test in Tests)
Sources/MacSCPApp/
  BrowserPane.swift            (Task 1 — onDropURLs + drop highlight; Task 2 — pass through pasteboardWriter)
  RemoteFileTableView.swift    (Task 2 — pasteboardWriterForRow)
  RemoteFilePromise.swift      (Task 3 — new: provider + delegate)
  ContentView.swift            (Task 1 drop handler; Task 2 local writer; Task 3 remote writer)
Tests/macSCPCoreTests/
  TransferEngineTests.swift    (Task 1 — +1 sequence test)
```

---

### Task 1: Sequential drop upload onto the remote pane

**Files:**
- Modify: `Sources/MacSCPApp/BrowserPane.swift`
- Modify: `Sources/MacSCPApp/ContentView.swift`
- Test: `Tests/macSCPCoreTests/TransferEngineTests.swift` (+1 test)

**Interfaces:**
- Produces: `BrowserPane(title:tint:viewModel:onDropURLs:)` with `onDropURLs: (([URL]) -> Void)? = nil` — only the remote pane gets a handler; panes without a handler reject drops.

- [x] **Step 1: Failing test (sequence guarantee in the VM)** — add to `TransferEngineTests`:

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

Run: `swift test --filter TransferEngineTests` — the test is NEW and must be GREEN on the first run (it documents the sequence guarantee the drop handler relies on; if it is RED, there is a real bug in the isRunning guard — then STOP and report).

- [x] **Step 2: Extend BrowserPane with a drop target**

`Sources/MacSCPApp/BrowserPane.swift` — replace the file entirely:

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

- [x] **Step 3: Drop handler in ContentView**

In `Sources/MacSCPApp/ContentView.swift`: extend the remote `BrowserPane` in the `HSplitView` (the local pane stays WITHOUT `onDropURLs`):

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

and add as a private method to `ContentView`:

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

- [x] **Step 4: Build + full suite** — `swift build && swift test`: 67 tests green (66 + 1).

- [x] **Step 5: Commit**

```bash
git add Sources/MacSCPApp/BrowserPane.swift Sources/MacSCPApp/ContentView.swift Tests/macSCPCoreTests/TransferEngineTests.swift
git commit -m "feat: accept file drops on the remote pane with sequential upload

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Drag source (local pane supplies file URLs)

**Files:**
- Modify: `Sources/MacSCPApp/RemoteFileTableView.swift`
- Modify: `Sources/MacSCPApp/BrowserPane.swift` (pass parameter through)
- Modify: `Sources/MacSCPApp/ContentView.swift` (writer for the local pane)

**Interfaces:**
- Produces: `RemoteFileTableView(items:selectedPath:onOpen:onSelect:pasteboardWriter:)` with `pasteboardWriter: ((RemoteFileItem) -> NSPasteboardWriting?)? = nil`; `BrowserPane(..., pasteboardWriter:)` passes it through. So: local row → Finder (Finder copies) and local row → remote pane (upload via the Task 1 drop).

No unit test (AppKit drag); verification: build + visual test in Task 4.

- [x] **Step 1: Table as a drag source**

In `Sources/MacSCPApp/RemoteFileTableView.swift`:

1. Add a property after `onSelect`:

```swift
    var pasteboardWriter: ((RemoteFileItem) -> NSPasteboardWriting?)? = nil
```

2. In `makeCoordinator()`/`updateNSView` pass the writer to the coordinator (analogous to `onOpen`/`onSelect`): coordinator property `var pasteboardWriter: ((RemoteFileItem) -> NSPasteboardWriting?)?`, assigned in both methods.

3. Add the data-source method in `Coordinator`:

```swift
        func tableView(
            _ tableView: NSTableView,
            pasteboardWriterForRow row: Int
        ) -> NSPasteboardWriting? {
            guard row >= 0, row < items.count else { return nil }
            return pasteboardWriter?(items[row])
        }
```

4. In `makeNSView`, after `table.doubleAction = ...`, add (allow dragging outside the app):

```swift
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
```

- [x] **Step 2: Pass through BrowserPane** — add the property `var pasteboardWriter: ((RemoteFileItem) -> NSPasteboardWriting?)? = nil` and pass `pasteboardWriter: pasteboardWriter` at the `RemoteFileTableView` call site.

- [x] **Step 3: Local pane in ContentView** — extend the local `BrowserPane`:

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

(Add `import AppKit` to ContentView if the compiler cannot see `NSURL`/`NSPasteboardWriting`.)

- [x] **Step 4: Build + full suite** — `swift build && swift test`: 67 tests green.

- [x] **Step 5: Commit**

```bash
git add Sources/MacSCPApp/
git commit -m "feat: make local pane rows draggable as file URLs

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Remote → Finder via NSFilePromiseProvider

**Files:**
- Create: `Sources/MacSCPApp/RemoteFilePromise.swift`
- Modify: `Sources/MacSCPApp/ContentView.swift` (writer for the remote pane)

**Interfaces:**
- Produces: `RemoteFilePromiseProvider(item:download:)` — `download: @Sendable (RemoteFileItem, URL) async throws -> Void` is called with Finder's destination URL when the promise is redeemed.

No unit test (AppKit pasteboard); verification: build + visual test in Task 4.

- [x] **Step 1: Promise provider**

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

- [x] **Step 2: Remote pane writer in ContentView**

Extend the remote `BrowserPane` with the writer (in addition to `onDropURLs` from Task 1):

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

(Parameter order: `viewModel`, then `onDropURLs`, then `pasteboardWriter` — match the actual property order in `BrowserPane`.)

- [x] **Step 3: Build + full suite** — `swift build && swift test`: 67 tests green.

- [x] **Step 4: Commit**

```bash
git add Sources/MacSCPApp/RemoteFilePromise.swift Sources/MacSCPApp/ContentView.swift
git commit -m "feat: drag remote files out as file promises

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Final verification

- [x] **Step 1:** `swift test` — 67 tests green
- [x] **Step 2:** Docker rig up, `MACSCP_ITEST=1 swift test --filter CitadelFileSystem` — 6/6, leave the rig running (the visual test needs it)
- [x] **Step 3: Visual smoke test** (coordinator at the screen):
  1. Drag a local file row onto the remote pane → blue drop highlight on hover, upload runs (amber TransferBar), remote pane refreshes
  2. Drop several files in sequence → all arrive (sequence)
  3. Drag a folder row → drop is ignored (no transfer, no crash)
  4. Drag a remote row into Finder (desktop/folder) → file appears with correct content (promise download; needs Finder access for the test — otherwise have the maintainer verify this point)
  5. Rig afterwards: `docker compose -f docker/test-server/compose.yml down`
- [x] **Step 4:** Check off checkboxes, commit `docs: mark M2d plan tasks as completed` (with footer)

## Outlook

M2d completes **Milestone M2 (Browser)**. After that, M3 — Sessions: session manager (JSON in Application Support), keychain for secrets, key/agent auth, TOFU host keys, `~/.ssh/config` import, sessions sidebar.
