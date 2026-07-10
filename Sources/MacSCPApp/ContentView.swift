import AppKit
import SwiftUI
import macSCPCore

struct BrowserSession {
    let localFS: LocalFileSystem
    let remoteFS: any RemoteFileSystem
    let local: RemoteBrowserViewModel
    let remote: RemoteBrowserViewModel
    let terminal: TerminalPanelViewModel
}

/// Sheet-Item-Wrapper: verleiht `TransferConflict` `Identifiable`, ohne den
/// Core-Typ per Extension zu erweitern (bindende Vorgabe M5b/T4). Pro Prompt
/// genügt eine frische UUID, weil zu jeder Zeit höchstens ein Sheet offen ist.
struct ConflictPromptItem: Identifiable {
    let id = UUID()
    let conflict: TransferConflict
}

/// Hält die Continuation für den `ConflictDecider`-Prompt der Transfer-Queue.
/// Muster: `ConnectionViewModel.presentHostKeyPrompt` inkl. Cancellation-Handler
/// und Exactly-once-Auflösung. Reference-Typ (statt View-`@State`-Feld direkt),
/// weil `TransferQueueViewModel.conflictDecider` eine `@Sendable`-Closure ist,
/// die außerhalb des `ContentView`-Structs weiterlebt.
@MainActor
@Observable
final class ConflictPromptBridge {
    /// Aktuell offener Prompt — treibt `.sheet(item:)` in `ContentView`.
    private(set) var currentPrompt: ConflictPromptItem?
    private var continuation:
        CheckedContinuation<(resolution: ConflictResolution, applyToAll: Bool)?, Never>?

    /// Decider-Seite: von `TransferQueueViewModel.conflictDecider` awaited.
    /// Cancellation-sicher: bricht die aufrufende Task ab, während der Prompt
    /// offen ist, wird mit `nil` (Abbrechen) aufgelöst statt zu hängen.
    func ask(_ conflict: TransferConflict) async
        -> (resolution: ConflictResolution, applyToAll: Bool)?
    {
        currentPrompt = ConflictPromptItem(conflict: conflict)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: nil)
                    return
                }
                self.continuation = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resolve(nil)
            }
        }
    }

    /// Von den Sheet-Buttons aufgerufen. Exactly-once: eine zweite Auflösung
    /// (z.B. Doppelklick oder Dismiss nach Button-Tap) wird ignoriert.
    func resolve(_ result: (resolution: ConflictResolution, applyToAll: Bool)?) {
        guard let continuation else { return }
        self.continuation = nil
        currentPrompt = nil
        continuation.resume(returning: result)
    }

    /// Von außen (Teardown) aufrufbar: löst einen noch offenen Prompt mit
    /// "Abbrechen" auf. MUSS vor `transferQueue.cancelAll()` laufen — `cancelAll`
    /// blockt (dokumentiert) auf einem offenen Decider-Prompt, der sonst nie
    /// beantwortet würde (Deadlock beim Trennen mit offenem Sheet).
    func dismiss() {
        resolve(nil)
    }
}

/// Konflikt-Sheet-Inhalt. Eigener View-Typ wegen des lokalen Toggle-Status
/// (`applyToAll`) — SwiftUI instanziiert ihn frisch pro Sheet-Präsentation.
private struct ConflictSheetView: View {
    let conflict: TransferConflict
    let onResolve: (ConflictResolution, Bool) -> Void
    let onCancel: () -> Void

    @State private var applyToAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Datei existiert bereits")
                .font(.headline)
            Text("„\(conflict.fileName)“ existiert in „\(conflict.destinationDirectory)“.")
                .foregroundStyle(.secondary)
            Toggle("Für alle weiteren übernehmen", isOn: $applyToAll)
            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel) { onCancel() }
                Button("Umbenennen") { onResolve(.rename, applyToAll) }
                Button("Überspringen") { onResolve(.skip, applyToAll) }
                Button("Überschreiben", role: .destructive) { onResolve(.overwrite, applyToAll) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 360)
        // Escape/Klick-außerhalb dürfen den Prompt NICHT auflösen, ohne die
        // Continuation zu erfüllen — das würde `cancelAll`/die Queue hängen
        // lassen. Auflösung ausschließlich über die Buttons.
        .interactiveDismissDisabled(true)
    }
}

/// Vermittelt Zugriff auf das umschließende `NSWindow` — SwiftUI bietet dafür
/// keine eigene API. `view.window` ist erst gesetzt, NACHDEM die NSView in die
/// Fensterhierarchie eingehängt wurde, daher der `DispatchQueue.main.async`-
/// Umweg (M5c/T0).
private struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onResolve(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onResolve(nsView.window) }
    }
}

