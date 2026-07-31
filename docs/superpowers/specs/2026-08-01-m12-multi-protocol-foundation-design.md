# M12 — Multi-Protokoll-Fundament + Fähigkeits-Framework + dünnes S3 Design

**Status:** freigegeben (Brainstorming 2026-08-01)
**Meilenstein:** M12
**Sprache:** Design-Doc DE; Code/Kommentare EN; UI lokalisiert EN/DE/FR/PL

## Ziel

Die App vom SSH-Einzweck-Client zu einem **Protokoll-Plugin-System** umbauen:
ein Verbindungstyp-Diskriminator (`kind`), ein **Fähigkeits-Framework**, über
das jedes Backend Capabilities deklariert und eigene Beiträge (Formular-Schema,
Info-Felder, Kontextmenü-Einträge) liefert, plus als **erster zweiter Consumer
ein dünnes S3-Backend** (nur Verbinden + Browsen/Listen). SSH bleibt
durchgehend grün; S3-Transfer/CRUD/Presigned folgen in M13/M14.

Maintainer-Entscheidungen aus dem Brainstorming:
- **Scope:** Fundament + Framework + dünnes S3 **zusammen** (validiert die
  Abstraktion an zwei maximal verschiedenen Backends — POSIX-FS+Shell vs.
  flacher Objektspeicher — statt spekulativ).
- **Echtes Plugin-System** für die Zukunft (WebDAV/FTP/SMB als bloße
  Descriptors): die Capability-Achsen decken das Spektrum ab.
- **Login-Sets** bekommen ebenfalls `kind` + per-kind-Auth.
- **Seams für später:** Datei-Ebene- und Verbindungs-Ebene-Contributions
  werden als Typen angelegt; Presigned-URL (M14) und Diagnose-Tools (Ping/
  Traceroute/Speedtest, eigener späterer Meilenstein) docken dort an.
- Kein Release; weiter auf `develop`.

## Kontext / Ist-Zustand (verifiziert)

- **`RemoteFileSystem`** (Core-Protokoll, `Sources/macSCPCore/RemoteFS/`) ist
  bereits backend-agnostisch: `list/stat/readStream/write/delete/createDirectory/
  rename/setPermissions/deleteTree/homeDirectoryPath/disconnect`. `LocalFileSystem`
  und `CitadelFileSystem` implementieren es; die gesamte Browser-/Transfer-
  Schicht programmiert gegen `any RemoteFileSystem`. `CitadelFileSystem` wird
  namentlich nur an **zwei** Stellen referenziert (`ContentView.swift:1168`,
  `MacSCPCLI.swift:25`).
- **`RemoteShellProvider`** (`RemoteShell.swift:19`) ist bereits eine optionale
  Laufzeit-Capability (`as?`) — nur SSH liefert eine Shell. **Das ist das
  Vorbild** für die Laufzeit-Capability-Protokolle.
- **`Connector`-Typealias** (`ConnectionViewModel.swift:73`):
  `@Sendable (SSHConnectionConfig, @escaping @Sendable (HostKeyCandidate) async -> Bool) async throws -> any RemoteFileSystem`.
  Der zweite Parameter ist der TOFU-Host-Key-Decider — **SSH-spezifisch**.
- **`StoredSession`** (`Sessions/StoredSession.swift`): `Codable` (synthesized),
  alle Felder SSH (host/port/username/authKind/keyPath/groupID/loginSetID/jump);
  Vorwärtskompat über **optionale** Felder (nil = Legacy). **Kein `kind`.**
  ⚠️ synthesized Codable wendet KEINE Defaults auf fehlende Keys an → ein neues
  `kind` muss `decodeIfPresent(...) ?? .ssh` sein (custom `init(from:)`), sonst
  bricht Alt-JSON (M3d-Lektion: synthesized Codable umging schon einmal eine
  normalisierende Init).
- **Login-Sets:** `Sessions/LoginSetStore.swift` (+ `LoginSetsSheet.swift`);
  M10b. Aktuell SSH-geformt.
- **Formular:** `ConnectionFormView.swift` (~750 Z., SSH-Feldsektionen), gespeist
  von `ConnectionViewModel` (~888 Z., SSH-Auth/Jump/TOFU).
