# M25 — Die letzten Platzhalter-Leser Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Die fünf ungeschützten Leser von `StoredSession.host`/`port`/
`username`/`authKind` in `SessionListViewModel` abräumen und anschließend per
Compiler-Probe entscheiden, ob die vier Accessoren gelöscht werden können.

**Architecture:** Eine der drei Stellen ist gar kein Protokollproblem (`delete`
rechnet Werte aus, die es bei leerem `affected` nie benutzt — hochziehen). Die
beiden anderen stellen dieselbe Frage in SSH-Vokabular; die bekommt ein
Mitglied am `BackendDescriptor`, das drei Aufrufstellen bedient.

**Tech Stack:** Swift 6 (`.swiftLanguageMode(.v5)`), SwiftPM, macOS 15+,
Swift Testing (`@Test`/`#expect`).

**Spec:** `docs/superpowers/specs/2026-08-08-m25-platzhalter-leser-design.md`

## Global Constraints

- **Code und Kommentare: nur Englisch.** Bezeichner, Doc-Kommentare,
  Inline-Kommentare, Testnamen. Kein Deutsch in Quelldateien.
- **Commit-Messages: Englisch, Conventional Commits.** Footer auf jedem Commit:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- **Commit/Push nur auf ausdrückliche Anfrage.** Kein `scripts/release`.
- **Ein Secret-Wert darf nie geloggt, gedruckt oder in einen Fehler eingebettet
  werden.** Secrets leben ausschließlich im Keychain; JSON-Stores nie.
- **Die GUI-App nicht starten.** Kein Schlüsselmaterial committen.
- `swift build` bleibt sauber **inklusive App-Target**. Testzahl **≥ 1587**.
- **Keine neuen Localization-Schlüssel.** Die vier App-Kataloge behalten
  identische Schlüsselmengen (`LocalizableStringsTests` erzwingt es).
- Sitzungen in Tests **nur** über die Fixtures aus
  `Tests/macSCPCoreTests/SessionFixtures.swift` bauen (`sshSession`,
  `s3Session`, `webdavSession`), nie `StoredSession` direkt.
- **M25 ist eine reine Innenumstellung.** Jede beobachtete Verhaltensänderung
  ist ein Befund und gehört gemeldet, nicht weggeschrieben.

---

## File Structure

| Datei | Verantwortung | Task |
|---|---|---|
| `Sources/macSCPCore/Presentation/SessionListViewModel.swift` | `delete` hochziehen; `updateSession`/`exportPayload` auf das neue Mitglied | 1, 3 |
| `Sources/macSCPCore/Capabilities/BackendDescriptor.swift` | `visibleSecretField(for:)` | 2 |
| `Sources/macSCPCore/Connection/StoredSessionConnectionConfig.swift` | ausgeschriebene Kopie auf das Mitglied falten | 2 |
| `Sources/macSCPCore/Sessions/StoredSession.swift` | ggf. die vier Accessoren löschen | 4 |
| `docs/superpowers/specs/2026-08-08-m25-abschluss.md` | Abschlussbericht | 4 |

Neue Tests gehören in die bestehende Suite des geprüften Typs
(`SessionListViewModelTests`, `BackendDescriptorTests`). **Keine neue
Testdatei.**

## Warum die Tests als Tabelle stehen

M23 und M24 haben zusammen vierzehn Defekte gefunden, die **im Plan** steckten
und nicht in der Umsetzung — fast alle in nie ausgeführtem Testcode.
Produktionscode steht deshalb unten wörtlich, Tests als Tabelle aus (Name,
Aufbau, Erwartung) plus Zeiger auf die zu kopierende Form. Wer den Test
schreibt, führt ihn auch aus.

---

## Task 1: `delete` rechnet nur noch, wenn es etwas zu restaurieren gibt

**Files:**
- Modify: `Sources/macSCPCore/Presentation/SessionListViewModel.swift:244-290`
- Test: `Tests/macSCPCoreTests/SessionListViewModelTests.swift`

**Interfaces:**
- Produces: nichts Neues. `delete(_:) -> JumpRestoreResult` behält Signatur
  und Semantik.

