# M21 — WebDAV als drittes Backend

**Stand:** 2026-08-04
**Vorgänger:** M12 (Fähigkeits-Framework), M13 (S3-Backend), M16 (Cross-Backend-Transfer)

## Zweck

WebDAV als drittes Backend neben SSH/SFTP und S3 — und damit der erste echte
Test der Behauptung aus M12, weitere Protokolle seien „bloße
Zusatzimplementierungen". WebDAV eignet sich dafür besser als jedes andere:
es ist HTTP-basiert wie S3, hat aber **echte Verzeichnisse** und **atomares
Rename**, also genau die zwei Fähigkeits-Achsen, die bei S3 auf `false`
stehen. Wenn die generischen Schichten das ohne eine einzige
`if kind ==`-Abfrage mittragen, sind die Achsen wirklich unabhängig.

## Zielserver

Vier Familien, in zwei Gruppen:

**Automatisiert prüfbar**
- Generisches WebDAV nach RFC 4918 (Apache `mod_dav`, nginx-dav, Caddy)
- Nextcloud / ownCloud

**Nur manuell prüfbar** (keine Container-Abbilder, Prüfung gegen echte Geräte)
- Synology, QNAP und andere NAS
- Hetzner Storage Box

Die Implementierung zielt auf den RFC-Kern; Nextcloud bekommt genau eine
Anpassung (Pfad-Präfix, siehe Formular). NAS und Hetzner brauchen keine
eigenen Zugeständnisse, wohl aber die Zertifikatsbehandlung.

## Architektur

### Geteilte HTTP-Naht

`S3HTTPTransport` wird zu `HTTPTransport` verallgemeinert,
`URLSessionS3Transport` zu `URLSessionHTTPTransport`; beide ziehen aus
`Sources/macSCPCore/S3/` in einen neutralen Ort um. Die Oberfläche bleibt
unverändert (`send`, `sendStreaming`) — es ist Umbenennung plus Umzug. Die
vorhandenen S3-Tests hängen an dieser Naht und sind das Sicherheitsnetz.

Eine Erweiterung: der Transport nimmt eine mitgegebene `URLSession` entgegen
statt `.shared`. WebDAV braucht eine Session **mit Delegat** — das ist die
Stelle, an der macOS sowohl die Authentifizierungs-Herausforderung als auch
die Server-Vertrauensprüfung anbietet.

**Warum nicht kopieren:** Zwei fast gleiche Transporte im Baum wären beim
nächsten Protokoll drei. Wörtliche Verdopplung eines Logikblocks gilt in
diesem Projekt als Wartungsschaden.

**Warum Digest nicht von Hand:** URLSession beantwortet Basic *und* Digest
über denselben Delegat-Rückruf, inklusive Nonce-Zähler, `qop` und
`stale`-Erneuerung. Falls sich das im Rig als sperrig erweist, ist der
dokumentierte Rückfallweg eine eigene Digest-Berechnung, prüfbar gegen die
Vektoren aus RFC 7616.

### Neue Bausteine (`Sources/macSCPCore/WebDAV/`)

| Datei | Aufgabe |
|---|---|
| `WebDAVConnectionConfig` | Basis-URL, Benutzername, Auth-Art |
| `WebDAVURL` | Pfad-Arithmetik: relative Browser-Pfade → absolute URLs, Prozent-Kodierung, Verzeichnis-Schrägstrich, Nextcloud-Vorlage |
| `WebDAVPropfindParser` | `multistatus`-XML → `[RemoteFileItem]` über `XMLParser` |
| `WebDAVSessionDelegate` | Auth-Herausforderung (Basic/Digest) und Server-Vertrauen |
| `ServerCertificateValidation` | TOFU-Entscheidungslogik, rein und netzfrei |
| `WebDAVFileSystem` | die `RemoteFileSystem`-Implementierung |

`WebDAVURL` ist bewusst eine eigene Datei: dort wohnen die stillen Fehler
(Leerzeichen, Umlaute, `+`, doppelte Schrägstriche, die Wurzel), und sie sind
rein rechnerisch prüfbar.

Der Parser ist **nachsichtig gegenüber fremden Namensräumen**, damit
Nextclouds Zusatz-Properties nichts brechen.

### Vertrauensspeicher

`TrustedCertificateStore` bei den Sessions spiegelt `KnownHostsStore` eins zu
eins: dieselbe JSON-Ablage, dieselben vier Operationen
(`find`/`upsert`/`allKeys`/`remove`), geschlüsselt auf Host und Port. Damit
erbt er das Verwaltungsmuster aus M10a samt der Suche aus M18.

### Angefasste Registrierungsstellen