- **Kontextmenü:** `BrowserContextMenu.entries(for:side:)` ist eine PURE
  Core-Funktion (Datei-Ebene). **Info-Dialog:** `InfoPermissionsSheet`
  (Owner/Group/rwx). **Sidebar/Tab:** `SessionSidebar`, `TabStripView` (hier
  landet das Typ-Badge).
- **Package.swift:** `defaultLocalization: "en"`; Core listet lproj explizit,
  App via `.process("Resources")`. **swift-crypto** ist bereits Core-Dependency
  (liefert HMAC-SHA256/SHA256 für SigV4 — **keine neue Dependency**). URLSession
  (Foundation) für HTTP.
- **Test-Rig:** `docker/test-server/compose.yml` (zwei sshd-Container 2222/2223);
  `MACSCP_ITEST=1`. Ein **MinIO-Container** slottet identisch ein.

## Architektur

### 1. Diskriminator & Config (Core)

- **`ConnectionKind`** (`enum: String, Codable, CaseIterable, Sendable`):
  `case ssh, s3` (offen für `webdav`, `ftp`, `smb`).
- **`ConnectionConfig`** (`enum`): `case ssh(SSHConnectionConfig)`,
  `case s3(S3ConnectionConfig)`. Exhaustive-switchbar; typsicher.
- **`S3ConnectionConfig`** (neu, Core): `accessKeyID`, `region`, `endpoint`
  (S3-kompatibel), `bucket`, `usePathStyle: Bool`, optional `sessionToken`.
  **Secret Access Key NICHT im Config** — nur in der Keychain (`SecretStore`),
  wie das SSH-Passwort.
- **`Connector`** wird generalisiert:
  `@Sendable (ConnectionConfig, HostKeyDecider) async throws -> any RemoteFileSystem`
  (der Decider bleibt im Typ, wird von S3 schlicht nie aufgerufen). Ein zentraler
  **`BackendConnector`**-Dispatcher wählt nach `kind` das konkrete Connect
  (`CitadelFileSystem.connect` / `S3FileSystem.connect`).
- **`StoredSession.kind: ConnectionKind`** (`decodeIfPresent ?? .ssh`, custom
  `init(from:)`) + optionales `s3: S3ConnectionConfig?`-Payload. Alt-JSON lädt
  unverändert als `.ssh`. Analog `LoginSet` (kind + per-kind-Auth-Payload;
  geteilte Felder wie Anzeigename/Benutzername bleiben gemeinsam).

### 2. Fähigkeits-Framework (Core)

**A) Statischer `BackendDescriptor` je `kind`** (Registry, keine Live-Verbindung):
- **`ProtocolCapabilities`** (struct, deklarativ): `supportsShell: Bool`,
  `permissionModel: PermissionModel` (`.posixMode`/`.acl`/`.none`),
  `supportsSymlinks: Bool`, `atomicRename: Bool`, `directoriesAreReal: Bool`,
  `resumeMode: ResumeMode` (`.append`/`.rangeGet`/`.restOffset`/`.none`),
  `supportsPresignedURL: Bool`, `transport: TransportSecurity`
  (`.alwaysEncrypted`/`.optionalTLS`/`.plaintext`).
- **Formular-Schema + Provider-Presets:** eine `ConnectionFieldSchema`
  (geordnete Felder mit Label-Key, `isSecret`, Typ) + Auth-Modell +
  Presets-Liste (AWS, Hetzner, „Custom"). Das generische Formular rendert aus
  dem Schema; der Typ-Schalter tauscht nur das Schema.
- **Badge:** Kurzname + Symbol/Tint je `kind`.

Das generische UI liest **nur** `ProtocolCapabilities` fürs Gating: Terminal-
Knopf (`supportsShell`), Rechte-Editor (`permissionModel != .none`),
Symlink-Marker (`supportsSymlinks`), Resume-Banner (`resumeMode != .none`),
Klartext-Warnung (`transport == .plaintext`). **Kein `if kind == …` in der
generischen Schicht.**

**B) Laufzeit-Capability-Protokolle** an der `RemoteFileSystem`-Instanz (via
`as?`, wie `RemoteShellProvider`): Shell (SSH). Für später als Seam definiert:
`PresignedURLProvider` (S3, M14). M12 legt den Seam an, füllt ihn für S3 nicht.