**Warum das kein Descriptor-Fall ist:** `bastionUsername`, `bastionAuthKind`,
`bastionKeyPath` und `bastionSecret` werden **ausschließlich** in der Schleife
über `affected` gelesen. Seit M24 ist `affected` für jede Nicht-SSH-Sitzung
leer. Die Berechnung ist also toter Aufwand — inklusive eines Keychain-Zugriffs,
der bei einer S3-Sitzung deren **Secret Access Key** holt und verwirft.

- [ ] **Step 1: Den Test schreiben (rot)**

Anfügen an `SessionListViewModelTests`. Für den lesefeindlichen Store die Form
kopieren, die am Ende von `Tests/macSCPCoreTests/LoginMergePlannerTests.swift`
steht (ein `SecretStore`, dessen `password(for:)` per `Issue.record` den Test
scheitern lässt).

| Test | Aufbau | Erwartung |
|---|---|---|
| `deletingANonSSHSessionNeverReadsTheKeychain` | eine `s3Session`, gespeichert, **keine** verweisende Sitzung; ViewModel mit lesefeindlichem `SecretStore`; `delete(bucket)` | kein einziger `password(for:)`-Aufruf; `result.restored == 0`; die Sitzung ist gelöscht. **Ohne die Verlagerung schlägt er fehl**, weil `bastionSecret` heute unbedingt gelesen wird |

- [ ] **Step 2: Rot bestätigen**

Run: `swift test --filter SessionListViewModel`
Expected: `deletingANonSSHSessionNeverReadsTheKeychain` scheitert mit dem
`Issue.record` des Stores.

- [ ] **Step 3: Die Berechnung und die Schleife in einen Guard ziehen**

Den Block ab `// The deleted session's effective login, …` bis zum Ende der
`for referencing in affected`-Schleife ersetzen. `var secretFailures = 0`
bleibt **außerhalb**, weil der Rückgabewert es braucht:

```swift
        var secretFailures = 0
        // Nothing below is needed unless something actually references this
        // session as its bastion, and since M24 `affected` is empty for every
        // non-SSH session. Computing it anyway was not merely wasted work: the
        // `secrets.password(for:)` call reaches into the Keychain, and for an
        // `.s3` session the slot it reads holds that session's SECRET ACCESS
        // KEY -- fetched only to be discarded. A read of a secret nobody needs
        // is one read too many.
        if !affected.isEmpty {
            // The deleted session's effective login, via `resolvedSSHLogin(for:)`:
            // nil for a manual session (use its own fields + own keychain secret
            // below), a set's values otherwise. An
            // agent session/set reads no keychain at all (M10d rule).
            let resolvedBastionLogin = resolvedSSHLogin(for: session)
            let bastionUsername = resolvedBastionLogin?.username ?? session.username
            let bastionAuthKind = resolvedBastionLogin?.authKind ?? session.authKind
            let bastionKeyPath = resolvedBastionLogin?.keyPath ?? session.keyPath
            var bastionSecret: String?
            if let resolvedBastionLogin {
                bastionSecret = resolvedBastionLogin.secret
            } else if session.authKind != .agent {
                bastionSecret = (try? secrets.password(for: session.id)) ?? nil
            }

            for referencing in affected {
                guard var jump = referencing.jump else { continue }
                jump.host = session.host
                jump.port = session.port
                jump.username = bastionUsername
                jump.authKind = bastionAuthKind
                jump.keyPath = bastionKeyPath
                jump.loginSetID = nil
                jump.sessionID = nil

                var hadSecretFailure = false
                if let bastionSecret {
                    do {
                        try secrets.savePassword(bastionSecret, for: jump.secretID)
                    } catch {
                        hadSecretFailure = true
                    }
                }

                var updated = referencing
                // `referencing.jump` was non-nil above, so the SSH block exists:
                // only an SSH session can carry a jump at all since M23/T8.
                updated.ssh?.jump = jump
                // Throw-free by design (M10b pattern): a store-write failure for
                // one referencing session must not abort restoring the others,
                // nor the deletion that follows.
                try? store.upsert(updated)
                if hadSecretFailure {
                    secretFailures += 1
                }
            }
        }
```

- [ ] **Step 4: Grün bestätigen**