`ConnectionKind`, `ConnectionConfig`, `BackendConnector`,
`BackendDescriptor`, `StoredSessionConnectionConfig`, `ConnectionViewModel`,
`LoginSetsSheet`, `CLISecretSources`. Das ist die Naht, die M12 angelegt
hat; ob sie vollständig ist, zeigt dieser Meilenstein.

## Verbindungsmodell

### Formular

Über das vorhandene `ConnectionFieldSchema` — keine neue UI-Mechanik.

| Feld | Art |
|---|---|
| Server-URL | Text |
| Benutzername | Text |
| Passwort | Geheimnis (Keychain, nie im JSON) |
| Nextcloud-Pfad anhängen | Umschalter |

Vorlagen: **Nextcloud / ownCloud** setzt den Umschalter, **Eigene** setzt
nichts. Der Nutzer gibt `https://cloud.example.com` ein, `WebDAVURL` hängt
`/remote.php/dav/files/<benutzer>/` an — die Eigenheit, an der Nutzer sonst
scheitern.

Für Hetzner und Synology gibt es **bewusst keine Vorlage**: dort ist die URL
benutzer- beziehungsweise gerätespezifisch, eine Vorlage könnte nichts
sinnvoll vorbelegen und würde nur Vertrauen vortäuschen.

### Klartext-HTTP

`http://` bleibt erlaubt — im Heimnetz ist es Realität. Aber Basic sendet die
Zugangsdaten dabei im Klartext.

Hier bekommt die Achse `TransportSecurity` **ihren ersten Leser**: sie ist
heute deklariert und bei beiden Backends gesetzt, wird aber nirgends
ausgewertet (nachgeprüft am Baum, Stand 2026-08-04). Neue Regel, an genau
einer Stelle:

- Basic über `http://` → ausdrückliche Bestätigung, Eintrag im Prüfprotokoll
- Digest über `http://` → keine Rückfrage; es geht kein Geheimnis über die Leitung
- alles über `https://` → keine Rückfrage

### Zertifikats-TOFU

`ServerCertificateValidation` entscheidet nach dem Muster von
`HostKeyValidation`. Drei Fälle, und nur drei:

1. **Systemkette vertraut** → durch, nichts wird gespeichert. Nextcloud und
   Hetzner sollen gar nicht erst durch TOFU laufen.
2. **Unbekannt** → Dialog mit SHA-256-Fingerprint, Aussteller und
   Gültigkeit; ohne Zustimmung keine Verbindung.
3. **Bekannt und abweichend** → **harter Stopp**. Kein Dialog, keine
   Möglichkeit zuzustimmen — dieselbe Invariante wie beim Hostkey.

Es gibt **keinen** Schalter „Zertifikat nicht prüfen". Das wäre der
`accept-anything path`, den die Projektregeln für Hostkeys ausdrücklich
verbieten.

