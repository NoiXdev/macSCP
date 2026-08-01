# M13 — S3-Transfer/CRUD Design

**Status:** freigegeben (Brainstorming 2026-08-01)
**Meilenstein:** M13
**Sprache:** Design-Doc DE; Code/Kommentare EN; keine neuen UI-Strings erwartet
(die Fehler-/Aktions-Texte existieren backend-agnostisch aus M5/M7).

## Ziel

Die in M12 gestubbten mutierenden `S3FileSystem`-Operationen echt
implementieren, sodass ein S3-Backend im Browser vollwertig transferieren und
CRUD kann: **Download (`readStream`), Upload (`write`), `delete`,
`createDirectory`, `rename`, `deleteTree`**. `setPermissions` bleibt bewusst
`protocolError` (S3 hat kein POSIX-Rechtemodell — die Capability
`permissionModel == .none` blendet den Editor ohnehin aus).

Validiert gegen das echte MinIO-Rig (`http://127.0.0.1:19000`, Bucket
`macscp-seed`) und über den vorhandenen `SigV4Signer`. **Keine neue
Dependency** (Foundation `URLSession`/`XMLParser` + swift-crypto via Signer).

**Nicht in M13:** Cross-Backend-Transfer S3↔SSH (die Engine ist
backend-agnostisch — nach M13 läuft das prinzipiell „geschenkt", die
*explizite* gated Verifikation + Doppel-Drossel-Härtung ist **M14**);
Presigned-URLs (M14); echtes Upload-Resume (S3 kann es strukturell nicht,
siehe §6).

## Ausgangslage (Ist)

`S3FileSystem` (M12/T5) hat reale, signierte `connect`/`list`/`stat`
(ListObjectsV2); alle mutierenden Methoden werfen
`RemoteFSError.protocolError`. `SigV4Signer.authorizationHeader(method:host:
path:query:headers:payloadHash:date:)` trägt bereits beliebige Methoden +
Payload-Hash (die statische `canonicalQueryString` ist `internal`, single
source). `S3HTTPTransport.send(_:) -> (Data, HTTPURLResponse)` liefert nur
**gepuffert**. `TransferEngine.copyFile(from:…:resume:…)` treibt
`source.stat().size` → `source.readStream(fromOffset:)` → `destination.write(
mode:contents:)`; `resume` ist ein **opt-in-Flag** des Aufrufers.

## S3-API-Mapping

| `RemoteFileSystem` | S3-Operation |
|---|---|
| `readStream(path:fromOffset:)` | `GET {key}` mit `Range: bytes={offset}-`, gestreamt; Offset ≥ EOF → leerer Stream (kein Fehler) |
| `write(overwrite)` | Hybrid: ≤ Schwelle → einzelner `PUT {key}`; sonst Multipart |
| `write(append)` | für S3-Ziel strukturell unmöglich → durch Engine-Sperre nie ausgelöst (§6) |
| `delete(path:)` | `DELETE {key}` (einzelnes Objekt; Datei-Kontrakt) |
| `createDirectory(at:)` | `PUT {key}/` mit 0-Byte-Body (Marker-Objekt), idempotent |
| `rename(from:to:)` (Datei) | `PUT {toKey}` mit `x-amz-copy-source: /{bucket}/{fromKey}` (URL-enc.) + `DELETE {fromKey}` |
| `rename(from:to:)` (Ordner) | copy+delete für **jedes** Objekt unter dem Prefix (inkl. Marker); nicht atomar, O(N) |
| `deleteTree(at:)` | rekursiv listen (kein Delimiter) → `POST {bucket}?delete` (DeleteObjects) in ≤1000er-Batches; Marker inklusive |
| `setPermissions` | weiter `protocolError` (kein POSIX) |
| `homeDirectoryPath` | `"/"` (unverändert) |