Run: `swift test --filter SessionListViewModel`
Expected: PASS — **einschließlich der bestehenden `delete`-Tests, unverändert.**
Muss ein bestehender `delete`-Test angefasst werden, hat die Verlagerung
Verhalten verschoben: das ist ein **Befund** für den Task-Bericht, keine
Testanpassung.

- [ ] **Step 5: Commit**

```bash
git add Sources/macSCPCore/Presentation/SessionListViewModel.swift Tests/macSCPCoreTests/SessionListViewModelTests.swift
git commit -m "perf(core): compute a bastion's login only when something references it"
```

---

## Task 2: Die Schema-Frage bekommt einen Namen

**Files:**
- Modify: `Sources/macSCPCore/Capabilities/BackendDescriptor.swift` (neues Mitglied neben `hasStoredConfiguration`)
- Modify: `Sources/macSCPCore/Connection/StoredSessionConnectionConfig.swift:108-112`
- Test: `Tests/macSCPCoreTests/BackendDescriptorTests.swift`

**Interfaces:**
- Produces: `BackendDescriptor.visibleSecretField(for session: StoredSession) -> ConnectionField?`
  — Task 3 ruft es zweimal auf.

- [ ] **Step 1: Die Tests schreiben (rot)**

Anfügen an `BackendDescriptorTests`. Sitzungen über die Fixtures; für SSH die
Auth-Art über `sshSession(..., authKind:)` setzen.

| Test | Aufbau | Erwartung |
|---|---|---|
| `sshAgentSessionShowsNoSecretField` | `sshSession(authKind: .agent)` | `visibleSecretField(for:) == nil` |
| `sshPasswordSessionShowsItsPasswordField` | `sshSession(authKind: .password)` | Feld-`id` ist `SSHField.password.rawValue` |
| `sshPrivateKeySessionShowsItsPassphraseField` | `sshSession(authKind: .privateKey, keyPath: "/k")` | Feld-`id` ist `SSHField.passphrase.rawValue` |
| `s3SessionAlwaysShowsItsSecretField` | `s3Session(name:)` | Feld-`id` ist `S3Field.secretAccessKey.rawValue` |
| `webdavSessionAlwaysShowsItsPasswordField` | `webdavSession(name:)` | Feld-`id` ist `WebDAVField.password.rawValue` |
| `anSSHSessionWithoutItsBlockStillShowsAPasswordField` | eine `.ssh`-Sitzung **ohne** SSH-Block — dafür `StoredSession(id:name:groupID:loginSetID:kind:)` **direkt** bauen (die einzige zulässige Ausnahme von der Fixture-Regel, weil keine Fixture einen blocklosen Zustand erzeugt; im Test kommentieren, warum) | Feld-`id` ist `SSHField.password.rawValue` — pinnt die Äquivalenztabelle der Spec: `sessionValues` liest durch die Rückfälle in einen gefüllten Beutel, das Ergebnis ist dasselbe wie heute |

- [ ] **Step 2: Rot bestätigen**

Run: `swift test --filter BackendDescriptor`
Expected: Kompilierfehler — das Mitglied existiert nicht.

- [ ] **Step 3: Das Mitglied anlegen**

In `BackendDescriptor.swift`, direkt **nach** `hasStoredConfiguration(_:)`:

```swift
    /// The secret field this stored session currently shows, or nil when it
    /// needs none (M25).
    ///
    /// The schema's answer to "does this login carry a secret at all", asked
    /// WITHOUT `StoredSession.authKind` — which for a `.s3`/`.webdav` session
    /// fabricates `.password`, the placeholder M23 set out to remove. Only
    /// ssh-agent shows no secret field, so the nil case IS the agent case for
    /// SSH and never arises for the other two backends.
    ///
    /// Deliberately does NOT ask `hasStoredConfiguration` itself. Its three
    /// callers want different things from a session whose block is missing —
    /// the CLI refuses it, both view-model paths carry on — and a member that
    /// guards sometimes would be worse than three callers asking their own
    /// question. What it DOES inherit is `sessionValues`'s asymmetry: for
    /// `.ssh` a missing block still reads through `StoredSession`'s own
    /// fallbacks into a POPULATED bag, while `.s3`/`.webdav` yield an empty
    /// one (see `sessionValues(_:)`).
    public func visibleSecretField(for session: StoredSession) -> ConnectionField? {
        credentialSchema.visibleSecretField(
            in: sessionValues(session), namespace: fieldNamespace)
    }
```

