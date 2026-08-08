# M26 — Der blocklose SSH-Datensatz Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Einen `.ssh`-Datensatz ohne gespeicherten SSH-Block beim Laden
verwerfen, die fünfzehn Leser auf `guard let ssh` umstellen und die vier
erfindenden `StoredSession`-Accessoren löschen.

**Architecture:** Der Verwurf sitzt an der Hygiene-Naht, die im
`SessionStore`-Lesepfad schon existiert (verwaiste Gruppen-IDs). Danach gilt
`.ssh` ⇒ `ssh != nil` in der Praxis, und `host`/`port`/`username`/`authKind`
haben keine Leser mehr.

**Tech Stack:** Swift 6 (`.swiftLanguageMode(.v5)`), SwiftPM, macOS 15+,
Swift Testing (`@Test`/`#expect`).

**Spec:** `docs/superpowers/specs/2026-08-08-m26-blockloser-ssh-datensatz-design.md`

## Global Constraints

- **Code und Kommentare: nur Englisch.** Bezeichner, Doc-Kommentare,
  Inline-Kommentare, Testnamen. Kein Deutsch in Quelldateien.
- **Commit-Messages: Englisch, Conventional Commits.** Footer auf jedem Commit:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- **Commit/Push nur auf ausdrückliche Anfrage.** Kein `scripts/release`.
- **Ein Secret-Wert darf nie geloggt, gedruckt oder in einen Fehler eingebettet
  werden.** Secrets leben ausschließlich im Keychain.
- **Die GUI-App nicht starten.** Kein Schlüsselmaterial committen.
- `swift build` bleibt sauber **inklusive App-Target**. Testzahl **≥ 1604**.
- **Keine neuen Localization-Schlüssel.**
- **Nur `.ssh` wird verworfen**, nicht `.s3`/`.webdav` — bewusste Asymmetrie mit
  Begründung in der Spec. Wer sie ausdehnt, muss die vorhandenen
  Blocklos-Wachen mit anfassen; das ist nicht dieser Meilenstein.
- **Der Lesepfad schreibt die Datei nicht.** Kein `persist` in `load()`.
- Sitzungen in Tests über die Fixtures aus `SessionFixtures.swift`; die
  Fixture-DATEI für Task 1 wird von Hand geschrieben (kein Schreibpfad der App
  kann sie erzeugen), mit Kommentar warum.

---

## File Structure

| Datei | Verantwortung | Task |
|---|---|---|
| `Sources/macSCPCore/Sessions/SessionStore.swift` | Verwurf im Lesepfad | 1 |
| `Sources/macSCPCore/Sessions/LoginResolver.swift` | 6 Leser → `guard let ssh` | 2 |
| `Sources/macSCPCore/Presentation/SessionListViewModel.swift` | 5 Leser → `guard let ssh` | 2 |
| `Sources/macSCPCore/SSH/SSHFieldSchema.swift` | 4 Leser → leerer Beutel | 2 |
| `Sources/macSCPCore/Sessions/StoredSession.swift` | die vier Accessoren löschen | 2 |
| `docs/superpowers/specs/2026-08-08-m26-abschluss.md` | Abschlussbericht | 3 |

Neue Tests in die bestehende Suite des geprüften Typs (`SessionStoreTests`,
`BackendDescriptorTests`). **Keine neue Testdatei.**

## Warum die Tests als Tabelle stehen

Drei Meilensteine haben zusammen siebzehn Defekte gefunden, die **im Plan**
steckten statt in der Umsetzung — fast alle in nie ausgeführtem Testcode.
Produktionscode steht deshalb unten wörtlich, Tests als Tabelle aus (Name,
Aufbau, Erwartung) plus Zeiger auf die zu kopierende Form.

---

## Task 1: Der Verwurf beim Laden

**Files:**
- Modify: `Sources/macSCPCore/Sessions/SessionStore.swift:61-78` (`load()`)
- Test: `Tests/macSCPCoreTests/SessionStoreTests.swift`

