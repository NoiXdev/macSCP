# Gescheiterter Verbindungsaufbau — Umsetzungsplan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ein fehlgeschlagener Verbindungsaufbau bleibt im Tab stehen und bietet einen Weg weiter, statt kommentarlos aufs Formular zurückzufallen.

**Architecture:** Eine eigene Fläche neben der Abriss-Fläche, gespeist aus einem prüfbaren Wert; vier Handlungen, dazu ein Dialog mit der vollständigen Meldung.

**Spec:** `docs/superpowers/specs/2026-08-25-gescheiterter-aufbau-design.md`

## Global Constraints

- Code, Kommentare, Bezeichner, Testnamen, Commit-Messages: **nur Englisch**; Katalogwerte sind Übersetzungen. Alle vier Kataloge, Deutsch von Hand.
- Conventional Commits; Footer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- **„Erneut versuchen" läuft durch denselben Verbindungspfad wie ein frischer Aufbau.** TOFU bleibt ein harter Stopp. Die Erlaubnisliste in `ReconnectWiringGuardTests` muss die neue Aufrufstelle erfassen.
- **Kein Geheimnis** in Protokoll, Export, Fehlermeldung, Testfehlertext — und ab jetzt auch nicht im Details-Dialog.
- Keine Zeilennummern, keine Ortsangaben in Kommentaren; jede Zahl im selben Durchgang gezählt.
- **Kein Versuch darf an echten Keychain, Sitzungs-Store oder Konfiguration reichen.** `ContentView` nimmt eingespeiste Ablagen — benutzen.
- Wächter: **Mutationstests belegen die Empfindlichkeit, nie den Geltungsbereich.** Vor der Wahl eines Ankers fragen, *woher* die Eigenschaft verletzt werden könnte. Kommentar- und zeichenkettenfreien Quelltext scannen.
- Die App wird nicht gestartet, nichts gepusht.

---

### Task 1: Kann im Details-Text ein Geheimnis stehen?

**Files:** Test in `Tests/macSCPCoreTests/`; Korrekturen dort, wo ein Fehler entsteht — **nicht** an der Anzeige.

**Der Befund, der diese Aufgabe auslöst:** `ConnectionViewModel` erzeugt seine `state = .failed(message:field:)` fast überall aus aufbereiteten, lokalisierten Texten. **Eine** Stelle bettet einen rohen Fehler ein: `String(format: CoreL10n.string("core.error.unexpected %@"), String(describing: error))`.

Bisher war das folgenlos, weil der Text nur im Formular stand. Der Details-Dialog macht ihn prominent.

- [ ] **Step 1: Zählen, welche Fehler dort ankommen können.** Jeden Typ aufzählen, der in diesen `catch` laufen kann — eigene Fehler von macSCP, Citadel, NIOSSH, Foundation. Die Zahl in den Bericht, nicht in einen Kommentar, außer sie wird im selben Durchgang gezählt.
- [ ] **Step 2: Für jeden prüfen, ob seine Textdarstellung ein Geheimnis tragen kann** — Passwort, Passphrase, Schlüsselmaterial. macSCPs eigene Fehler sind es per Projektregel nicht; **das ist zu belegen, nicht anzunehmen.** Fremde Typen einzeln ansehen.
- [ ] **Step 3: Einen Test schreiben, der das festnagelt.** Gegen echte Fehlerwerte, nicht erfundene. Findet sich ein Typ, der ein Geheimnis tragen *kann*, wird **er** korrigiert — der Wert gehört gar nicht erst in den Fehler.
- [ ] **Step 4: Volle Suite grün.** — [ ] **Step 5: Commit** — `test(core): pin that a connect failure carries no secret`

---

### Task 2: Der prüfbare Wert

**Files:** Neben `LostConnectionPlan` in `Sources/MacSCPAppKit/ContentView+Detail.swift`; Test in `Tests/macSCPAppKitTests/`.

**Interfaces produced:** `ConnectFailurePlan.content(hasStoredSession:)` → allgemeine Meldung plus die sichtbaren Handlungen.

- [ ] **Step 1: Test zuerst.** Vier Handlungen; **„Sitzung bearbeiten" erscheint nur** bei gespeicherter Sitzung, die drei anderen immer. Die Meldung ist allgemein und trägt keine Einzelheiten — dieselbe bauliche Sicherheit wie `LostConnectionContent`: nur `(Schlüssel, Rückfalltext)`-Paare, kein Feld, in das ein Hostname passen würde.
- [ ] **Step 2: Rot laufen lassen.** — [ ] **Step 3: Umsetzen.** — [ ] **Step 4: Grün.**
- [ ] **Step 5: Commit** — `feat(app): decide what a failed connect offers`

---

### Task 3: Die Fläche, der Dialog, die Verdrahtung

**Files:** `ContentView+Detail.swift` (`ConnectionSurfacePlan` und die Fläche), alle vier Kataloge, Wächtertest.

**Interfaces consumed:** Task 1 (Sicherheit belegt), Task 2 (`ConnectFailurePlan`).

- [ ] **Step 1: Katalogschlüssel** in allen vier Sprachen, Deutsch von Hand. Wächtertest für gleiche Schlüsselmengen grün.
- [ ] **Step 2: `ConnectionSurfacePlan` um den gescheiterten Aufbau erweitern.** Heute bildet er `.connected`, `.degraded` und `nil` alle auf `.form` ab; der gescheiterte Versuch braucht seine eigene Antwort. Eine offene Host-Schlüssel-Abfrage überschreibt weiterhin alles.
- [ ] **Step 3: Die Fläche zeichnen** und die vier Handlungen verdrahten. „Erneut versuchen" ruft **dieselbe** Verbindungsfunktion wie ein Klick in der Seitenleiste. „Bearbeiten" führt aufs vorausgefüllte Formular, „Sitzung bearbeiten" in den Sitzungs-Editor, „Schließen" schließt den Tab.
- [ ] **Step 4: Der Details-Dialog** mit der vollständigen Meldung.
- [ ] **Step 5: Wächter.** Die Erlaubnisliste über Wähl- und Übergabestellen muss die neue „Erneut versuchen"-Stelle erfassen — **durch Mutation belegen**, dass ein direkter Wählvorgang dort rot wird.
- [ ] **Step 6: Volle Suite mehrfach grün.** — [ ] **Step 7: Commit** — `feat(app): keep a failed connect in its tab`

---

## Was ausdrücklich nicht dazugehört

- Der Abriss-Fall (`.lost`) und seine Texte bleiben unverändert.
- Ein Aufbau, der an einer Frage scheitert, die nur ein Mensch beantworten kann, hat seinen eigenen Weg und wird nicht angefasst.
- Kein Umbau des Formulars und keine Änderung daran, wo sein Fehlertext lebt.