- [ ] **Step 4: Die ausgeschriebene Kopie im CLI-Pfad falten**

In `StoredSessionConnectionConfig.build`, die zwei Zeilen

```swift
        let secretField = descriptor.credentialSchema.visibleSecretField(
            in: values, namespace: descriptor.fieldNamespace)
```

ersetzen durch

```swift
        let secretField = descriptor.visibleSecretField(for: session)
```

Der lange Kommentarblock darüber bleibt **unverändert** — er erklärt die
Secret-Regel, nicht die Schreibweise. Das Mitglied rechnet `sessionValues`
dabei ein zweites Mal aus (`values` steht schon da); das ist ein reiner
Wörterbuchaufbau ohne Seiteneffekt, und eine Regel an einer Stelle ist es wert.

- [ ] **Step 5: Grün bestätigen**

Run: `swift test --filter "BackendDescriptor|StoredSessionConnectionConfig"`
Expected: PASS.
Run: `swift build`
Expected: sauber inklusive App-Target.

- [ ] **Step 6: Commit**

```bash
git add Sources/macSCPCore Tests/macSCPCoreTests/BackendDescriptorTests.swift
git commit -m "feat(core): let the descriptor say whether a session carries a secret"
```

---

## Task 3: Die beiden Aufrufstellen im ViewModel

**Files:**
- Modify: `Sources/macSCPCore/Presentation/SessionListViewModel.swift:336` (`updateSession`) und `:772` + `:791` (`exportPayload`)
- Test: `Tests/macSCPCoreTests/SessionListViewModelTests.swift`

**Interfaces:**
- Consumes: `BackendDescriptor.visibleSecretField(for:)` aus Task 2.

**Die Falle dieses Tasks** steht in der Spec und wird hier wiederholt, weil sie
der einzige Weg ist, den Task falsch zu machen: in `exportPayload` kommt die
Agent-Eigenschaft einer **set-gebundenen** Sitzung aus dem SET
(`resolved?.authKind`), nicht aus der Sitzung. Wer die ganze Zeile durch eine
Schema-Frage an die Sitzungswerte ersetzt, lässt eine Sitzung an einem
Agent-Set plötzlich ein Secret suchen und im nutzer-sichtbaren „N Passwörter
fehlen" mitzählen. **Nur der Rückfall-Zweig wird ersetzt.**

- [ ] **Step 1: Die Tests schreiben (rot)**

| Test | Aufbau | Erwartung |
|---|---|---|
| `updateSessionClearsALeftoverSlotWhenSwitchingToAgent` | `sshSession(authKind: .password)` gespeichert, Secret unter der Sitzungs-ID; dieselbe Sitzung mit `authKind: .agent` durch `updateSession(_:newSecret: nil)` | unter der Sitzungs-ID liegt kein Secret mehr |
| `updateSessionKeepsAnS3SessionsSecret` | `s3Session` gespeichert, Secret unter der Sitzungs-ID; `updateSession(_:newSecret: nil)` mit umbenannter Sitzung | das Secret liegt unverändert da. **Ohne die richtige Umstellung fällt es weg**, wenn jemand die Frage falsch herum stellt |
| `updateSessionKeepsAWebDAVSessionsSecret` | wie oben mit `webdavSession` | dito |
| `exportingASessionBoundToAnAgentLoginSetCarriesNoPasswordAndCountsNone` | ein `LoginSet` mit `authKind: .agent`, eine `sshSession(loginSetID:)` daran gebunden, Export mit `includePasswords: true` | die exportierte Sitzung hat kein Passwort **und** `missingPasswordCount == 0`. **Das ist Erfolgskriterium 4** — der Test, den eine pauschale Umstellung rot machen würde |
| `exportingAManualAgentSessionCarriesNoPasswordAndCountsNone` | `sshSession(authKind: .agent)`, nicht set-gebunden, Export mit `includePasswords: true` | dito — hier greift der neue Schema-Zweig |

Aufbau der Export-Tests von den vorhandenen `exportPayload`-Tests in derselben
Datei kopieren (Suchbegriff `includePasswords`).