struct ContentView: View {
    /// Passed in from `MacSCPApp` (same instance as the `Settings` scene —
    /// no singleton, per the v2 multi-window rule). Wired into
    /// `transferQueue` at session start and kept in sync via `.onChange`
    /// (M5c/T4 queue parallelism, M5c/T5 bandwidth limits).
    let settingsStore: SettingsStore
    @State private var connectionViewModel = ConnectionViewModel(connector: { config, onUnknownHostKey in
        try await CitadelFileSystem.connect(
            config: config,
            knownHosts: KnownHostsStore(directory: SessionStore.defaultDirectory),
            onUnknownHostKey: onUnknownHostKey
        )
    })
    @State private var sessionListViewModel = SessionListViewModel(
        store: SessionStore(directory: SessionStore.defaultDirectory),
        secrets: KeychainSecretStore()
    )
    @State private var session: BrowserSession?
    @State private var activeSessionID: UUID?
    @State private var transferQueue = TransferQueueViewModel()
    @State private var isReconnecting = false
    @State private var importedHosts: [SSHConfigHost] = []
    @State private var conflictBridge = ConflictPromptBridge()
    /// Von `WindowAccessor` gereicht — Grundlage für die aktiven Resize-Aufrufe
    /// beim Zustandswechsel (M5c/T0).
    @State private var window: NSWindow?
    /// Letzte Browser-Fenstergröße, gemerkt beim Trennen — beim erneuten
    /// Verbinden wird darauf statt der Mindestgröße gewachsen, falls größer.
    @State private var lastBrowserSize: CGSize?

    private var sidebarDisabled: Bool {
        isReconnecting
            || transferQueue.isActive
            || connectionViewModel.state == .connecting
    }

