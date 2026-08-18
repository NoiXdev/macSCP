# P3c: Terminal aus dem Host-Kontextmenü — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Das Kontextmenü einer gespeicherten Sitzung bekommt „Terminal
öffnen" (in macSCP, ohne Dateibrowser) und „In externem Terminal öffnen" —
beide nur, wenn die Sitzung eine Shell hat.

**Architecture:** Die Konfigurations-Auflösung, die `connect()` heute intern
macht, wird zu einer eigenen Funktion, die **beide** Wege benutzen — der
Verbindungsaufbau und der externe Start. Kein zweiter Auflösungspfad.

**Tech Stack:** Swift 6, `.swiftLanguageMode(.v5)`, SwiftPM, macOS 15+,
SwiftUI, Swift Testing, zwei Testtargets.

Spec: `docs/superpowers/specs/2026-08-18-p3-ordnung-design.md`, Abschnitt P3c.

## Global Constraints

- **Code, Kommentare, Testnamen: Englisch.** Interne Doku (`docs/`) Deutsch.
- **Jeder neue L10n-Schlüssel in allen vier Katalogen** (en/de/fr/pl),
  identische Schlüsselmengen, `plutil -lint` sauber.
- **Nie eine Zeilennummer in einen Kommentar.**
- **Kein Secret in Log, Fehler oder Testfehlermeldung.** Diese Phase fasst
  Anmeldedaten an — siehe die eigene Warnung unten.
- **Jede Tatsachenbehauptung dieses Plans ist am Code zu prüfen, bevor sie
  benutzt wird.** Im letzten Meilenstein enthielten **zwölf** meiner
  Aufgabenbeschreibungen einen sachlichen Fehler über den Code. Die unten
  zitierten Signaturen sind am 2026-08-18 gemessen; weicht etwas ab, ist
  **der Plan** falsch — melden, nicht anpassen.
- **Zwei Proben vor jedem Commit**, beide:
  1. Bliebe ein Test grün, wenn die Funktion konstant zurückgäbe?
  2. **Welche Behauptung meines Doc-Kommentars beobachtet kein Test?**
     Im letzten Meilenstein waren **fünf** Doc-Kommentare schlicht falsch.
     Prüfe jeden Satz am Code, bevor du ihn schreibst.
- **Die GUI wird nicht gestartet.** `scripts/package-app` erlaubt,
  `scripts/release` nicht.
- Conventional Commits, Englisch, Footer:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- Volle Suite grün vor jedem Commit. Ausgangsstand: **2060 Tests in 176
  Suiten** — selbst nachmessen.

## Gemessener Ist-Zustand (2026-08-18)

- `ConnectionViewModel.connect()` macht vier Dinge nacheinander: Formular
  prüfen (Schema + Jump), `descriptor.makeConfig(values, resolvedSecret)`,
  `attachingJump(to:)`, dann wählen. Bei Erfolg merkt es sich
  `lastConnectedConfig` — **nur** für den SSH-Fall.
- `ContentView.requestExternalTerminal(for tab:)` verlangt heute
  `tab.isConnected` **und** `tab.connectionViewModel.lastConnectedConfig`.
  Ein externes Terminal ist damit nur aus einem **bereits verbundenen** Tab
  erreichbar.
- `ExternalTerminalLauncher.open(config:target:customPath:root:)` braucht
  eine fertige `SSHConnectionConfig`.
- `disconnect` setzt `lastConnectedConfig` auf `nil` — bewusst, damit kein
  Klartext-Passwort über die Trennung hinaus liegen bleibt. **Diese
  Eigenschaft darf diese Phase nicht aufweichen.**
- Das Zeilen-Kontextmenü der Sidebar enthält heute „Connect" und „Edit…"
  (`sidebar.connect`, `sidebar.edit`) und ruft `onSelect()` / `onEdit()`.
- `BackendDescriptor.descriptor(for:).capabilities.supportsShell` ist für
  S3 und WebDAV `false`.
- `SessionTab.showsFiles` und `PaneVisibility` (aus P2) bestimmen, welche
  Fensterhälften eine Sitzung zeigt; `StoredSession.paneVisibility` hält das
  gespeichert, Standard `.filesOnly`.

---

### Task 1: Eine Auflösung, zwei Aufrufer (Core)

**Warum:** Ein externes Terminal braucht genau die ersten drei Schritte von
`connect()` und darf den vierten nicht tun. Diese drei Schritte ein zweites
Mal hinzuschreiben ist der Fehler, für den dieses Projekt in den letzten
Phasen mehrfach bezahlt hat.

