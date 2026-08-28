# Testisolation: die drei Nachträge — Umsetzungsplan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Kein Test kann aus Versehen eine echte Ablage lesen oder beschreiben, und keine Prüfung meldet Erfolg über etwas, das sie gar nicht ansieht.

**Grundlage:** `docs/superpowers/specs/2026-08-22-backlog-testisolation.md` — der Eintrag ist zugleich der Entwurf; er nennt Befund und Behebung für jeden der drei Nachträge.

**Der Hauptbefund ist bereits erledigt:** `ContentView` hat die Test-Naht bekommen (`sessionListViewModel:`, `secretStore:`, `managedKeyStore:`). Offen sind die drei Nachträge.

## Global Constraints

- Code, Kommentare, Bezeichner, Testnamen, Commit-Messages: **nur Englisch**.
- Conventional Commits; Footer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- **Kein Mutationsversuch, der an echte Zugangsdaten-, Sitzungs- oder
  Konfigurationsablagen reichen kann.** Das ist die Regel, die dieser Eintrag
  selbst aufgestellt hat, und sie gilt beim Umsetzen genauso.
- **Isolation wird vorgeführt, nicht behauptet.** Wer sagt, ein Test schreibe
  nicht mehr in die echte Datei, zeigt das — Datei vorher, Suite laufen, Datei
  nachher.
- **Keine Zeilennummern, keine Ortsangaben in Kommentaren.** Jede Zahl und jede
  Aufzählung wird in dem Durchgang gezählt, der sie schreibt.
- Alle sechs Targets stehen auf `.swiftLanguageMode(.v6)`; **CI wird rot, sobald
  die Zahl eindeutiger Warnorte über 1 liegt.**
- Ein Scratch-Pfad, nach Gebrauch gelöscht.
- Die App wird nicht gestartet, nichts gepusht.

---

### Task 1: Die Vorgabewerte aus `SessionListViewModel.init` entfernen

**Files:**
- Modify: `Sources/macSCPCore/Presentation/SessionListViewModel.swift`,
  `Sources/MacSCPAppKit/ContentView.swift`, und die Testdateien, die
  konstruieren
- Test: die bestehenden Suiten; plus ein Nachweis (siehe Step 4)

**Der gemessene Ist-Zustand:** `init` trägt drei Vorgabewerte, die auf die
echten Verzeichnisse zeigen:

```swift
auditStore: AuditLogStore = AuditLogStore(directory: AuditLogStore.defaultDirectory),
loginSetStore: LoginSetStore = LoginSetStore(directory: SessionStore.defaultDirectory),
keys: ManagedKeyStore = ManagedKeyStore(directory: SessionStore.defaultDirectory)
```

und `init` ruft `reload()`. Ein Test, der einen Store weglässt, liest damit
eine echte Nutzerdatei.

**Zur Anzahl:** der Backlog-Eintrag nennt **16** Konstruktionen ohne
`loginSetStore:` und **51** ohne `auditStore:`, davon **8** mit anschließendem
`vm.delete(...)`. Diese Zahlen stammen vom 2026-08-25. **Zähl selbst** — und
zähl nicht mit `grep` auf einer Zeile: die Argumente stehen oft in den
folgenden Zeilen, eine Einzeilensuche zählt falsch. (Ich habe das beim
Planschreiben zuerst falsch gemacht.)

**Die einzige Produktivstelle** ist `ContentView`, wo das Modell mit
`sessionListViewModel ?? SessionListViewModel(...)` gebaut wird — die muss die
drei Stores danach explizit übergeben.

- [ ] **Step 1: Zählen und aufschreiben.** Wie viele Konstruktionsstellen es
  gibt, wie viele je Store fehlen, und wie viele davon anschließend schreiben
  (`vm.delete`, `vm.save`, …). Die Zahlen kommen in den Bericht.
- [ ] **Step 2: Die drei Vorgabewerte entfernen.** Danach kompiliert nichts
  mehr, was einen Store weglässt — das ist die Absicht, und es ist dieselbe
  Fähigkeitsgrenze wie beim Verbinden: nicht beobachten, sondern unmöglich
  machen.
- [ ] **Step 3: Die Aufrufstellen nachziehen.** Tests zeigen auf temporäre
  Verzeichnisse. **Keine Zusicherung wird abgeschwächt, um etwas kompilieren zu
  lassen** — wo ein Test bisher versehentlich die echte Datei las und dadurch
  bestand, ist das ein Fund und gehört in den Bericht.