    var body: some View {
        HSplitView {
            SessionSidebar(
                viewModel: sessionListViewModel,
                importedHosts: importedHosts,
                activeSessionID: activeSessionID,
                interactionsDisabled: sidebarDisabled,
                onSelect: { stored in connectStored(stored) },
                onDelete: { stored in
                    sessionListViewModel.delete(stored)
                    if activeSessionID == stored.id {
                        activeSessionID = nil
                    }
                },
                onNew: { disconnectToForm() },
                onSelectImported: { fillFromImported($0) }
            )
            .frame(minWidth: 170, idealWidth: 190, maxWidth: 260)

            detail
                .frame(minWidth: 590, maxWidth: .infinity)
        }
        // Kompaktes Formular vs. Browser: die Mindestgröße hängt vom
        // Verbindungszustand ab (M5c/T0) — ersetzt das globale `.frame` aus
        // `MacSCPApp.swift`.
        .frame(minWidth: session == nil ? 700 : 930, minHeight: 460)
        .background(WindowAccessor { window = $0 })
        .task { importedHosts = SSHConfigImporter.load(path: SSHConfigImporter.defaultPath) }
        // Settings live-wiring (M5c/T4+T5): each observer targets
        // `transferQueue` directly rather than a captured snapshot, so it
        // keeps applying to whichever session's queue is current. A change
        // affects FUTURE slot assignments/items only — see the properties'
        // doc comments in `TransferQueueViewModel`.
        .onChange(of: settingsStore.maxConcurrentTransfers) { _, newValue in
            transferQueue.maxConcurrent = newValue
        }
        .onChange(of: settingsStore.uploadLimitKBs) { _, newValue in
            transferQueue.uploadLimitBytesPerSec = newValue * 1024
        }
        .onChange(of: settingsStore.downloadLimitKBs) { _, newValue in
            transferQueue.downloadLimitBytesPerSec = newValue * 1024
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let session {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    uploadButton(session)
                    downloadButton(session)
                    Spacer()
                    Button {
                        session.terminal.toggle()
                    } label: {
                        Label("Terminal", systemImage: "terminal")
                    }
                    .keyboardShortcut("t", modifiers: .command)
                    .help("Terminal ein-/ausblenden (⌘T)")
                    Button("Trennen") {
                        disconnectToForm()
                    }
                    .disabled(transferQueue.isActive)
                }
                .padding(8)

                Divider()

                VSplitView {
                    HSplitView {
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

                        BrowserPane(
                            title: "Remote",
                            tint: DesignTokens.remoteBlue,
                            viewModel: session.remote,
                            onDropURLs: { urls in
                                uploadDropped(urls, session: session)
                            },
                            pasteboardWriter: { item in
                                item.kind == .file
                                    ? remotePromiseProvider(for: item, session: session)
                                    : nil
                            }
                        )
                        .frame(minWidth: 280)
                    }
                    .frame(minHeight: 200)
                    .layoutPriority(1)

                    if session.terminal.isVisible {
                        terminalPanel(session)
                            .frame(minHeight: 120, idealHeight: 220)
                    }
                }

                TransferQueueBar(viewModel: transferQueue)
            }
            .sheet(
                item: Binding(
                    get: { conflictBridge.currentPrompt },
                    set: { newValue in
                        if newValue == nil { conflictBridge.dismiss() }
                    }
                ),
                onDismiss: { conflictBridge.dismiss() }
            ) { item in
                ConflictSheetView(
                    conflict: item.conflict,
                    onResolve: { resolution, applyToAll in
                        conflictBridge.resolve((resolution: resolution, applyToAll: applyToAll))
                    },
                    onCancel: { conflictBridge.dismiss() }
                )
            }
        } else {
            // Formular oben ausrichten statt vertikal zu zentrieren (User-
            // Feedback 2026-07-10, M5c/T0) — das kompakte Fenster hat sonst
            // viel Leerraum unter dem Inhalt.
            ConnectionFormView(viewModel: connectionViewModel) { fs in
                startSession(with: fs)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    /// Wächst/schrumpft das Fenster aktiv (animiert) auf die Zielgröße und
    /// hält dabei die obere linke Ecke fest — AppKit zählt `origin.y` von
    /// unten, daher wird sie um die Höhendifferenz nachgeführt.
    private func resizeWindow(toWidth width: CGFloat, height: CGFloat) {
        guard let window else { return }
        let current = window.frame
        let newOrigin = NSPoint(x: current.origin.x, y: current.origin.y + current.height - height)
        let newFrame = NSRect(origin: newOrigin, size: CGSize(width: width, height: height))
        window.setFrame(newFrame, display: true, animate: true)
    }

    /// Panel-Inhalt: Terminal bei laufender Shell, sonst Ende-/Leerzustand.
    /// `SSHTerminalView` wird bewusst nur bei aktiver Shell eingehängt, damit
    /// `onOutput` bei jedem Neuöffnen frisch bindet.
    @ViewBuilder
    private func terminalPanel(_ session: BrowserSession) -> some View {
        ZStack {
            Color(nsColor: DesignTokens.terminalBackground)
            switch session.terminal.state {
            case .running, .opening:
                SSHTerminalView(viewModel: session.terminal)
            case .ended(let message):
                VStack(spacing: 8) {
                    Text(message ?? "Shell beendet.")
                        .foregroundStyle(Color(nsColor: DesignTokens.terminalText))
                    Button("Neu öffnen") { session.terminal.openIfNeeded() }
                }
            case .closed:
                Color.clear
            }
        }
    }

    /// Nach erfolgreichem Verbinden: Panes aufbauen und ggf. Session speichern.
    private func startSession(with fs: any RemoteFileSystem) {
        let shellProvider = fs as? RemoteShellProvider
        session = BrowserSession(
            localFS: LocalFileSystem(),
            remoteFS: fs,
            local: RemoteBrowserViewModel(fs: LocalFileSystem(), startPath: NSHomeDirectory()),
            remote: RemoteBrowserViewModel(fs: fs),
            terminal: TerminalPanelViewModel(openShell: { term, cols, rows in
                guard let shellProvider else {
                    throw RemoteFSError.protocolError(
                        reason: "Diese Verbindung unterstützt kein Terminal.")
                }
                return try await shellProvider.openShell(
                    terminal: term, cols: cols, rows: rows)
            })
        )
        transferQueue = TransferQueueViewModel()
        let bridge = conflictBridge
        transferQueue.conflictDecider = { conflict in await bridge.ask(conflict) }
        // Settings wiring (M5c/T4 concurrency, M5c/T5 bandwidth): applied once
        // here at session start, and kept in sync afterwards by the
        // `.onChange` observers below (they target `transferQueue` directly,
        // so they keep working across session restarts too). KBs → bytes/s.
        transferQueue.maxConcurrent = settingsStore.maxConcurrentTransfers
        transferQueue.uploadLimitBytesPerSec = settingsStore.uploadLimitKBs * 1024
        transferQueue.downloadLimitBytesPerSec = settingsStore.downloadLimitKBs * 1024

        // Fenster aktiv auf Browser-Größe wachsen lassen (User-Feedback
        // 2026-07-10, M5c/T0) — auf die zuletzt gemerkte Browser-Größe, falls
        // vorhanden und größer als die Mindestgröße.
        let targetSize = CGSize(
            width: max(lastBrowserSize?.width ?? 0, 930),
            height: max(lastBrowserSize?.height ?? 0, 620))
        resizeWindow(toWidth: targetSize.width, height: targetSize.height)

        if connectionViewModel.shouldSaveSession {
            let stored = sessionListViewModel.save(
                name: connectionViewModel.saveName
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                host: connectionViewModel.host
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                port: Int(connectionViewModel.port
                    .trimmingCharacters(in: .whitespaces)) ?? 22,
                username: connectionViewModel.username
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                password: connectionViewModel.password,
                authKind: connectionViewModel.authChoice == .password ? .password : .privateKey,
                keyPath: connectionViewModel.authChoice == .privateKey
                    ? connectionViewModel.keyPath.trimmingCharacters(in: .whitespacesAndNewlines)
                    : nil
            )
            activeSessionID = stored?.id
            connectionViewModel.shouldSaveSession = false
        }
    }

    /// Sidebar-Klick: bestehende Verbindung trennen, Formular aus Store +
    /// Schlüsselbund füllen und direkt verbinden.
    private func connectStored(_ stored: StoredSession) {
        guard !isReconnecting else { return }
        isReconnecting = true // synchron — sperrt die Sidebar sofort, vor dem ersten await
        Task {
            defer { isReconnecting = false }
            await teardownSession()
            connectionViewModel.host = stored.host
            connectionViewModel.port = String(stored.port)
            connectionViewModel.username = stored.username
            connectionViewModel.saveName = stored.name
            connectionViewModel.shouldSaveSession = false
            connectionViewModel.password = sessionListViewModel.password(for: stored) ?? ""
            connectionViewModel.authChoice =
                stored.authKind == .privateKey ? .privateKey : .password
            connectionViewModel.keyPath = stored.keyPath ?? ""

            if let fs = await connectionViewModel.connect() {
                startSession(with: fs)
                activeSessionID = stored.id
            }
        }
    }

    /// Import-Klick: Formular aus dem ssh-config-Eintrag füllen — bewusst
    /// OHNE Verbinden (der Import kennt keine Geheimnisse).
    private func fillFromImported(_ host: SSHConfigHost) {
        guard !isReconnecting else { return }
        isReconnecting = true // synchron — verhindert Doppel-Teardown (korrumpiert lastBrowserSize)
        Task {
            defer { isReconnecting = false }
            await teardownSession()
            connectionViewModel.host = host.hostName ?? host.alias
            connectionViewModel.port = String(host.port ?? 22)
            connectionViewModel.username = host.user ?? ""
            connectionViewModel.saveName = host.alias
            connectionViewModel.shouldSaveSession = false
            if let identityFile = host.identityFile {
                connectionViewModel.authChoice = .privateKey
                connectionViewModel.keyPath = identityFile
            } else {
                connectionViewModel.authChoice = .password
                connectionViewModel.keyPath = ""
            }
        }
    }

    private func disconnectToForm() {
        guard !isReconnecting else { return }
        isReconnecting = true // synchron — verhindert Doppel-Teardown (korrumpiert lastBrowserSize)
        Task {
            defer { isReconnecting = false }
            await teardownSession()
        }
    }

    private func teardownSession() async {
        let hadSession = session != nil
        if let session {
            // MUSS vor `cancelAll()` laufen: ein offenes Konflikt-Sheet hält
            // sonst den Decider-Prompt offen, an dem `cancelAll` (dokumentiert)
            // hängen bleibt, bis er beantwortet wird — Deadlock beim Trennen.
            conflictBridge.dismiss()
            await transferQueue.cancelAll()
            await session.terminal.shutdown()
            await session.remote.disconnect()
        }
        connectionViewModel.clearPassword()
        connectionViewModel.authChoice = .password
        connectionViewModel.keyPath = ""
        session = nil
        activeSessionID = nil
        if hadSession {
            // Aktuelle Browser-Größe merken (für das nächste Verbinden) und
            // Fenster aktiv auf die kompakte Formular-Größe schrumpfen
            // (User-Feedback 2026-07-10, M5c/T0).
            if let window { lastBrowserSize = window.frame.size }
            resizeWindow(toWidth: 700, height: 460)
        }
    }

    /// Lokal ausgewählte Datei ODER Ordner → aktuelles Remote-Verzeichnis.
    /// Symlink-Auswahl bleibt deaktiviert (kein sinnvolles Transfer-Ziel).
    @ViewBuilder
    private func uploadButton(_ session: BrowserSession) -> some View {
        let selected = session.local.selectedItem
        Button {
            guard let selected else { return }
            if selected.kind == .directory {
                transferQueue.enqueueTree(
                    directoryName: selected.name, direction: .upload,
                    source: session.localFS, sourceDirectory: selected.path,
                    destination: session.remoteFS,
                    destinationDirectory: session.remote.currentPath,
                    onCompleted: { [weak remote = session.remote] in await remote?.refresh() }
                )
            } else {
                transferQueue.enqueue(
                    fileName: selected.name, direction: .upload,
                    source: session.localFS, sourcePath: selected.path,
                    destination: session.remoteFS,
                    destinationDirectory: session.remote.currentPath,
                    onCompleted: { [weak remote = session.remote] in await remote?.refresh() }
                )
            }
        } label: {
            Label("Hochladen", systemImage: "arrow.up")
        }
        .tint(DesignTokens.localAmber)
        .disabled(selected == nil || selected?.kind == .symlink)
        .help("Ausgewählte lokale Datei/Ordner ins Remote-Verzeichnis hochladen")
    }

    /// Remote ausgewählte Datei ODER Ordner → aktuelles lokales Verzeichnis.
    /// Symlink-Auswahl bleibt deaktiviert (kein sinnvolles Transfer-Ziel).
    @ViewBuilder
    private func downloadButton(_ session: BrowserSession) -> some View {
        let selected = session.remote.selectedItem
        Button {
            guard let selected else { return }
            if selected.kind == .directory {
                transferQueue.enqueueTree(
                    directoryName: selected.name, direction: .download,
                    source: session.remoteFS, sourceDirectory: selected.path,
                    destination: session.localFS,
                    destinationDirectory: session.local.currentPath,
                    onCompleted: { [weak local = session.local] in await local?.refresh() }
                )
            } else {
                transferQueue.enqueue(
                    fileName: selected.name, direction: .download,
                    source: session.remoteFS, sourcePath: selected.path,
                    destination: session.localFS,
                    destinationDirectory: session.local.currentPath,
                    onCompleted: { [weak local = session.local] in await local?.refresh() }
                )
            }
        } label: {
            Label("Herunterladen", systemImage: "arrow.down")
        }
        .tint(DesignTokens.remoteBlue)
        .disabled(selected == nil || selected?.kind == .symlink)
        .help("Ausgewählte Remote-Datei/Ordner ins lokale Verzeichnis herunterladen")
    }

    /// Gedroppte Datei-/Ordner-URLs in die Queue einreihen. Dateien laufen über
    /// `enqueue`, Ordner rekursiv über `enqueueTree` (M5b/T3/T4) — kein
    /// Directory-Filter mehr, nur nicht (mehr) existierende URLs werden verworfen.
    private func uploadDropped(_ urls: [URL], session: BrowserSession) {
        for url in urls {
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(
                atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
            guard exists else { continue }
            if isDirectory.boolValue {
                transferQueue.enqueueTree(
                    directoryName: url.lastPathComponent, direction: .upload,
                    source: session.localFS, sourceDirectory: url.path(percentEncoded: false),
                    destination: session.remoteFS,
                    destinationDirectory: session.remote.currentPath,
                    onCompleted: { [weak remote = session.remote] in await remote?.refresh() }
                )
            } else {
                transferQueue.enqueue(
                    fileName: url.lastPathComponent, direction: .upload,
                    source: session.localFS, sourcePath: url.path(percentEncoded: false),
                    destination: session.remoteFS,
                    destinationDirectory: session.remote.currentPath,
                    onCompleted: { [weak remote = session.remote] in await remote?.refresh() }
                )
            }
        }
    }

    /// Promise-Einlösung: Remote-Datei über die Queue an die vom Finder
    /// vorgegebene URL laden — serialisiert sich mit allen anderen Transfers.
    private func remotePromiseProvider(
        for item: RemoteFileItem, session: BrowserSession
    ) -> RemoteFilePromiseProvider {
        RemoteFilePromiseProvider(item: item) { item, url in
            try await transferQueue.enqueueAndWait(
                fileName: url.lastPathComponent, direction: .download,
                source: session.remoteFS, sourcePath: item.path,
                destination: session.localFS,
                destinationDirectory: url.deletingLastPathComponent()
                    .path(percentEncoded: false)
            )
        }
    }
}
