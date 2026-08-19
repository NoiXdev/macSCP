# M31 — Ad-hoc-Verbindungen protokollieren (Design)

Stand 2026-08-19. Aus dem M27-Backlog, nie beauftragt.

## Der Befund, gemessen

Der gesamte Speicher-und-Protokoll-Block im Submit-Pfad hängt an einer
Bedingung: `if form.shouldSaveSession { … }` (`ContentView`). Steht der
Speichern-Schalter aus, entsteht keine `StoredSession`, damit kein
`AuditRecorder` — und damit **kein einziger Eintrag**: kein `connected`,
keine Transfers, kein `disconnected`.

Der vierte fehlende Eintrag ist der ernste: `attachAuditRecorder` schreibt
auch die **M21-Klartext-Notiz** (`plaintextConfirmed`, „connected without TLS
after an explicit confirmation"). Sie fehlt ausgerechnet dann, wenn die
Verbindung nicht gespeichert wird. Nachgemessen im Quelltext, nicht aus dem
Kommentar übernommen.

**Der eigentliche Defekt ist die Verschachtelung.** Protokollieren steckt
innerhalb von Speichern. Das Log hängt damit nicht daran, ob eine Verbindung
stattfindet, sondern daran, ob sie gespeichert wird.

## Die Entscheidung

Maintainer-Entscheidung 2026-08-19: Ad-hoc-Verbindungen protokollieren unter
**einer festen Pseudo-Sitzung**, lesbar im bestehenden Audit-Sheet,
aufbewahrt wie jedes andere Log.

Verworfen wurden: je Verbindung eine eigene ID (bräuchte eine Liste, über die
man diese Logs überhaupt findet — sonst schreiben ohne lesen, genau die
Lücke, die M27 benannt hat), nur die Klartext-Notiz, und den Punkt als
Nicht-Befund zu schließen.

## Der Entwurf

**Un-Verschachteln.** Das Anhängen des Recorders wandert aus dem
Speicher-Zweig heraus: mit `stored.id`, wenn gespeichert wurde, sonst mit der
Ad-hoc-ID. Die Klartext-Notiz kommt damit von selbst mit, weil sie in
`attachAuditRecorder` sitzt.

**Die Pseudo-Sitzung.** Eine Konstante in Core mit fester UUID, damit jede
ungespeicherte Verbindung in *dasselbe* Log schreibt. Sie ist ein Wert, kein
Datensatz: kein Eintrag in `sessions.json`, keine Sidebar-Zeile, nichts, das
sich verbinden, umbenennen, löschen oder exportieren lässt.

**Lesbarkeit.** Ein Eintrag im Sessions-Menü öffnet das bestehende
`AuditLogSheet` mit einer synthetischen `StoredSession` aus dieser ID und
einem lokalisierten Namen. Das Menü führt bereits Known Hosts,
Serverzertifikate, Logins und SSH-Schlüssel — nachgesehen, das Muster für
app-weite Sheets existiert und wird nur fortgesetzt. Das Sheet selbst ändert
sich nicht.

**Unterscheidbarkeit.** Alle Ad-hoc-Verbindungen teilen ein Log. Das trägt,
weil `recordConnected(summary:)` Host und Nutzer schon heute in den
Detailtext schreibt; die Zeilen bleiben ohne neue Maschinerie
auseinanderzuhalten.

**Aufbewahrung** wie bei jeder anderen Sitzung. Der Löschknopf des Sheets
samt Bestätigung gilt unverändert.

## Testbarkeit

Das Anhängen liegt in `ContentView`, also im ungetesteten Teil der
App-Schicht. Nach dem M29-Muster wandert deshalb nicht der Aufruf, sondern
die **Entscheidung** heraus in einen kleinen, getesteten Typ: „unter welcher
Sitzungs-ID protokolliert dieser Connect?" — gespeicherte Sitzung → ihre ID,
sonst die Ad-hoc-ID.

Beide Richtungen bekommen einen Test. Die **Konstant-Rückgabe-Probe** ist
damit erfüllt: eine Funktion, die immer die Ad-hoc-ID liefert, macht den
ersten Test rot; eine, die immer die Sitzungs-ID liefert, den zweiten. Dazu
ein Test, dass die Ad-hoc-ID über Aufrufe hinweg **stabil** ist — sonst
zerfiele das eine Log in viele unerreichbare.

## Was nicht dazugehört

- Keine globale Audit-Ansicht. Die bleibt bewusst aus (M27), und dieser
  Entwurf braucht sie nicht: er nutzt die vorhandene Sitzungs-Ansicht.
- Keine Änderung an `AuditLogSheet`, `AuditRecorder` oder `AuditLogStore`.
- Keine Einstellung zum Abschalten. Eine Option, die das Protokollieren
  ausschaltet, wäre selbst eine sicherheitsrelevante Entscheidung und
  gehörte, wenn überhaupt, in eine eigene Runde.