- [ ] **Step 4: Die Isolation vorführen.** Der Eintrag verlangt das
  ausdrücklich: den Inhalt von
  `~/Library/Application Support/macSCP/sessions-v2.json` und `logins.json`
  vor und nach einem vollen Lauf vergleichen (Prüfsumme genügt) und das
  Ergebnis zitieren. **Nichts an diesen Dateien ändern.** Existiert eine nicht,
  ist „existiert nachher immer noch nicht" das Ergebnis.
- [ ] **Step 5:** Volle Suite grün, keine neue Warnung.
- [ ] **Step 6: Commit** — `refactor(sessions): make every store an explicit choice`

---

### Task 2: Katalogorte von der Platte ableiten

**Files:**
- Modify: `Tests/macSCPAppKitTests/LocalizationParityTests.swift`,
  `Tests/macSCPAppKitTests/GermanAddressFormTests.swift`

**Der gemessene Ist-Zustand:** beide zählen die Katalogorte **fest auf**. Die
Sprachen innerhalb eines Ortes werden von der Platte abgeleitet, die Orte
selbst nicht. Ein drittes lokalisiertes Ziel bliebe stillschweigend ungeprüft.

Der Eintrag ordnet das selbst ein: *„eine Prüfung, die weniger prüft, als sie
glaubt, ist schlechter als keine, weil sie Erfolg meldet."* Heute gibt es genau
zwei `Resources/`-Verzeichnisse, also folgenlos.

**Vorbild im Haus:** `ReconnectWiringGuardTests
.everySourceDirectoryIsScannedOrExplicitlyExcluded` leitet Wurzeln von der
Platte **und** aus `Package.swift` ab. Lies das, bevor du anfängst.

- [ ] **Step 1: Rot zuerst.** Leg ein drittes `Resources/`-Verzeichnis mit
  einem Katalog an, der absichtlich einen Schlüssel vermissen lässt, und
  belege, dass die Prüfungen es heute **nicht** bemerken. Räum es weg.
- [ ] **Step 2: Ableiten statt aufzählen**, nach dem Vorbild oben.
- [ ] **Step 3:** Dieselbe Probe noch einmal — jetzt muss sie **rot** werden.
  Beide Läufe zitieren.
- [ ] **Step 4:** Volle Suite grün, keine neue Warnung.
- [ ] **Step 5: Commit** — `test(l10n): find the catalogues instead of listing them`

---

### Task 3: Den Schutz im TLS-Stub festnageln

**Files:**
- Modify: `Tests/macSCPCoreTests/` (neue oder bestehende Wächterdatei)

**Der gemessene Ist-Zustand:** `Tests/macSCPCoreTests/LoopbackTLSStub.swift` ist
das einzige `import Security` unter `Tests/` und ruft `SecPKCS12Import`
**ungegated** — bei jedem `swift test`, nicht hinter `MACSCP_KEYCHAIN`. Dass
dabei nichts im Login-Keychain landet, hängt an **einer** Wörterbuchzeile:

```swift
kSecImportToMemoryOnly as String: kCFBooleanTrue as Any,
```

Ohne sie importiert der Aufruf in die Default-Keychain. Kein Verstoß — aber
die dünnste Stelle der Isolationszusage im ganzen Baum, gehalten von einer
Zeile, die ein Refactoring, ein Merge oder ein Copy-Paste in einen neuen Stub
entfernen kann.

- [ ] **Step 1: Der Wächter.** Jeder `SecPKCS12Import`-Aufruf unter `Tests/`
  muss `kSecImportToMemoryOnly` mit wahrem Wert im selben Optionen-Wörterbuch
  führen.

  **Diese Prüfung ist von Natur aus negativ** („kein Aufruf ohne das Flag") und
  fällt damit unter die Regel aus `CLAUDE.md`: sie braucht eine **positive**
  Prüfung daneben, die behauptet, dass es den Aufruf überhaupt gibt. Ohne die
  passt sie in dem Moment, in dem jemand die Datei umbenennt — und meldet
  Erfolg.
- [ ] **Step 2: Beide Richtungen belegen.** Flag entfernen → **rot**; Aufruf
  ganz entfernen → **die positive Prüfung rot**. Beide Läufe zitieren, beide
  Proben zurücknehmen.
- [ ] **Step 3:** Volle Suite grün, keine neue Warnung.
- [ ] **Step 4: Commit** — `test(security): pin the flag that keeps the stub out of the keychain`

---

## Was ausdrücklich nicht dazugehört

- **Keine Änderung an `SessionListViewModel.save`** und keine an dem, was die
  Stores tun.
- Kein Umbau der gegateten Suiten (`MACSCP_ITEST`, `MACSCP_KEYCHAIN`).
- Kein Aufräumen des Eintrags, den der ursprüngliche Vorfall in der echten
  `sessions-v2.json` hinterlassen hat — das ist eine Datei des Maintainers,
  und niemand außer ihm fasst sie an.