**Contributions (beide Ebenen als Seam in M12, minimal gefüllt):**
- **Datei-Ebene:** `BrowserContextMenu.entries` akzeptiert vom Backend
  beigesteuerte Datei-Aktionen (M12: nur der generische Satz + SSHs Bestand;
  keine neuen S3-Einträge). Der **Info-Dialog** rendert generische +
  beigesteuerte Detail-Felder (SSH behält Owner/Group/Rechte/Symlink; S3 dünn:
  Größe/Datum/ETag).
- **Verbindungs-Ebene:** neuer Seam für Session/Tab-Aktionen (Diagnose-Tools
  docken später an). M12: nur der Seam, keine Einträge.

**Gating-Verhalten:** ein Nicht-SSH-Tab zeigt den Terminal-Knopf **nicht**; das
Terminal-Kürzel/-Menü ist deaktiviert; wird ein SSH-only-Kürzel dennoch auf
einem S3-Tab ausgelöst, gibt es eine **saubere, lokalisierte Fehlermeldung**
(kein stiller No-op, kein Crash).

### 3. Dünnes S3-Backend (Core, der zweite Consumer)

- **`SigV4Signer`** (neu): AWS Signature V4 (Canonical Request → String-to-Sign
  → HMAC-SHA256-Kette) über swift-crypto; `UNSIGNED-PAYLOAD` für GET (HTTPS).
  Unit-getestet gegen die **offiziellen AWS-SigV4-Testvektoren** (deterministisch,
  ohne Netz).
- **`S3FileSystem: RemoteFileSystem`** (dünn): `connect` (Endpoint/Region/Bucket
  + Access-Key aus Keychain, ein `ListObjectsV2`-Probe-Call zur Auth-Validierung),
  `list(path:)` (`ListObjectsV2` mit `prefix` + `delimiter="/"` → CommonPrefixes
  = synthetische Ordner + Objekte, **paginiert** über ContinuationToken),
  `stat`, `homeDirectoryPath` → `"/"`, `disconnect`. **Nicht in M12:** `write`/
  `readStream`/`delete`/`rename`/`createDirectory`/`deleteTree` werfen einen
  klaren „not supported yet"-Fehler (kommen in M13). `setPermissions` wirft
  `protocolError` (S3 hat keine POSIX-Rechte — dauerhaft).
- **Provider-Presets:** AWS (region→endpoint-Ableitung, virtual-hosted-style),
  Hetzner Object Storage (endpoint, path-style), „Custom" (freier Endpoint).
- **Fehler-Mapping:** HTTP 403→`authenticationFailed`, 404→`notFound`,
  Netz→`connectionFailed`, Rest→`protocolError`.

### 4. UI (App)

- **Verbindungsformular:** Typ-Schalter (Picker ssh/s3) oben; darunter die aus
  dem `ConnectionFieldSchema` generierte Feldsektion; Provider-Preset-Picker bei
  S3. SSH-Sektion (Auth/Jump/TOFU) bleibt, nur hinter dem `kind`.
- **Badge:** Typ-Badge (Kurzname/Symbol) in der Sidebar-Zeile und im Tab-Strip.
- **Gating:** Terminal-Toolbar-Knopf/-Menü + SSH-only-Aktionen per Capability
  aus-/eingeblendet; Kürzel-Fehlermeldung.
- **L10n:** neue Keys (Typ-Namen, S3-Feld-Labels, Provider-Namen, Gating-Fehler)
  in EN/DE/FR/PL (FR/PL KI-generiert, Native-Review-Markierung).

## Randfälle / bewusste Nicht-Ziele (M12)

- **S3 nur Verbinden + Browsen** — Up-/Download/Löschen/Umbenennen/Presigned/
  Cross-Backend sind M13/M14. In M12 sauber „noch nicht unterstützt".
- **Kein Live-Sprachwechsel-artiger Umbau** der Lookups.
- **Alt-Sessions/-Login-Sets** laden unverändert als `.ssh` (decodeIfPresent).
- **Secrets** (S3-Secret-Access-Key) nur in der Keychain, nie in JSON/Export im
  Klartext (Export-Pfad muss `kind`+S3 mit-serialisieren, Secret separat wie
  SSH).