**Files:**
- Modify: `Sources/macSCPCore/Presentation/ConnectionViewModel.swift`
- Create/Modify: die zugehörigen Tests

**Interfaces:**
- Produces (Namen sind ein Vorschlag — wähle bessere, wenn du welche
  siehst, und schreib die gewählten in den Bericht):

```swift
/// The config `connect()` would dial, resolved without dialing anything.
/// Returns nil and sets `state` exactly as `connect()` would when the form
/// or the jump does not validate.
public func resolvedConfigWithoutDialing() -> ConnectionConfig?
```

- [ ] **Schritt 1: Erst lesen, dann schneiden**

Lies `connect()` ganz. Bestimme, welcher Teil **reine Auflösung** ist und wo
der Verbindungsaufbau anfängt. Der Schnitt liegt vor `state = .connecting`.

Prüfe dabei, ob `state` beim Scheitern in beiden Wegen dasselbe bedeuten
soll. Ein externer Start, der das Formular in den Fehlerzustand versetzt,
kann richtig sein — oder störend, weil das Formular gar nicht sichtbar ist.
**Entscheide bewusst und begründe im Bericht.**

- [ ] **Schritt 2: Der Äquivalenz-Wächter zuerst**

Ein Test, der beweist, dass `connect()` und die neue Funktion **dieselbe**
Konfiguration erzeugen — für einen einfachen SSH-Fall, einen mit Jump, und
einen, bei dem die Auflösung scheitert. Er ist der Grund für diese Task; er
muss rot werden, wenn jemand später einen der beiden Wege ändert.

- [ ] **Schritt 3: `connect()` ruft auf statt zu wiederholen**

`connect()` benutzt die neue Funktion und behält sein Verhalten exakt. Die
volle Suite ist hier der Regressionsnachweis: `connect()` ist in diesem
Projekt vielfach getestet.

- [ ] **Schritt 4: Volle Suite + Commit**

```bash
swift test
git commit -m "refactor(core): resolve a connection config without dialing it"
```

---

### Task 2: Die zwei Einträge (App)

**Files:**
- Modify: `Sources/MacSCPAppKit/SessionSidebar.swift`
- Modify: `Sources/MacSCPAppKit/ContentView.swift` und/oder die passende
  Erweiterungsdatei
- Modify: die vier `Localizable.strings`
- Create: `Tests/macSCPAppKitTests/…` (siehe Schritt 4)

**Interfaces:**
- Consumes: `resolvedConfigWithoutDialing()` aus Task 1

- [ ] **Schritt 1: Die Sichtbarkeitsregel — als testbarer Typ, nicht als `if`**

Ob die beiden Einträge erscheinen, hängt an
`BackendDescriptor.descriptor(for: session.kind).capabilities.supportsShell`.
**Ausgeblendet, nicht ausgegraut** — ein dauerhaft toter Eintrag an einem
S3-Bucket erklärt nichts.

Diese Entscheidung gehört als kleine, testbare Funktion nach Core oder in
eine testbare App-Datei, **nicht** als Bedingung in den View-Body. In P2 hat
genau diese Form ein leeres Fenster erzeugt, und in P3a hat sie leere
Gruppen verschwinden lassen.

Neue Schlüssel (alle vier Kataloge):
- `sidebar.openTerminal` — „Open Terminal"
- `sidebar.openExternalTerminal` — „Open in External Terminal"

- [ ] **Schritt 2: „Terminal öffnen"**

Verbindet wie „Verbinden", aber die Sitzung kommt **ohne Dateibrowser**
hoch. Die Mechanik dafür steht seit P2.

**Beide Fragen, die die Spec offen gelassen hat, beantwortest du hier — und
zwar so:** dieser Eintrag verhält sich in allem, was nicht die
Fenster­aufteilung betrifft, **exakt wie „Verbinden"**. Neuer Tab oder
aktiver Tab, bereits verbundene Sitzung, Fehlerfall: was „Verbinden" heute
tut, tut dieser Eintrag auch. **Miss nach, was das ist**, und schreib es in
den Bericht — nicht, weil ich es nicht entscheiden will, sondern weil zwei
Einträge, die sich unterschiedlich verhalten, ohne Grund verwirren.

- [ ] **Schritt 3: „In externem Terminal öffnen"**