**Interfaces:**
- Produces: nichts Neues. `load()` bleibt `private`; die Wirkung ist über die
  öffentliche Leseschnittstelle des Stores sichtbar.

- [ ] **Step 1: Die Tests schreiben (rot)**

Aufbau von den vorhandenen `SessionStore`-Tests kopieren: echter Store über
eine Datei in einem temporären Verzeichnis, nicht über einen Mock — geprüft
wird der Lesepfad selbst.

Die Fixture-Datei wird **von Hand als JSON geschrieben**: ein Datensatz mit
`"kind": "ssh"` und **ohne** `"ssh"`-Schlüssel, dazu ein gesunder
SSH-Nachbar. Im Test kommentieren, warum von Hand — kein Schreibpfad der App
kann diesen Zustand erzeugen.

| Test | Aufbau | Erwartung |
|---|---|---|
| `aBlocklessSSHRecordIsDroppedWhenLoading` | die Fixture-Datei, dann Store lesen | die geladene Liste enthält den blocklosen Datensatz **nicht** |
| `aHealthyNeighbourSurvivesTheDrop` | dieselbe Datei | der gesunde Nachbar ist da, mit allen Feldern — **ein kaputter Eintrag lässt die Datei nicht scheitern** |
| `loadingDoesNotRewriteTheFile` | Datei-Inhalt als `Data` vor dem Lesen merken, Store lesen, Inhalt erneut lesen | byte-gleich. Pinnt die Entscheidung, dass der Lesepfad nicht schreibt |
| `aBlocklessS3RecordIsKept` | eine Datei mit einem `"kind": "s3"`-Datensatz ohne `"s3"`-Schlüssel | der Datensatz ist **noch da** — pinnt die bewusste Asymmetrie aus der Spec, damit ein späteres Ausdehnen eine Entscheidung ist und kein Versehen |

- [ ] **Step 2: Rot bestätigen**

Run: `swift test --filter SessionStore`
Expected: `aBlocklessSSHRecordIsDroppedWhenLoading` schlägt fehl (der Datensatz
wird heute geladen). Die anderen drei beschreiben heutiges Verhalten und sind
bereits grün — **das ist beabsichtigt**, sie sind die Klammer. Welche rot und
welche grün waren, gehört in den Task-Bericht.

- [ ] **Step 3: Den Verwurf einbauen**

In `load()`, **nach** dem vorhandenen Gruppen-Sweep und **vor** `return file`:

```swift
        // Second hygiene rule, same shape as the group sweep above: an `.ssh`
        // record with no stored SSH block is unusable -- no host, no user
        // name, nothing to dial -- and before M26 it was the last thing that
        // made `StoredSession`'s SSH accessors invent `""`/`22`/`""`/
        // `.password` for a session that never had them.
        //
        // Only `.ssh`. An `.s3`/`.webdav` record with no block is equally
        // unusable, but those backends have no inventing accessors (a missing
        // block yields the EMPTY bag) and their blockless case is already
        // caught explicitly in several places -- dropping them here would make
        // those guards unreachable without removing them. See the design doc.
        //
        // Deliberately does NOT rewrite the file: a write on the read path
        // would be a new failure mode for a problem nobody has, and would
        // change the user's data without being asked. The next regular save
        // omits the record anyway; until then it is skipped on every start.
        file.sessions.removeAll { $0.kind == .ssh && $0.ssh == nil }
```

- [ ] **Step 4: Grün bestätigen**

Run: `swift test --filter SessionStore`
Expected: PASS.
Run: `swift test`
Expected: alles grün. **Schlägt ein bestehender Test fehl, ist das ein
Befund** — er gehört in den Bericht, nicht weggeschrieben.

- [ ] **Step 5: Commit**

```bash
git add Sources/macSCPCore/Sessions/SessionStore.swift Tests/macSCPCoreTests/SessionStoreTests.swift
git commit -m "fix(core): drop an SSH record with no stored block when loading"
```

---

## Task 2: Die fünfzehn Leser und die vier Accessoren

