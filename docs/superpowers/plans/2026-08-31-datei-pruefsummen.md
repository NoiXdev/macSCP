# Prüfsummen für Dateien — Umsetzungsplan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Auf Anforderung sagen können, welche Prüfsumme eine Datei hat —
und dabei nie verschweigen, woher der Wert kommt.

**Grundlage:** `docs/superpowers/specs/2026-08-31-datei-pruefsummen-design.md`

**Architektur:** Eine **enge** Fähigkeit in Core („berechne die Prüfsumme
dieser Datei"), kein allgemeiner Befehlsweg. Das Lesen der Ausgabe, die Wahl
der Befehlsform und die Herkunft eines Werts sind reine Funktionen.

## Global Constraints

- Code, Kommentare, Bezeichner, Testnamen, Commit-Messages: **nur Englisch**.
- Conventional Commits; Footer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- **Kein `exec(String)` in Core**, in keiner Form und unter keinem Namen. Der
  Aufrufer darf keinen Befehl formulieren können.
- **Der Pfad geht durch `PosixQuoting`.** Keine zweite Quoting-Regel.
- **Die Antwort der Gegenseite ist Eingabe.** Nur das erste Feld wird
  gelesen, nur als Hex in der Länge des Verfahrens; der zurückgegebene Pfad
  wird nicht verglichen und nicht angezeigt.
- **Kein Herunterladen**, um zu rechnen — auch nicht als Ausweichweg.
- **Jeder neue Wartepunkt bekommt eine Frist.** Diese Woche wurde zweimal
  gemessen, dass ein `await` gegen eine schweigende Gegenseite nicht
  zurückkommt.
- Nutzer-sichtbare Texte in **alle vier Kataloge** (`en`, `de`, `fr`, `pl`)
  über `L10n.string(_:_:)`; Core-seitig `CoreL10n.string(_:)`. **Kein String
  Catalog, kein `String(localized:)`, kein `Bundle.module`.** Das Deutsche
  **duzt**.
- **Nur zeigen, was möglich ist** — nichts wird ausgegraut; „dieser Server
  liefert keine Prüfsummen" ist eine Aussage, ein toter Eintrag nicht.
- **Keine Zeilennummern, keine Ortsangaben in Kommentaren.** Jede Zahl und
  jede Aufzählung wird in dem Durchgang gezählt, der sie schreibt.
- Alle sechs Targets stehen auf `.swiftLanguageMode(.v6)`; **CI wird rot,
  sobald die Zahl eindeutiger Warnorte über 1 liegt.** Warnungen werden auf
  einem **frischen** Scratch-Pfad gemessen.
- Ein Scratch-Pfad je Agent, nach Gebrauch gelöscht. Die App wird nicht
  gestartet, nichts gepusht.

---

### Task 1: Die reinen Werte

**Files:**
- Create: `Sources/macSCPCore/RemoteFS/FileChecksum.swift`
- Test: `Tests/macSCPCoreTests/FileChecksumTests.swift`

**Interfaces:**
- Produces: das Verfahren als Aufzählung, das Ergebnis samt **Herkunft**, das
  Lesen einer Ausgabe, und die Wahl der Befehlsform. Tasks 2–4 rufen daraus.

**Warum zuerst:** alles hier ist ohne Verbindung prüfbar, und es legt fest,
was ein Ergebnis überhaupt sagen kann. Ein Ergebnis **ohne** Herkunft darf
sich nicht bauen lassen.

- [ ] **Step 1: Rot zuerst.** Tests für: `<hex>  <pfad>` wird gelesen und
  ergibt nur das Hex; falsche Länge, Nicht-Hex, leere Ausgabe und eine
  Ausgabe **ohne** Pfad werden abgelehnt; ein Pfad in der Antwort, der nicht
  der angefragte ist, ändert **nichts** (er wird gar nicht angesehen); die
  GNU- und die BSD-Form ergeben denselben gelesenen Wert.
- [ ] **Step 2: Umsetzen.** Die Herkunft ist **Teil** des Ergebnisses, nicht
  ein zweites Feld daneben, das jemand weglassen kann — bau es so, dass ein
  Ergebnis ohne sie nicht konstruierbar ist.
- [ ] **Step 3: Der S3-Fall.** Ein ETag der Form `"…-N"` ist **kein**
  Dateihash. Eine Funktion entscheidet das, mit Tests für beide Formen und
  für die Anführungszeichen, die S3 mitliefert.
- [ ] **Step 4:** Volle Suite grün, keine neue Warnung (frischer Bau).
- [ ] **Step 5: Commit** — `feat(remotefs): say what a checksum is and where it came from`

---

### Task 2: Die enge Fähigkeit über SSH

**Files:**
- Modify: `Sources/macSCPCore/SSH/CitadelFileSystem.swift`,
  `Sources/macSCPCore/Capabilities/ProtocolCapabilities.swift`,
  `Sources/macSCPCore/RemoteFS/RemoteFileSystem.swift`
- Test: `Tests/macSCPCoreTests/`, plus ein gegateter Fall gegen das Rig

**Interfaces:**
- Consumes: Task 1.

**Die Auflage, die diesen Task ausmacht:** die Fähigkeit heißt „berechne die
Prüfsumme dieser Datei mit diesem Verfahren" und nimmt **keinen Befehl**
entgegen. Wer hier einen `String` durchreicht, hat den Entwurf verletzt —
melden, nicht bauen.

- [ ] **Step 1: Rot zuerst**, gegen einen Doppelgänger: der Pfad wird
  gequotet (`PosixQuoting`, keine zweite Regel), die Befehlsform folgt der
  einmal je Verbindung ermittelten Antwort, und eine unlesbare Ausgabe wird
  zum Fehler statt zu einem Wert.
- [ ] **Step 2: Der Ausführungsweg.** Eng, mit **Frist**. Wo `CitadelShell`
  Bausteine hat, benutze sie — **lies nach, statt zu erfinden**, und wenn
  der Terminalweg nicht taugt, sag im Bericht warum.
- [ ] **Step 3: Die Fähigkeit in `ProtocolCapabilities`**, nach dem Vorbild
  von `supportsPresignedURL`. Damit verzweigt die Oberfläche später **nicht**
  über `ConnectionKind`.
- [ ] **Step 4: Ein gegateter Fall** (`MACSCP_ITEST=1`) gegen das Rig, der
  eine echte Prüfsumme holt und mit einer lokal gerechneten vergleicht. Rig
  aus dem Haupt-Checkout, nie aus einem Worktree; aufräumen auf jedem
  Ausgangspfad.
- [ ] **Step 5:** Volle Suite grün, keine neue Warnung (frischer Bau).
- [ ] **Step 6: Commit** — `feat(ssh): compute a file's checksum on the remote`

---

### Task 3: Die anderen drei Backends

**Files:**
- Modify: `Sources/macSCPCore/S3/S3FileSystem.swift`,
  `Sources/macSCPCore/RemoteFS/LocalFileSystem.swift`,
  `Sources/macSCPCore/WebDAV/WebDAVFileSystem.swift`
- Test: die jeweiligen Suiten

- [ ] **Step 1: Lokal** — gerechnet, Herkunft „lokal gerechnet".
- [ ] **Step 2: S3** — aus dem ETag, **und** die Mehrteil-Einschränkung im
  Ergebnis. Ein Mehrteil-ETag darf nicht als Dateihash herauskommen; Test für
  beide Formen.
- [ ] **Step 3: WebDAV** — nicht verfügbar, und zwar als **Aussage**. Kein
  `OC-Checksum` in diesem Vorgang.
- [ ] **Step 4:** Volle Suite grün, keine neue Warnung (frischer Bau).
- [ ] **Step 5: Commit** — `feat(remotefs): answer the checksum question per backend`

---

### Task 4: Anfordern und anzeigen

**Files:**
- Modify: die Datei-Info, das Kontextmenü der Dateitabelle, `SettingsStore`
  und `SettingsView`
- Modify: alle vier `Localizable.strings`
- Test: `Tests/macSCPAppKitTests/`

**Interfaces:**
- Consumes: Tasks 1–3.

- [ ] **Step 1: In der Datei-Info** für eine Datei, auf Anforderung.
- [ ] **Step 2: Für eine Auswahl** über das Kontextmenü. **Eine nach der
  anderen**, Ergebnis erscheint sobald es da ist, Abbrechen lässt das
  Gerechnete stehen.
- [ ] **Step 3: Die Herkunft steht dabei** — bei S3 sichtbar, dass ein
  Mehrteil-ETag den Inhalt nicht beschreibt. Wer diesen Text weglässt, macht
  die Anzeige zur Lüge.
- [ ] **Step 4: Die Einstellung.** SHA-256 voreingestellt; an MD5 und SHA-1
  steht, dass sie zum Abgleich gegen eine fremde Angabe taugen und **nicht**
  als Nachweis, dass zwei Dateien gleich sind.
- [ ] **Step 5: Wo es nicht geht, steht warum.** Kein ausgegrauter Eintrag.
- [ ] **Step 6:** Volle Suite grün, keine neue Warnung (frischer Bau).
- [ ] **Step 7: Commit** — `feat(files): show a checksum on request, and where it came from`

---

## Was ausdrücklich nicht dazugehört

- **Keine Tabellenspalte** — Punkt 3 des Eintrags, eigener Vorgang, und
  dessen Frage 3 ist unbeantwortet.
- **Kein allgemeiner Befehlsweg** in Core.
- **Kein Herunterladen**, um zu rechnen.
- **Kein `OC-Checksum`** für WebDAV.