Löst die Konfiguration über Task 1 auf und übergibt sie an
`ExternalTerminalLauncher`. **macSCP verbindet sich dabei nicht.**

**Drei Dinge, die hier zwingend sind:**

1. **Der vorhandene Passworthinweis gilt auch hier.**
   `requestExternalTerminal` zeigt ihn einmalig, wenn die Auth ein Passwort
   ist — weil das Passwort in ein Skript geschrieben wird. Dieser Weg darf
   ihn nicht umgehen. Prüfe am Code, wie er ausgelöst wird, und häng dich
   ein, statt einen zweiten zu bauen.
2. **Kein Secret bleibt liegen.** `disconnect` setzt `lastConnectedConfig`
   bewusst auf `nil`, damit kein Klartext-Passwort über die Trennung hinaus
   existiert. Dein Weg darf **keine** neue Stelle schaffen, an der eine
   aufgelöste Konfiguration länger lebt als der Aufruf. Halte sie lokal.
3. **Fehler werden gezeigt.** Scheitert die Auflösung (fehlendes Secret,
   kaputter Jump) oder der Start, bekommt der Nutzer dieselbe Art Meldung
   wie auf dem vorhandenen Weg — kein stiller Fehlschlag.

- [ ] **Schritt 4: Was prüfbar ist, prüfen**

Die Sichtbarkeitsregel aus Schritt 1 ist eine reine Funktion und bekommt
echte Tests. Die Verdrahtung der Menüeinträge ist ohne Rendering-Werkzeug
nicht beobachtbar — **sag das im Bericht klar**, statt Abdeckung zu
suggerieren. Das Projekt hat sieben Quelltext-Wächter und eine Review hat
das Muster als über seiner nützlichen Größe bezeichnet: einen achten nur mit
Begründung.

- [ ] **Schritt 5: Katalog-Nachweis + volle Suite + Commit**

```bash
for f in $(git ls-files '*.strings'); do plutil -lint "$f"; done
swift test
git commit -m "feat(app): open a terminal straight from a host's context menu"
```

---

### Task 3: Phasenabschluss

**Files:**
- Create: `docs/superpowers/specs/2026-08-18-p3c-abschluss.md`

- [ ] **Schritt 1: Messen**

```bash
swift test 2>&1 | tail -3
for f in $(git ls-files '*.strings'); do plutil -lint "$f"; done
MACSCP_VERSION="1.2.0-dev" MACSCP_BUILD="$(git rev-list --count HEAD)" ./scripts/package-app
```

Den Build **im Hintergrund** starten; danach beide Binaries (`lipo -archs`),
beide Ressourcen-Bundles, alle vier `.lproj`, `plutil -lint` auf die
Info.plist prüfen. **Die App wird nicht gestartet.**

- [ ] **Schritt 2: Bericht**

Er nennt die gemessenen Zahlen; wie die Auflösung geteilt wurde und was der
Äquivalenz-Wächter hält; was „Verbinden" tut und womit sich „Terminal
öffnen" deshalb deckt; dass keine aufgelöste Konfiguration länger lebt als
der Aufruf; und **ausdrücklich**, dass die GUI nicht gestartet wurde — mit
der Liste für den Maintainer: beide Einträge an einer SSH-Sitzung, **keiner**
an einer S3- oder WebDAV-Sitzung, das eingebaute Terminal ohne
Dateibrowser, der externe Start samt Passworthinweis beim ersten Mal.

- [ ] **Schritt 3: Commit**

```bash
git commit -m "docs(app): record the terminal context menu phase"
```

---

## Selbstreview dieses Plans

**Spec-Abdeckung:** Zwei getrennte Einträge → Task 2. Nur bei vorhandener
Shell, ausgeblendet statt ausgegraut → Task 2, Schritt 1. Eingebaut =
ohne Dateibrowser → Task 2, Schritt 2. Extern = keine eigene Verbindung →
Task 2, Schritt 3. Die zwei offenen Fragen der Spec (neuer Tab? bereits
verbunden?) → beantwortet durch die Regel „verhält sich wie Verbinden",
gemessen statt geraten.

**Platzhalter:** keine. Task 1 nennt bewusst keinen fertigen Rumpf, weil der
Schnitt am gelesenen `connect()` zu bestimmen ist — das ist eine
Arbeitsanweisung, kein offener Punkt.

**Typkonsistenz:** `resolvedConfigWithoutDialing()` in den Tasks 1 und 2
gleich geschrieben; der Name darf sich ändern, dann aber an beiden Stellen.
