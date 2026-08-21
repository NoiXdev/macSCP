# Verbindungszustand: Erkennung, Anzeige, Erholung

**Stand:** Entwurf, vom Maintainer abgenommen 2026-08-21.

Fasst drei Backlog-Einträge zusammen, weil sie **ein** Zustandsmodell teilen:
A1 (Fehleransicht im Tab mit „Erneut verbinden", Zustandssymbol am Reiter)
und A2 (Keep-alive) aus `2026-08-20-backlog-sitzungen-tabs-seitenleiste.md`,
sowie B-1 (Einfrieren beim toten Host) aus `2026-08-20-bugs.md`.

Getrennt gebaut entstünden drei Wege, die dasselbe sagen wollen: „verbindet",
„verbunden", „verloren".

## Was bereits gemessen wurde

Am Quelltext geprüft, nicht angenommen:

- **Weder Citadel noch NIOSSH kennt Keep-alive.** NIOSSHs einzige öffentliche
  Sende-API für globale Requests ist `sendTCPForwardingRequest`; ein eigenes
  `keepalive@openssh.com` ist darüber nicht zu schicken.
- **Citadels `session` ist `internal`.** Weder der Kanal noch der
  `NIOSSHHandler` sind von außen erreichbar. Ein Keep-alive auf SSH-Ebene
  scheidet damit aus.
- **`SSHClient.isConnected`** (liest `channel.isActive`) und
  **`onDisconnect(perform:)`** sind öffentlich und für die Erkennung nutzbar.
- **`SSHClient.connect(host:port:…)` hat einen Parameter
  `connectTimeout: TimeAmount = .seconds(30)`**, den `CitadelFileSystem` an
  **beiden** Aufrufstellen — Sprung-Hop und Ziel — nicht übergibt. B-1s lange
  Wartezeit ist damit eine nicht gesetzte Vorgabe, keine Umstrukturierung.
- **`RemoteFileSystem.stat(path:)`** ist der billigste Rundlauf im Protokoll
  und damit die Sonde.

## 1. Zustandsmodell

Ein Wert je Sitzung, in Core:

| Zustand | Punkt | Bedeutung |
|---|---|---|
| `connecting` | gelb | Aufbau läuft, abbrechbar |
| `connected` | grün | letzter Beweis war erfolgreich |
| `degraded` | gelb | eine Sonde ist fehlgeschlagen, ein zweiter Versuch läuft |
| `lost` | rot | aufgegeben, Sitzung abgebaut |

Der Zustand gehört zur Sitzung im **Fensterbereich**, nie zu einem
app-weiten Singleton — bestehende Architektur-Invariante.

`degraded` ist kein Schmuck: ohne ihn müsste eine einzelne verlorene Sonde
sofort zu Rot führen, und ein einzelner Paketverlust sähe aus wie ein
Abriss.

## 2. Erkennung

Ein Zeitgeber je Sitzung, Intervall aus den Einstellungen.

Beim Ticken:

1. **Hat die Warteschlange Arbeit, wird übersprungen.** Laufender Verkehr
   beweist die Verbindung besser als jede Sonde, und eine zusätzliche
   Anfrage während einer Übertragung ist reine Störung.
2. Sonst `stat` auf den **beim Verbinden ermittelten Heimatpfad**
   (`homeDirectoryPath()` läuft ohnehin beim Aufbau) — kein zusätzlicher
   Rundlauf, um erst den Pfad zu finden.
3. Erfolg → `connected`.
4. Fehlschlag oder eigene Frist abgelaufen → `degraded`, **ein** sofortiger
   zweiter Versuch. Auch der scheitert → `lost`.

Die Entscheidungslogik (überspringen / senden / erneut / aufgeben) ist reine
Funktion über (Warteschlange beschäftigt, letztes Ergebnis, Fehlversuche)
und gehört als eigener Typ getestet, getrennt vom Zeitgeber.

## 3. Erholung

`lost` zeigt im Tab die Fehleransicht: was passiert ist, und **„Erneut
verbinden"**.

Der Wiederaufbau läuft durch **denselben** Verbindungspfad wie ein frischer
Aufbau. Das ist die tragende Entscheidung dieses Abschnitts: TOFU bleibt ein
harter Stopp, die Keychain-Regeln bleiben unverändert, und es entsteht kein
zweiter Pfad, an dem eine Sicherheitsregel vergessen werden könnte.

Einstellbares Verhalten:

- **`offerOnly` (Standard)** — nichts geschieht ohne Klick.
- **`onceThenAsk`** — ein automatischer Versuch, danach die Fehleransicht.
- **`automatic`** — wiederholte Versuche, erster nach 5 s, danach jeweils
  doppelter Abstand bis höchstens 60 s, ohne Aufgabegrenze. Jederzeit
  abbrechbar; ein Abbruch führt in die Fehleransicht.

Auch bei `automatic` gilt: ein Versuch, der auf TOFU oder eine Passphrase
läuft, endet in der Fehleransicht und wird nicht im Hintergrund wiederholt.

## 4. Verbindungsaufbau (B-1)

Der Aufbau wird eine **abbrechbare Aufgabe** und benutzt dieselbe Tab-Fläche:
„Verbinde …" mit Abbrechen, während der Rest der App bedienbar bleibt.

Dazu wird `connectTimeout` an beiden Aufrufstellen übergeben, mit einem
kürzeren Standard als den geerbten 30 Sekunden.

**Bewusst ohne Vorbedingung:** ob der Hauptthread heute wirklich blockiert
oder ob nur eine tote Modal-Fläche danach aussieht, ist **nicht gemessen**
(die App wird in dieser Arbeitsweise nicht gestartet). Die gewählte Form
behebt beide Fälle, deshalb muss die Frage vorher nicht beantwortet sein.
Fällt bei der Umsetzung auf, dass tatsächlich blockiert wird, ist das ein
eigener Befund und gehört gemeldet.

Am Rande angesehen, nicht Teil dieses Umfangs: `AgentBackedPrivateKey`
wartet mit `semaphore.wait(timeout:)` blockierend in einem sonst
asynchronen Pfad.

## 5. Übertragungen

Bei `lost`:

- Die **laufende** Übertragung scheitert mit dem Grund „Verbindung verloren".
- Die **wartenden** bleiben in der Liste und werden gekennzeichnet — nichts
  wird stillschweigend verworfen.
- **Kein automatisches Fortsetzen.** Eine halb geschriebene Datei auf der
  Gegenseite ist ein Konfliktfall, der die bestehenden Konfliktregeln
  braucht, keine stille Entscheidung.

Der Abbau geht durch die bestehende Reihenfolge — `cancelAll` → Terminal
`shutdown` → `disconnect` —, nicht an ihr vorbei. Die Invarianten der
Warteschlange (FIFO, genau-einmal-Fortsetzungen, keine verwaisten Shells)
gelten unverändert.

## 6. Einstellungen

Drei Werte im `SettingsStore`:

| Wert | Standard | Anmerkung |
|---|---|---|
| Wiederverbinden-Verhalten | `offerOnly` | die drei Fälle aus Abschnitt 3 |
| Intervall der Lebenszeichen | 60 s | 0 schaltet die Sonde ab |
| Frist für den Verbindungsaufbau | 10 s | NIOs eigener Vorgabewert; Citadel überschreibt ihn auf 30. Gilt für **jeden** Hop einzeln, also auch für den Sprung-Host |

Die Frist der **Sonde** ist bewusst **keine** Einstellung: sie muss kürzer
als das Intervall sein, sonst überholen sich Sonden. Sie wird aus dem
Intervall abgeleitet — die halbe Intervalldauer, nach oben auf 10 s
begrenzt —, und diese Ableitung gehört getestet. Bei Intervall 0 findet
keine Sonde statt, die Frist ist dann gegenstandslos.

## 7. Lokalisierung

Alle neuen Zeichenketten in `en`, `de`, `fr` und `pl`; ein Wächtertest
erzwingt gleiche Schlüsselmengen. Betroffen: die Fehleransicht, der
Abbrechen-Knopf, die drei Einstellungen samt Erläuterung, der Grund
„Verbindung verloren" an der Übertragung, und die Kurzhilfen der drei
Punktfarben.

## 8. Prüfbarkeit

- **Unit:** Zustandsautomat, Sondenregel, Ableitung der Sondenfrist,
  Rückfallabstände bei `automatic`. Reine Logik, normale Tests.
- **Docker-Rig (`MACSCP_ITEST=1`):** ein echter Abriss lässt sich erzeugen
  (Container anhalten) und `lost` nachweisen; ebenso, dass die Sonde bei
  lebender Gegenseite erfolgreich ist und dass sie bei beschäftigter
  Warteschlange ausbleibt.
- **Sichtprüfung beim Maintainer:** der Punkt am Reiter in allen drei Farben,
  die Fehleransicht, der Abbrechen-Knopf während des Aufbaus. Kein Test
  dieses Projekts zeichnet SwiftUI.

## 9. Ausdrücklich nicht dazu

- **Kein Keep-alive auf Socket-Ebene** (`SO_KEEPALIVE`). Es wurde erwogen:
  kein Log-Rauschen, aber macOS lässt so einen Socket standardmäßig zwei
  Stunden leer laufen, das Feinjustieren geht nur über rohe Socket-Optionen,
  ein lebendiger TCP-Socket beweist nichts über SSH oder SFTP darüber — und
  er wäre faktisch ungetestet.
- **Kein Fortsetzen abgebrochener Übertragungen.**
- **Keine Änderung an TOFU, Keychain oder dem Verbindungspfad selbst.**

## 10. Textfrage für die Umsetzung

Ob die Fehleransicht den technischen Grund zeigt oder nur eine
verständliche Zusammenfassung, entscheidet sich beim Schreiben der Texte.
Fest steht die Auflage: sie darf **kein** Geheimnis und keinen vom Nutzer
getippten Wert enthalten — dieselbe Regel, die für Protokolle, Exporte und
Fehlermeldungen im ganzen Projekt gilt.