Verwaltet wird das im bestehenden Known-Hosts-Sheet als **zweiter
Abschnitt**, nicht in einem neuen Fenster: es ist dieselbe Frage („wem
vertraue ich?").

## Protokoll-Abbildung

| Operation | WebDAV |
|---|---|
| `list` | PROPFIND, `Depth: 1` |
| `stat` | PROPFIND, `Depth: 0` |
| `readStream` | GET mit `Range` |
| `write` | PUT (strömend) |
| `delete` | DELETE |
| `createDirectory` | MKCOL |
| `rename` | MOVE mit `Destination`, `Overwrite: F` |
| `deleteTree` | DELETE auf die Sammlung |
| `homeDirectoryPath` | `/` — die Basis-URL *ist* die Wurzel |
| `setPermissions` | nicht unterstützt, wirft |

Zwei Stellen unterscheiden sich deutlich von S3:

- **`deleteTree` ist ein einziger Aufruf.** WebDAV löscht eine Sammlung
  serverseitig rekursiv; S3 braucht dafür rekursives Auflisten und
  DeleteObjects-Stapel.
- **`rename` ist echt atomar.** MOVE mit `Overwrite: F` gibt bei belegtem
  Ziel 412 zurück, statt wie bei S3 aus Kopieren-und-Löschen zusammengesetzt
  zu sein und im Fehlerfall einen halben Zustand zu hinterlassen.

### Fähigkeiten

```
supportsShell:        false
permissionModel:      .none
supportsSymlinks:     false
atomicRename:         true      ← bei S3 false
directoriesAreReal:   true      ← bei S3 false
resumeMode:           .rangeGet
supportsPresignedURL: false
transport:            .optionalTLS
```

### Fortsetzung nur beim Herunterladen

Für teilweises PUT gibt es keinen Standard; Nextclouds Chunked Upload ist
eine eigene Erweiterung und bleibt draußen. Ein abgebrochener Upload beginnt
von vorn — die Warteschlange behandelt das bereits, seit M13 die
Resume-Sperre an `supportsAppendResume` gehängt hat.

Beim Herunterladen wird `Accept-Ranges: bytes` ausgewertet. **Fehlt der
Kopf, wird vollständig neu abgerufen** statt einen Bereich anzufordern, den
der Server still ignoriert — sonst entstünde eine beschädigte Datei.

### Fehlerabbildung

Auf die vorhandenen `RemoteFSError`-Fälle:

| Status | Fall |
|---|---|
| 401 | Authentifizierung fehlgeschlagen |
| 403 | keine Berechtigung |
| 404 | nicht gefunden |
| 405 auf MKCOL | existiert bereits |
| 409 | übergeordneter Ordner fehlt |
| 412 auf MOVE | Zielkonflikt |
| 507 | kein Speicherplatz |

## Nicht in diesem Meilenstein

LOCK/UNLOCK, PROPPATCH, Kontingent-Abfrage, Nextclouds Chunked Upload und
dessen Papierkorb, OAuth2/Bearer, presigned URLs (WebDAV kennt sie nicht),
WebDAV in der CLI über das hinaus, was der Connector-Dispatcher ohnehin
mitbringt.

## Tests

### Ohne Netz

- **`WebDAVURL`** — Wurzel (die Stelle, an der M20 den `//`-Fehler hatte),
  Leerzeichen, Umlaute, `+`, `#`, doppelte Schrägstriche,
  Verzeichnis-Schrägstrich, Nextcloud-Vorlage mit Benutzernamen.
- **`WebDAVPropfindParser`** — abgelegte Antworten von Apache **und** von
  echtem Nextcloud, dazu die leere Sammlung und ein `multistatus` mit 404 für
  einzelne Einträge. Der Nextcloud-Baustein ist der Wächter gegen einen zu
  engen Parser.
- **`ServerCertificateValidation`** — die drei Fälle; der Abweichungsfall als
  eigener Test nach dem Muster von `tamperedKnownKeyFailsHardWithMismatch`.
- **Anfragenbau und Fehlerabbildung** über einen eingesetzten
  `HTTPTransport`-Doppelgänger, wie S3 es bereits macht.

### Gegatet (`MACSCP_ITEST=1`)

Neuer `webdav`-Dienst im vorhandenen compose: ein `httpd` mit `mod_dav` und
drei vhosts — Basic über Klartext, Digest über Klartext, TLS mit
selbstsigniertem Zertifikat. **Das Zertifikat wird beim Rig-Start erzeugt,
nicht eingecheckt**, genau wie die SSH-Testschlüssel.

Geprüft wird: vollständiger CRUD-Umlauf, Rename mit belegtem Ziel, rekursives
Löschen, Fortsetzung per Range-GET, beide Auth-Verfahren, und der
TOFU-Ablauf einschließlich des harten Stopps nach Zertifikatswechsel.

Dazu ein **WebDAV↔SSH-Transfer**: `CrossBackendTarget` aus M16 ist
protokollneutral gebaut — läuft es ohne Anpassung, ist das ein zweiter Beleg
fürs Framework.

### Nextcloud

Im selben compose hinter einem **eigenen Profil**, das der normale Riglauf
nicht startet. Einmal manuell gefahren liefert es die echte PROPFIND-Antwort,
aus der der Testbaustein oben entsteht.

## Erfolgskriterien

1. Eine WebDAV-Session lässt sich anlegen, verbinden, durchsuchen und in
   beide Richtungen übertragen — gegen Apache und gegen echtes Nextcloud.
2. Kein generischer Codepfad bekommt eine `if kind == .webdav`-Abfrage; alles
   Protokollabhängige liest den Descriptor.
3. Ein gewechseltes Serverzertifikat bricht die Verbindung hart ab, ohne dem
   Nutzer eine Zustimmung anzubieten.
4. Basic über Klartext-HTTP verlangt eine Bestätigung und steht im
   Prüfprotokoll.
5. Die vier Sprachkataloge bleiben vollständig und deckungsgleich.

## Offene Punkte für den Plan

- Ob `HTTPTransport` unter `RemoteFS/` oder in einem eigenen `HTTP/`-Ordner
  liegt.
- Ob der Nextcloud-Testbaustein aus dem Rig erzeugt oder von Hand aus einer
  echten Antwort abgeschrieben wird.
- Genaue Form der Bestätigung bei Basic über Klartext: eigener Dialog oder
  eine Zeile im vorhandenen Verbindungs-Fehlerweg.