Key-Ableitung nutzt die vorhandene `S3FileSystem.s3Prefix(forPath:)`-Logik
(kein führender Slash; Objekt-Key ohne, „Verzeichnis"-Key mit `/`-Suffix).

## Architektur / Komponenten

### 1. Transport-Seam (`S3HTTPTransport`)

Wächst um **genau eine** Methode für gestreamte Downloads:

```swift
public protocol S3HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
    func sendStreaming(_ request: URLRequest) async throws
        -> (body: AsyncThrowingStream<Data, Error>, response: HTTPURLResponse)
}
```

- `URLSessionS3Transport.sendStreaming` nutzt `URLSession.bytes(for:)`,
  liest die `AsyncBytes` und emittiert `TransferChunk.size`-große `Data`-Stücke
  als `AsyncThrowingStream`. Nicht-2xx wird VOR dem Streamen als
  `RemoteFSError` gemappt (403/404/sonst), damit Fehler nicht erst im
  Stream-Consumer auftauchen.
- **Uploads brauchen keinen neuen Seam**: der `URLRequest` trägt `httpBody`
  (die gepufferte kleine Datei bzw. der gepufferte Multipart-Teil), das
  vorhandene `send` genügt (Antworten sind klein: ETag/XML).
- `FakeS3Transport` (Tests) implementiert beide Wege — `sendStreaming` liefert
  einen kanonischen Byte-Stream aus kanned `Data`.

### 2. Upload (`S3Uploader`, neue Datei `Sources/macSCPCore/S3/S3Uploader.swift`)

Ein fokussierter Uploader, den `S3FileSystem.write` aufruft. Kapselt die
Hybrid-Entscheidung und den Multipart-Lebenszyklus.

- **Schwelle: 8 MiB** (`partSize`/`singlePutThreshold`, Konstante). Puffert
  aus dem Chunk-Stream bis zur Schwelle:
  - Stream endet vor der Schwelle → **einzelner `PUT {key}`** mit
    `x-amz-content-sha256 = hex(sha256(body))` (der Body liegt vollständig
    vor, also echte Signatur; `Content-Length` gesetzt).
  - Schwelle erreicht → **Multipart**:
    1. `POST {key}?uploads` → `UploadId` aus dem XML (`InitiateMultipartUpload`).
    2. je Teil `PUT {key}?partNumber={n}&uploadId={id}` mit dem gepufferten
       Teil (≥5 MiB außer dem letzten), `x-amz-content-sha256: UNSIGNED-PAYLOAD`;
       `ETag` aus dem Response-Header sammeln (Teilnummer → ETag).
    3. `POST {key}?uploadId={id}` mit `CompleteMultipartUpload`-XML (sortierte
       `<Part><PartNumber><ETag>`).
- **Abbruch/Fehler**: jeder Fehler nach `Initiate` (inkl.
  `CancellationError`) löst **immer** `DELETE {key}?uploadId={id}`
  (`AbortMultipartUpload`) aus, bevor der Fehler weitergereicht wird — kein
  verwaister Multipart-Upload, der sonst Speicher kostet/kostenpflichtig ist.
- `Task.checkCancellation()` vor jedem Teil.
- 5 MiB ist das S3-Minimum je Teil (außer letztem); die 8-MiB-Schwelle liegt
  bewusst darüber, damit ein Multipart immer ≥2 valide Teile bilden kann.

### 3. Download (`S3FileSystem.readStream`)

Baut den signierten Range-GET (`Range: bytes={offset}-`), ruft
`transport.sendStreaming`, reicht dessen Body-Stream durch (bereits in
`TransferChunk.size` geschnitten). Offset ≥ Objektgröße → S3 antwortet 416
(oder leer); wird auf einen **leeren** Stream abgebildet (kein Fehler — der
Protocol-Kontrakt verlangt „Offset at or beyond EOF yields an empty stream").
Signatur mit `payloadHash = emptyPayloadHash` (GET hat keinen Body).

### 4. CRUD-Operationen (`S3FileSystem`)

- `delete`: signierter `DELETE {key}`; 204/200 → ok, 404 → `.notFound`.
- `createDirectory`: signierter `PUT {key}/` mit leerem Body
  (`payloadHash = emptyPayloadHash`), idempotent (erneutes Anlegen ist ok).
- `rename` (Datei): `PUT {toKey}` mit `x-amz-copy-source`-Header (Wert
  `/{bucket}/{fromKey}`, RFC-3986-kodiert), leerer Body; danach
  `DELETE {fromKey}`. **S3-PUT-Copy überschreibt still** — daher prüft `rename`
  die Ziel-Existenz **aktiv vorab** (`stat {toKey}`; gefunden → `RemoteFSError`
  statt still überschreiben, Protocol-Kontrakt). Da `stat` auch die Art kennt,
  entscheidet `S3FileSystem` Datei- vs. Ordner-Pfad.
- `rename` (Ordner): rekursiv alle Keys unter `fromPrefix` listen, für jeden
  `copy {from} → {to}` (Prefix-Ersetzung) + `delete {from}`; inkl. des
  `…/`-Markers. Nicht atomar (dokumentiert); ein Teil-Fehler lässt bereits
  kopierte Objekte am Ziel stehen (kein Rollback — v1, dokumentiert).
- `deleteTree`: rekursiv (ohne Delimiter) alle Keys unter dem Prefix listen,
  in ≤1000er-Batches per `POST {bucket}?delete` (DeleteObjects-XML mit
  `Content-MD5`, das die S3-API hier verlangt) löschen; Marker inklusive.
  Kooperativ abbrechbar pro Batch; ein Abbruch lässt einen teilweise
  gelöschten Baum stehen (wie Citadel/Local, dokumentiert).

### 5. Signatur mit Body

`buildSignedRequest(method:key:query:headers:body:payloadHash:)`-Helfer in
`S3FileSystem` (Verallgemeinerung des vorhandenen `buildListRequest`): baut die
URL (path- vs. virtual-host), signiert mit dem gegebenen `payloadHash`, setzt
`httpBody` wenn vorhanden. `Content-Length` folgt aus `httpBody`.
Wire-Query weiterhin über `SigV4Signer.canonicalQueryString` (I-1-Fix aus M12
bleibt die single source der Query-Kodierung).

### 6. Resume-Sperre (Core-Härtung — sicherheitskritisch für Korrektheit)

S3 kann keinen `.append`. Die Engine darf gegen ein S3-Ziel **niemals** einen
Tail anhängen (sonst würde ein bestehendes, größen-verschiedenes Objekt am
selben Key korrumpiert).

- Neu am Protokoll: `var supportsAppendResume: Bool { get }` mit
  Default-Extension `true`. `LocalFileSystem`/`CitadelFileSystem` erben `true`;
  `S3FileSystem` gibt `false`.
- `TransferEngine.copyFile` behandelt intern `let resume = resume &&
  destination.supportsAppendResume`. Damit ist für ein S3-Ziel `resumeOffset`
  immer 0 und der Write-Mode immer `.overwrite` — egal was der Aufrufer
  übergibt (Belt-and-suspenders; kein Aufrufer kann einen S3-Upload
  korrumpieren).
- `TransferQueueViewModel` liest `supportsAppendResume` des Ziels, um das
  „Fortsetzen"-Angebot bei einem S3-Ziel gar nicht erst anzubieten
  (UI-Konsistenz; die Engine-Sperre ist der eigentliche Schutz).

## Fehlerbehandlung

- HTTP-Mapping konsistent mit M12: 403 → `.authenticationFailed`,
  404 → `.notFound(path:)`, Netzwerk/Transport → `.connectionFailed(reason:)`,
  sonstige non-2xx → `.protocolError(reason: "… HTTP {code}")`.
- Multipart-Abort räumt bei jedem Fehler auf (§2).
- `Task.checkCancellation()` pro Chunk (Upload-Teil, Download bereits über den
  Engine-Stream) und pro DeleteObjects-Batch.
- **Secret-Hygiene**: `secretAccessKey`/`sessionToken` fließen nur in den
  Signer; nie geloggt/interpoliert. Keine Body-Inhalte in Logs.

## Tests

- **Core-Unit gegen `FakeS3Transport`** (kein Netz), je Operation:
  - Upload einzelner-`PUT`-Pfad (kleiner Stream → ein PUT, korrekter
    `payloadHash`, Key/Body stimmen).
  - Upload Multipart-Pfad (Stream > Schwelle → Initiate/≥2× UploadPart/Complete;
    Teilnummern + gesammelte ETags korrekt; Part-Reihenfolge im Complete-XML).
  - Multipart-**Abort** bei Teil-Fehler (Fehler injiziert → Abort-Request geht
    raus, Fehler wird propagiert).
  - Download Range-GET (Offset-Header korrekt; Bytes werden gechunkt geliefert;
    Offset ≥ EOF → leerer Stream).
  - `createDirectory` (Marker-Key endet auf `/`, 0-Byte).
  - `delete` (DELETE-Key; 404 → notFound).
  - `rename` Datei (copy-source-Header + delete), Ordner (re-key aller Keys).
  - `deleteTree` (rekursives Listen ohne Delimiter → DeleteObjects-Batch,
    inkl. Marker; >1000 → mehrere Batches).
  - **Resume-Sperre**: `TransferEngine.copyFile(resume: true)` mit einem
    S3-Ziel-Fake, dessen `supportsAppendResume == false`, schreibt immer
    `.overwrite` ab Offset 0 (nie `.append`) — auch wenn am Ziel ein kleineres
    Objekt „liegt".
- **Gated MinIO-Integration** (`MACSCP_ITEST=1`, echtes Rig aus dem
  Haupt-Checkout): Upload→Download-Roundtrip (Inhalt bit-gleich), Datei > 8 MiB
  (echter Multipart-Pfad), Ordner anlegen + wieder sehen, Datei umbenennen,
  Ordner umbenennen, Baum löschen. Seed-Bucket bleibt reproduzierbar; der Test
  räumt seine eigenen Keys auf.

## Dateien

- Neu: `Sources/macSCPCore/S3/S3Uploader.swift` (Hybrid-PUT/Multipart-Logik).
- Ändern: `Sources/macSCPCore/S3/S3FileSystem.swift` (readStream/write/delete/
  createDirectory/rename/deleteTree real; `buildSignedRequest`-Helfer;
  `supportsAppendResume = false`).
- Ändern: `Sources/macSCPCore/S3/S3HTTPTransport.swift` (`sendStreaming` +
  Impl).
- Ändern: `Sources/macSCPCore/RemoteFS/RemoteFileSystem.swift`
  (`supportsAppendResume`-Requirement + Default-Extension).
- Ändern: `Sources/macSCPCore/RemoteFS/TransferEngine.swift` (Resume-Guard).
- Ändern: `Sources/macSCPCore/Presentation/TransferQueueViewModel.swift`
  (Resume-Angebot gated auf `supportsAppendResume`).
- Ggf. neu: `Sources/macSCPCore/S3/S3MultipartXML.swift` (Parser für
  `InitiateMultipartUpload`/Builder für `CompleteMultipartUpload`/
  `Delete`-XML) — oder inline in `S3Uploader`/`S3FileSystem`, je nach Größe
  (der Plan entscheidet die Aufteilung).
- Tests: `Tests/macSCPCoreTests/S3UploaderTests.swift`,
  Erweiterungen in `S3FileSystemTests.swift`, neue Fälle in
  `TransferEngineTests.swift` (Resume-Sperre),
  `S3FileSystemIntegrationTests.swift` (gated MinIO CRUD/Transfer).

## Global Constraints

- Swift 6, alle Targets `.swiftLanguageMode(.v5)`, min. macOS 15.
- Code/Kommentare **Englisch**; keine neuen UI-Strings erwartet (Fehler-/
  Aktions-Texte sind backend-agnostisch vorhanden). Falls doch ein neuer
  nutzer-sichtbarer String nötig wird, in alle vier Kataloge EN/DE/FR/PL
  (typografische Anführungszeichen, kein ASCII-`"` in Nicht-EN).
- **Keine neue Dependency** (Foundation + swift-crypto via `SigV4Signer`).
- **Secret nur im Signer**, nie in Logs/JSON; keine Klartext-Bodys in Logs.
- **Kein atomares Rename, kein echtes Resume** — dokumentierte S3-Grenzen.
- Multipart wird bei jedem Fehlerpfad abgebrochen (kein verwaister Upload).
- TDD red→green; neue Logik mit Tests; gated MinIO aus dem Haupt-Checkout,
  Seed reproduzierbar.
- **Kein Release.** Cross-Backend/Presigned = M14.