- [ ] **Step 2: Rot bestätigen**

Run: `swift test --filter SessionListViewModel`
Expected: die Agent-Export-Tests und mindestens einer der Secret-Erhalt-Tests
scheitern noch nicht — sie beschreiben teils heutiges Verhalten. **Das ist in
Ordnung und der Punkt:** sie sind die Regressionsklammer für Step 3. Welche rot
und welche schon grün sind, gehört in den Task-Bericht.

- [ ] **Step 3: `updateSession` umstellen**

```swift
            if BackendDescriptor.descriptor(for: updated.kind)
                .visibleSecretField(for: updated) == nil {
                // No secret field on screen means this login needs none, which
                // today is ssh-agent and nothing else (M10d) -- clean up a
                // leftover manual slot from before the switch. Asking the
                // schema rather than `updated.authKind` keeps a `.s3`/`.webdav`
                // session out of this branch by its own declaration instead of
                // by the accident that its fabricated auth kind is not `.agent`.
                try? secrets.deletePassword(for: updated.id)
            } else if let newSecret, !newSecret.isEmpty {
```

- [ ] **Step 4: `exportPayload` umstellen**

Die Bindung

```swift
            let authKind = resolved?.authKind ?? session.authKind
```

**ersatzlos streichen** — sie wird in dieser Funktion an genau einer Stelle
gelesen, nämlich der Wache unten (nachgeprüft: die beiden anderen
`authKind`-Vorkommen sind `resolved.authKind.rawValue` für die Feldablage und
der eigene `authKind` des Jumps). Stattdessen:

```swift
            // Whether a secret can be fetched at all. The two branches are NOT
            // interchangeable: for a set-bound session the agent-ness belongs
            // to the SET, so asking the schema about the SESSION's own values
            // would make a session behind an agent set start looking for a
            // secret and count itself in the user-visible "N passwords
            // missing". Only the fallback -- the manual session, which is where
            // `StoredSession.authKind` used to be read -- becomes a schema
            // question. The `.agent` comparison on `ResolvedLogin` stays: that
            // type is SSH-shaped on purpose since M22/T9, and is not one of
            // the placeholder accessors.
            let needsSecret = resolved.map { $0.authKind != .agent }
                ?? (BackendDescriptor.descriptor(for: session.kind)
                        .visibleSecretField(for: session) != nil)
```

und in der Wache `authKind != .agent` durch `needsSecret` ersetzen:

```swift
            if includePasswords, needsSecret, session.kind != .s3,
                session.kind != .webdav || session.webdav != nil {
```

Die beiden `session.kind`-Bedingungen bleiben **unangetastet** (Spec: sie sind
Format-Logik, und M23/P3 hat sie nach einem Befund absichtlich
wiederhergestellt).

- [ ] **Step 5: Grün bestätigen**

Run: `swift test --filter SessionListViewModel`
Expected: PASS.
Run: `swift test`
Expected: alles grün, ≥ 1587.
Run: `swift build`
Expected: sauber inklusive App-Target.

- [ ] **Step 6: Commit**

```bash
git add Sources/macSCPCore/Presentation/SessionListViewModel.swift Tests/macSCPCoreTests/SessionListViewModelTests.swift
git commit -m "refactor(core): ask the schema, not authKind, whether a session has a secret"
```

---

## Task 4: Die Probe und der Abschluss

**Files:**
- Modify: ggf. `Sources/macSCPCore/Sessions/StoredSession.swift` (die vier Accessoren)
- Create: `docs/superpowers/specs/2026-08-08-m25-abschluss.md`

- [ ] **Step 1: Die Probe fahren**

An die vier Accessoren `host`, `port`, `username`, `authKind` in
`StoredSession.swift` vorübergehend anhängen:

```swift
    @available(*, deprecated, message: "M25 probe — every reader must be SSH-guarded")
```

Dann `swift build 2>&1 | grep -A 2 deprecated`. **Ein Compiler-Lauf, kein
`grep` auf `.host`** — M24 hat gezeigt, dass der Grep 241 Treffer liefert, von
denen die meisten URLs und fremde Typen sind.

- [ ] **Step 2: Jeden Treffer beurteilen**