- **SMB/FTP/WebDAV** sind NICHT Teil von M12 — nur die Achsen des Frameworks
  müssen sie konzeptionell tragen.

## Tests

- **Core (neu, TDD):** `ConnectionKind`/`ConnectionConfig`-Roundtrip;
  `StoredSession`/`LoginSet` `kind`-Decode (Alt-JSON → `.ssh`, neues S3 →
  Roundtrip); `ProtocolCapabilities`/Descriptor-Registry (SSH- und
  S3-Capabilities korrekt); `SigV4Signer` gegen **AWS-Testvektoren**
  (deterministisch); `S3FileSystem.list`-Parsing (ListObjectsV2-XML →
  RemoteFileItems, CommonPrefixes→Ordner, Pagination) mit einem Fake-HTTP-
  Transport (kein Netz).
- **Gated Integration:** **MinIO-Container** im Rig (Seed-Bucket); ein
  `S3FileSystemIntegrationTests` (connect + list gegen echtes MinIO, `MACSCP_ITEST=1`).
  SSH-Rig unverändert, weiter grün.
- **App (kein Test-Target):** Schema-getriebenes Formular, Badge, Gating per
  Build/Trace; **Runtime-Idle-CPU-Rauchtest** (M11n-Gewohnheit) — App startet,
  SSH-Verbindung unverändert, S3-Tab öffnet ohne Spin.
- **Regression:** die volle bestehende Suite bleibt grün (SSH-Pfad unangetastet
  hinter dem generalisierten Connector).

## Grobe Aufgaben-Schnitt (für den Plan)

1. **Core-Diskriminator:** `ConnectionKind` + `ConnectionConfig`-Enum +
   `S3ConnectionConfig` + `StoredSession.kind`/`s3` (decodeIfPresent) + Tests.
2. **Fähigkeits-Framework:** `ProtocolCapabilities` + `BackendDescriptor`-
   Registry + `ConnectionFieldSchema` + Contribution-Seam-Typen (Datei-/
   Verbindungs-Ebene) + Tests.
3. **Connector-Dispatcher:** generalisierter `Connector` + `BackendConnector`
   nach `kind`; SSH-Pfad wörtlich durchgereicht, Regression grün.
4. **SigV4Signer** (+ AWS-Testvektoren).
5. **S3FileSystem dünn** (connect + list + stat, XML-Parsing, Fehler-Mapping) +
   Fake-Transport-Tests + MinIO-Rig + gated Integrationstest.
6. **Login-Sets kind** + Resolver per kind + Export/Import `kind`+S3.
7. **App:** schema-getriebenes Formular + Typ-Schalter + Provider-Presets + Badge
   (Sidebar/Tab) + Capability-Gating (+Kürzel-Fehler) + L10n EN/DE/FR/PL.
8. **Abschluss-Verifikation** (gated inkl. MinIO, Whole-Milestone-Opus-Review,
   Runtime-Rauchtest, Push, Dev-Build).

## Global Constraints

- Swift 6, `.swiftLanguageMode(.v5)`, min. macOS 15; Swift Testing, TDD wo Logik
  entsteht.
- **Keine neue Dependency** — SigV4 über das vorhandene swift-crypto, HTTP über
  URLSession.
- Diskriminator/Capabilities/Config in **Core** (testbar); lokalisierte Labels in
  der App (Split wie `FileColumn`).
- **Vorwärtskompatibilität:** Alt-`sessions.json`/Login-Sets laden als `.ssh`
  (`decodeIfPresent ?? .ssh`).
- Secrets (SSH- **und** S3-) ausschließlich in der Keychain (`SecretStore`), nie
  in JSON.
- TOFU-Host-Key-Sicherheit unverändert für SSH; S3 hat keinen Decider.
- Code/Kommentare EN; UI-Strings EN/DE/FR/PL, kein ASCII-`"` in Nicht-EN;
  FR/PL KI-generiert (Native-Review vor Release).
- **M11n-Lektion:** Runtime-Idle-CPU-Rauchtest vor Auslieferung.
- Kein Release/Tag ohne ausdrückliche Maintainer-Anordnung.