**Files:**
- Modify: `Sources/macSCPCore/SSH/SSHFieldSchema.swift:288-296` (`values(from:)`)
- Modify: `Sources/macSCPCore/Sessions/LoginResolver.swift:214-231` (`resolveJump`)
- Modify: `Sources/macSCPCore/Presentation/SessionListViewModel.swift:252-275` (`delete`)
- Modify: `Sources/macSCPCore/Sessions/StoredSession.swift` (die vier Accessoren)
- Test: `Tests/macSCPCoreTests/BackendDescriptorTests.swift`

**Interfaces:**
- Consumes: den Verwurf aus Task 1 — er macht die Guards in der Praxis
  unerreichbar, weshalb ihr Verhalten „defensiv" statt „normal" ist.

**Alles in EINEM Task**, weil die Accessor-Löschung und die Umstellung der
Leser zusammen kompilieren müssen.

- [ ] **Step 1: Die beiden M25-Tests umschreiben (rot)**

In `BackendDescriptorTests` steht `anSSHSessionWithoutItsBlockStillShowsAPasswordField`
(M25). Er nagelt fest, dass ein blockloser `.ssh`-Datensatz einen **gefüllten**
Beutel liefert. Nach diesem Task liefert er einen leeren.

**Umschreiben, nicht löschen** — zu `anSSHSessionWithoutItsBlockYieldsTheEmptyBag`
oder gleichwertig. Der Doc-Kommentar sagt, was jetzt gilt, und nennt **M26** als
die Stelle, an der sich die Antwort geändert hat. Erwartung: `visibleSecretField(for:)`
ist `nil` **und** `descriptor.sessionValues(session).raw.isEmpty`.

**Der `.s3`/`.webdav`-Zwilling bleibt unverändert** — er pinnt eine Eigenschaft
des Schemas, nicht der Accessoren, und gilt weiter.

- [ ] **Step 2: Rot bestätigen**

Run: `swift test --filter BackendDescriptor`
Expected: der umgeschriebene Test schlägt fehl (heute ist der Beutel gefüllt).

- [ ] **Step 3: `SSHFieldSchema.values(from:)` umstellen**

Der Rumpf beginnt heute mit `var values = ...` und liest dann die vier
Accessoren. Voranstellen:

```swift
        // A record whose kind says `.ssh` but carries no block is dropped when
        // the store loads (M26), so this cannot be reached through the app --
        // it is the structural counterpart of that rule, and it puts SSH on
        // the same footing as the other two backends, whose `sessionValues`
        // has always returned the empty bag for a missing block.
        guard let ssh = session.ssh else { return FieldValues() }
```

und die vier Zeilen darunter von `session.` auf `ssh.` umstellen:
`ssh.host`, `String(ssh.port)`, `ssh.username`, `ssh.authKind.rawValue`.
`keyPath`, `managedKeyID` und der Jump-Block bleiben, wie sie sind — sie lesen
schon heute über `session.ssh?` oder über die bleibenden Accessoren.

- [ ] **Step 4: `LoginResolver.resolveJump` umstellen**

Nach dem `kind == .ssh`-Guard und vor dem ersten Lesezugriff:

```swift
        // Defensive, and unreachable in practice: a blockless `.ssh` record is
        // dropped when the store loads (M26), so `sessions` cannot contain one
        // and the lookup above would already have thrown. `.missingJumpSession`
        // is the literally correct answer either way -- from the reference's
        // point of view a dropped record IS gone.
        guard let ssh = referenced.ssh else {
            throw LoginResolveError.missingJumpSession
        }
```

Dann die sechs Lesezugriffe umstellen: `referenced.authKind` → `ssh.authKind`
(zweimal), `referenced.username` → `ssh.username` (zweimal), und im
`ResolvedJump` `referenced.host`/`referenced.port` → `ssh.host`/`ssh.port`.
`referenced.keyPath` bleibt (bleibender Accessor).

- [ ] **Step 5: `SessionListViewModel.delete` umstellen**

Innerhalb des `if !affected.isEmpty`-Blocks, ganz vorn:

```swift
            // Defensive, and unreachable in practice for the same reason as
            // above: `affected` is non-empty only for `.ssh`, and a blockless
            // `.ssh` record is dropped when the store loads (M26). Skipping
            // restoration is the rule M24 established for a bastion whose
            // host cannot be read -- leave the reference dangling and let the
            // next connect say so honestly.
            guard let ssh = session.ssh else { return finishDeleting(session, secretFailures: 0) }
```

**Achtung:** ein früher `return` hier würde die Löschung selbst überspringen.
Prüfe, wie der Rumpf nach der Schleife aufgebaut ist, und wähle die Form, die
die Löschung **nicht** überspringt — entweder ein `if let ssh { … }` um
Berechnung und Schleife (bevorzugt, weil es nichts umbaut), oder eine
Extraktion des Endes in einen Helfer. **Der obige `finishDeleting`-Aufruf ist
eine Skizze, keine existierende Funktion** — wenn du den Helfer nicht brauchst,
nimm ihn nicht. Der Test aus Schritt 8 fängt den Fehler, falls die Löschung
verloren geht.

Dann `session.username`/`session.authKind`/`session.host`/`session.port` in
diesem Block auf `ssh.` umstellen. `resolvedSSHLogin(for: session)` bleibt.

- [ ] **Step 6: Die vier Accessoren löschen**

In `StoredSession.swift` die vier Zeilen entfernen:

```swift
    var host: String { ssh?.host ?? "" }
    var port: Int { ssh?.port ?? 22 }
    var username: String { ssh?.username ?? "" }
    var authKind: AuthKind { ssh?.authKind ?? .password }
```

**`keyPath` und `jump` bleiben.** Den Doc-Kommentar über der Gruppe anpassen:
er beschreibt heute vier erfindende und zwei ehrliche Accessoren; künftig nur
noch die beiden ehrlichen. Was über die gelöschten dort steht, kommt weg —
kein Kommentar über Code, den es nicht mehr gibt.

- [ ] **Step 7: Bauen und die Testleser nachziehen**

Run: `swift build`
Expected: Fehler in **Tests**, die die Accessoren lesen (M25 zählte 38
Lesestellen). Jede einzeln nachziehen: auf `session.ssh?.host` o. Ä., oder auf
die Fixture-Werte, je nachdem was der Test aussagt. **Keine Testaussage
abschwächen** — wo ein Test einen Rückfallwert erwartete, den es nicht mehr
gibt, ist die richtige Änderung die Erwartung auf den echten Wert zu drehen,
nicht die Behauptung zu streichen. Jede Anpassung, die mehr ist als das
Umlesen desselben Werts, gehört in den Bericht.

- [ ] **Step 8: Den `delete`-Test ergänzen**

| Test | Aufbau | Erwartung |
|---|---|---|
| `deletingASessionStillRemovesItWhenItsBlockIsMissing` | eine `.ssh`-Sitzung ohne Block **direkt** über `StoredSession(...)` gebaut (Kommentar warum) und über den Store gespeichert; eine zweite Sitzung verweist per `jump.sessionID` darauf; `delete(broken)` | die Sitzung ist gelöscht **und** der Verweis unverändert. Fängt den Fehler aus Step 5, falls ein früher `return` die Löschung überspringt |

- [ ] **Step 9: Grün bestätigen**

Run: `swift test`
Expected: alles grün, ≥ 1604.
Run: `swift build`
Expected: sauber inklusive App-Target.
Run: `grep -n "var host\|var port\|var username\|var authKind" Sources/macSCPCore/Sessions/StoredSession.swift`
Expected: keine Treffer.

- [ ] **Step 10: Commit**

```bash
git add Sources/macSCPCore Tests/macSCPCoreTests
git commit -m "refactor(core): read the SSH block directly and retire the inventing accessors"
```

---

## Task 3: Meilenstein-Abschluss

**Files:**
- Create: `docs/superpowers/specs/2026-08-08-m26-abschluss.md`

- [ ] **Step 1: Volle Verifikation**

```bash
swift build
swift test
```
Testzahl notieren (≥ 1604).