Für jeden gemeldeten Leser entscheiden: **geschützt** (steht hinter
`kind == .ssh`, oder ist `SSHFieldSchema.values(from:)`, der sanktionierte
Leser) oder **ungeschützt**. Die vollständige Liste mit Datei und Zeile kommt
in den Bericht — auch wenn sie leer ist.

- [ ] **Step 3: Entscheiden und ausführen**

- **Alle geschützt** → die vier Accessoren **und** das `@available` löschen,
  dann `swift test` und `swift build` erneut. Bricht etwas, war ein Leser doch
  nicht geschützt: zurücknehmen und wie im anderen Fall berichten.
- **Mindestens einer ungeschützt** → das `@available` wieder entfernen, die
  Accessoren bleiben, und **jeder ungeschützte Leser wird namentlich mit Datei
  und Zeile im Bericht genannt**.

Beides ist ein zulässiges Ergebnis. Die Spec verspricht die Prüfung, nicht die
Löschung — den Ausgang nicht erzwingen.

- [ ] **Step 4: Volle Verifikation**

```bash
swift build
swift test
```
Testzahl notieren (≥ 1587).

Das Docker-Rig aus dem **Haupt-Checkout** starten, nie aus einem Worktree:

```bash
docker compose -f docker/test-server/compose.yml up -d
MACSCP_ITEST=1 swift test
MACSCP_KEYCHAIN=1 swift test --filter Keychain
```

Bleibt ein Lauf bei 0 % CPU stehen, ist das der seit M20 bekannte Hänger
(`docs/superpowers/specs/2026-08-08-testsuite-haenger-untersuchung.md`) —
abbrechen, neu starten, im Bericht vermerken, **nicht** als M25-Befund zählen.
Danach prüfen, dass kein Waisenprozess zurückblieb: `pgrep -fl swiftpm-testing-helper`.

Kataloge:
```bash
for f in Sources/MacSCPApp/Resources/*.lproj/Localizable.strings Sources/macSCPCore/Resources/*.lproj/Localizable.strings; do plutil -lint "$f"; done
```

- [ ] **Step 5: Den Abschlussbericht schreiben**

`docs/superpowers/specs/2026-08-08-m25-abschluss.md`, Form von
`2026-08-08-m24-abschluss.md` kopieren. Muss enthalten: die Verifikation
(Testzahlen, gegatete Läufe, Kataloge); die sieben Erfolgskriterien der Spec
mit **Beleg statt Behauptung**; das vollständige Ergebnis der Probe; jeden
Befund aus Task 1 Step 4 und Task 3 Step 2; was offen bleibt; und die Zahl der
unversendeten Commits (`git rev-list --count origin/develop..develop`).

- [ ] **Step 6: Commit, nicht pushen**

```bash
git add docs/superpowers/specs/2026-08-08-m25-abschluss.md
git commit -m "docs(m25): record the milestone close"
```

Der Push erfolgt ausschließlich auf ausdrückliche Anordnung des Maintainers.

---

## Selbstreview des Plans

**Spec-Abdeckung.** Kriterium 1 → T1; 2 → T1/Step 4 (Regressionsklammer);
3 → T3; 4 → T3 (der set-gebundene Agent-Export); 5 → T2/Step 4; 6 → T4;
7 → T4/Step 4. Das neue Descriptor-Mitglied → T2. Die bewusst nicht
angetasteten Format-Wachen sind eine Unterlassung und stehen als solche in
T3/Step 4.

**Typkonsistenz.** `visibleSecretField(for session: StoredSession) ->
ConnectionField?` wird in T2 definiert und in T2/Step 4, T3/Step 3 und
T3/Step 4 genau so aufgerufen. `BackendDescriptor.descriptor(for:)` ist die
bestehende Registry-Funktion.

**Eine bewusste Abweichung von der Skill-Vorgabe:** Testcode steht als Tabelle
statt als Quelltext, mit Zeiger auf die zu kopierende Form. Begründung oben im
eigenen Abschnitt.

**Eine bewusste Ausnahme von einer eigenen Regel:** der Test
`anSSHSessionWithoutItsBlockStillShowsAPasswordField` baut `StoredSession`
direkt statt über eine Fixture, weil keine Fixture einen blocklosen Zustand
erzeugt. Der Test kommentiert das.