Das Docker-Rig aus dem **Haupt-Checkout** starten, nie aus einem Worktree:

```bash
docker compose -f docker/test-server/compose.yml up -d
MACSCP_ITEST=1 swift test
MACSCP_KEYCHAIN=1 swift test --filter Keychain
```

Bleibt ein Lauf bei 0 % CPU stehen, ist das der seit M20 bekannte Hänger
(`docs/superpowers/specs/2026-08-08-testsuite-haenger-untersuchung.md`) —
abbrechen, neu starten, im Bericht vermerken, **nicht** als M26-Befund zählen.
Danach `pgrep -fl swiftpm-testing-helper` prüfen: gekillte Läufe hinterlassen
Waisen.

Kataloge:
```bash
for f in Sources/MacSCPApp/Resources/*.lproj/Localizable.strings Sources/macSCPCore/Resources/*.lproj/Localizable.strings; do plutil -lint "$f"; done
```

- [ ] **Step 2: Die Gegenprobe**

```bash
grep -rn "\.host\b" Sources/ --include=*.swift | grep -v "URL\|url\|endpoint\|baseURL" | head -20
```

Beurteilen, ob ein verbliebener Treffer noch `StoredSession` betrifft. Erwartet
wird: keiner — die Accessoren existieren nicht mehr, der Compiler hätte es
gemeldet. Das Ergebnis kommt in den Bericht, auch wenn es leer ist.

- [ ] **Step 3: Den Abschlussbericht schreiben**

`docs/superpowers/specs/2026-08-08-m26-abschluss.md`, Form von
`2026-08-08-m25-abschluss.md` kopieren. Muss enthalten: die Verifikation
(Testzahlen, gegatete Läufe, Kataloge); die acht Erfolgskriterien der Spec mit
**Beleg statt Behauptung**; die Zahl der angepassten Tests aus Task 2 Step 7
und jede Anpassung, die mehr war als ein Umlesen; jeden Befund aus Task 1
Step 4; die eine Release-Notiz aus der Spec; was offen bleibt (die Asymmetrie
gegenüber `.s3`/`.webdav`, der unrepräsentierbare Zustand als möglicher
späterer Meilenstein); und die Zahl der unversendeten Commits
(`git rev-list --count origin/develop..develop`).

- [ ] **Step 4: Commit, nicht pushen**

```bash
git add docs/superpowers/specs/2026-08-08-m26-abschluss.md
git commit -m "docs(m26): record the milestone close"
```

Der Push erfolgt ausschließlich auf ausdrückliche Anordnung des Maintainers.

---

## Selbstreview des Plans

**Spec-Abdeckung.** Kriterium 1–3 → T1/Step 1; 4 → T2/Step 6 + T2/Step 9;
5 → T2/Step 6 (die beiden bleiben) und T3/Step 2; 6 → T2/Step 1; 7 → T2/Step 7
(die Befundregel) und T1/Step 4; 8 → T3/Step 1. Die Asymmetrie zu
`.s3`/`.webdav` ist als **Test** gepinnt (T1, `aBlocklessS3RecordIsKept`), nicht
nur als Prosa — sonst wäre ein späteres Ausdehnen ein Versehen statt einer
Entscheidung.

**Typkonsistenz.** `guard let ssh = session.ssh` / `referenced.ssh` liefert
`StoredSSHConfig` mit `host`/`port`/`username`/`authKind`/`keyPath`/`jump`;
alle Umstellungen lesen genau diese Namen.

**Eine bewusste Unschärfe, ausgewiesen statt versteckt:** Task 2 Step 5 gibt
den Guard als Skizze und sagt ausdrücklich, dass `finishDeleting` **nicht**
existiert. Ein früher `return` an dieser Stelle würde die Löschung selbst
überspringen, und welche Form richtig ist, hängt vom Rumpf ab, den der
Implementierer vor sich hat. Der Test aus Step 8 ist die Klammer, die den
Fehler fängt — das ist verlässlicher als eine Planzeile, die ich nicht
ausgeführt habe.
