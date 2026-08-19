# M30 — Abgestandener Session-Slot beim Login-Set-Wechsel: Implementierungsplan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Beim Verlassen des Login-Set-Modus bedeutet ein leeres Geheimfeld
nicht mehr „unverändert", sondern ist ein Validierungsfehler — damit kann ein
altes Passwort nicht stillschweigend wieder aktiv werden.

**Architecture:** Eine einzige Änderung an zwei Aufrufen in
`ConnectionViewModel.validateForEditSave()`: das bisher feste
`requireSecrets: false` bzw. `requireSecret: false` wird aus dem Übergang
abgeleitet (vorher an ein Set gebunden, jetzt manuell). Die Meldung liefert
der vorhandene Validator aus der Felddeklaration. **Es wird nichts gelöscht**
— der getippte Wert überschreibt den alten Slot über den vorhandenen
Schreibpfad.

**Tech Stack:** Swift 6 (`.swiftLanguageMode(.v5)`), SwiftPM, macOS 15+,
Swift Testing (`@Test`/`#expect`).

**Spec:** `docs/superpowers/specs/2026-08-19-m30-abgestandener-session-slot-design.md`

## Global Constraints

- Code, Kommentare, Testnamen, Commit-Messages: **Englisch**. Interne Doku
  (`docs/`) darf Deutsch bleiben.
- Conventional Commits, Footer auf jedem Commit:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- **Kein Geheimnis darf je in eine Fehlermeldung geraten**, auch nicht in
  eine Testmeldung: `#expect` expandiert seinen Ausdruck, also erst in ein
  `Bool` heben und dieses prüfen.
- **Diese Änderung enthält keinen `delete`-Aufruf.** Wer beim Umsetzen einen
  braucht, hat den Entwurf verlassen und meldet das, statt ihn einzubauen.
- Neue Logik kommt mit Tests, TDD rot→grün. Suite: `swift test`.
- **Die Prosa dieses Plans ist eine zu prüfende Behauptung, kein Befund.**
  Wenn eine hier behauptete Signatur, ein Feldname oder ein Meldungsschlüssel
  nicht stimmt: melden, nicht stillschweigend umbauen.

## Dateien

| Datei | Rolle in diesem Plan |
|---|---|
| `Sources/macSCPCore/Presentation/ConnectionViewModel.swift` | trägt `validateForEditSave()`; hier sitzt die ganze Verhaltensänderung |
| `Tests/macSCPCoreTests/ConnectionViewModelTests.swift` | die Validierungs-Tests, Task 1 und 2 |
| `Tests/macSCPCoreTests/SessionListViewModelTests.swift` | der eine Test, der das Überschreiben des Slots festhält (Task 1) |

Keine neuen Dateien, keine neuen Typen, keine neuen L10n-Schlüssel: die
Meldungen `core.connect.passwordEmpty` und `core.connect.jumpPasswordEmpty`
sind bereits deklariert und übersetzt.

---

### Task 1: Die Regel für die Sitzung

**Files:**
- Modify: `Sources/macSCPCore/Presentation/ConnectionViewModel.swift` (in `validateForEditSave()`, am `descriptor.firstViolation`-Aufruf)
- Test: `Tests/macSCPCoreTests/ConnectionViewModelTests.swift`
- Test: `Tests/macSCPCoreTests/SessionListViewModelTests.swift`

**Interfaces:**
- Consumes: `BackendDescriptor.firstViolation(in:requireSecrets:)`, `ConnectionViewModel.editingOriginal`, `ConnectionViewModel.loginMode`, die Fixture `sshSession(name:host:username:authKind:keyPath:loginSetID:jump:)` aus `Tests/macSCPCoreTests/SessionFixtures.swift`
- Produces: nichts Neues — Task 2 ändert dieselbe Funktion an der Zeile darunter

- [ ] **Step 1: Die fünf fehlschlagenden Tests schreiben**

Ans Ende von `ConnectionViewModelTests` einfügen. `beginEditing` setzt
`loginMode` aus `stored.loginSetID`; die Zeile `vm.loginMode = .manual`
bildet also genau den Griff des Nutzers zum Umschalter nach.

```swift
    /// M30: Set-Modus zu verlassen ist der eine Moment, in dem ein leeres
    /// Geheimfeld NICHT "unverändert lassen" heißt. Ohne diese Regel bleibt
    /// das Passwort der vorherigen Konfiguration im Schlüsselbund stehen und
    /// wird beim nächsten Connect stillschweigend wieder benutzt.
    ///
    /// Die Gegenrichtung — eine manuelle Sitzung, die den Modus gar nicht
    /// wechselt — hält `validateForEditSaveAllowsEmptyPasswordAndBuildsTheSession`
    /// weiter oben in dieser Datei fest. Zusammen nageln die beiden die Regel
    /// in beide Richtungen fest: ein hart verdrahtetes `true` oder `false`
    /// macht je einen von ihnen rot.
    @Test @MainActor func leavingLoginSetModeWithAnEmptyPasswordIsRefused() {
        let vm = makeVM()
        vm.beginEditing(sshSession(name: "web", host: "h", username: "u",
                                   loginSetID: UUID()))
        vm.loginMode = .manual
        vm.password = ""

        #expect(vm.validateForEditSave() == nil)
        #expect(vm.state == .failed(
            message: CoreL10n.string("core.connect.passwordEmpty"),
            field: .schema("\(SSHField.namespace).\(SSHField.password.rawValue)")))
    }

    @Test @MainActor func leavingLoginSetModeWithATypedPasswordSaves() {
        let vm = makeVM()
        vm.beginEditing(sshSession(name: "web", host: "h", username: "u",
                                   loginSetID: UUID()))
        vm.loginMode = .manual
        vm.password = "typed"

        let result = vm.validateForEditSave()
        #expect(result?.loginSetID == nil)
        #expect(vm.state == .idle)
    }

    /// Falschablehnungs-Wächter. Die SSH-Passphrase ist in
    /// `SSHFieldSchema.credential` ausdrücklich NICHT als erforderlich
    /// deklariert — ein unverschlüsselter Schlüssel hat keine. Wird sie das
    /// eines Tages, fällt es hier auf statt beim Nutzer.
    @Test @MainActor func leavingLoginSetModeWithAKeyLoginNeedsNoPassphrase() {
        let vm = makeVM()
        vm.beginEditing(sshSession(name: "web", host: "h", username: "u",
                                   authKind: .privateKey, keyPath: "/k",
                                   loginSetID: UUID()))
        vm.loginMode = .manual
        vm.password = ""

        #expect(vm.validateForEditSave() != nil)
    }

    /// Zweiter Falschablehnungs-Wächter: ein Agent-Login zeigt überhaupt kein
    /// Geheimfeld, `requireSecrets` hat dort also nichts zu verlangen.
    @Test @MainActor func leavingLoginSetModeWithAnAgentLoginNeedsNoSecret() {
        let vm = makeVM()
        vm.beginEditing(sshSession(name: "web", host: "h", username: "u",
                                   authKind: .agent, loginSetID: UUID()))
        vm.loginMode = .manual
        vm.password = ""

        #expect(vm.validateForEditSave() != nil)
    }

    /// Von einem Set auf ein anderes zu wechseln ist kein Verlassen: es gibt
    /// keinen manuellen Modus, in dem ein alter Slot wieder aktiv werden
    /// könnte.
    @Test @MainActor func switchingBetweenLoginSetsNeedsNoSecret() {
        let vm = makeVM()
        vm.beginEditing(sshSession(name: "web", host: "h", username: "u",
                                   loginSetID: UUID()))
        vm.selectedLoginSetID = UUID()
        vm.password = ""

        #expect(vm.validateForEditSave() != nil)
    }
```

- [ ] **Step 2: Den sechsten Test schreiben — das Überschreiben**

In `SessionListViewModelTests` einfügen. Er hält die zweite Hälfte der
Zusicherung fest: der getippte Wert ersetzt den alten Slot wirklich, statt
neben ihm zu landen. Ohne ihn beweist Task 1 nur, dass gespeichert werden
*darf*.

Das Geheimnis wird in ein `Bool` gehoben, bevor `#expect` es sieht — die
Makro-Expansion druckt sonst den Wert in die Fehlermeldung.

```swift
    /// M30: der beim Verlassen des Set-Modus verlangte Wert muss den alten
    /// Slot ERSETZEN. Sonst wäre die neue Validierungsregel wirkungslos --
    /// der Nutzer tippt ein Passwort und das alte bliebe trotzdem stehen.
    @Test func aNewSecretOnEditReplacesTheStoredOne() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = sshSession(name: "web", host: "h", username: "u")
        try secrets.savePassword("old", for: session.id)

        vm.updateSession(session, newSecret: "new")

        // Hoisted into a Bool first: `#expect` expands its receiver, and a
        // secret must never reach a failure message.
        let replaced = try secrets.password(for: session.id) == "new"
        #expect(replaced)
    }
```

- [ ] **Step 3: Tests laufen lassen, Rot bestätigen**

```bash
swift test --filter "leavingLoginSetModeWithAnEmptyPasswordIsRefused"
```

Erwartet: FAIL — `validateForEditSave()` liefert heute eine Sitzung statt
`nil`, weil `requireSecrets` fest auf `false` steht. Die vier anderen neuen
Tests aus Step 1 und der aus Step 2 sind bereits grün; sie sind die
Kontrollen, die die Regel eingrenzen, nicht die Treiber.

- [ ] **Step 4: Die Regel einbauen**

In `validateForEditSave()`, unmittelbar vor dem `descriptor.firstViolation`-
Aufruf. `editingOriginal` statt der lokalen Kopie `session`: die Kopie wird
weiter unten mutiert, und eine künftige Umstellung dieser Reihenfolge würde
die Frage sonst still verfälschen.

```swift
        let descriptor = BackendDescriptor.descriptor(for: kind)
        // M30: leaving Set mode is the one moment where an empty secret field
        // does NOT mean "leave the stored one unchanged". The stored one
        // belongs to a configuration the user is walking away from, so letting
        // it stand silently reactivates it on the next connect. Demanding the
        // secret here makes the write path overwrite that slot, which is why
        // this fix deletes nothing -- every earlier attempt deleted on BINDING
        // instead and was reverted, four times, for destroying the only copy
        // of a credential.
        //
        // Read from `editingOriginal`, not from the local `session` copy: that
        // copy is mutated further down, and reordering those mutations would
        // otherwise change this answer without touching this line.
        let leftLoginSet = editingOriginal?.loginSetID != nil && loginMode == .manual
        if let violation = descriptor.firstViolation(in: values, requireSecrets: leftLoginSet) {
```

- [ ] **Step 5: Tests laufen lassen, Grün bestätigen**

```bash
swift test --filter "ConnectionViewModelTests|SessionListViewModelTests"
```

Erwartet: PASS, alle sechs neuen Tests plus die bestehenden derselben
Dateien.

- [ ] **Step 6: Volle Suite**

```bash
swift test
```

Erwartet: PASS. Sollte ein bestehender Test rot werden, ist das ein Befund
über den Umfang der Regel und gehört gemeldet — nicht durch Anpassen des
alten Tests entschärft.

- [ ] **Step 7: Commit**

```bash
git add Sources/macSCPCore/Presentation/ConnectionViewModel.swift Tests/macSCPCoreTests/ConnectionViewModelTests.swift Tests/macSCPCoreTests/SessionListViewModelTests.swift
git commit -m "fix(core): demand the secret when a session leaves its login set

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Die Jump-Symmetrie

**Files:**
- Modify: `Sources/macSCPCore/Presentation/ConnectionViewModel.swift` (in `validateForEditSave()`, am `validateJump`-Aufruf direkt unter Task 1s Änderung)
- Test: `Tests/macSCPCoreTests/ConnectionViewModelTests.swift`

**Interfaces:**
- Consumes: `ConnectionViewModel.validateJump(requireSecret:)` — der Parameter existiert bereits und wird heute mit `false` aufgerufen; `StoredSession.JumpSpec(host:port:username:authKind:keyPath:loginSetID:secretID:sessionID:)`
- Produces: nichts — letzte Codeänderung des Plans

- [ ] **Step 1: Die zwei fehlschlagenden Tests schreiben**

Die Sitzung selbst bleibt in beiden manuell und ungebunden, damit allein die
Jump-Regel geprüft wird. `beginEditing` setzt `jumpLoginMode` aus
`jump.loginSetID`, genau wie `loginMode` aus dem der Sitzung.

```swift
    /// M30, die Jump-Hälfte derselben Regel: der Jump hat einen eigenen
    /// Schlüsselbund-Slot und dieselbe Set-Bindung, also auch denselben
    /// Rückweg, auf dem ein altes Geheimnis stillschweigend wieder aktiv
    /// würde. Die Sitzung bleibt hier ungebunden, damit der Test die
    /// Jump-Regel allein prüft und nicht die aus Task 1 mitmisst.
    @Test @MainActor func aJumpLeavingLoginSetModeWithAnEmptyPasswordIsRefused() {
        let vm = makeVM()
        vm.beginEditing(sshSession(
            name: "web", host: "h", username: "u",
            jump: StoredSession.JumpSpec(host: "bastion", username: "j",
                                         loginSetID: UUID())))
        vm.jumpLoginMode = .manual
        vm.jumpPassword = ""

        #expect(vm.validateForEditSave() == nil)
        #expect(vm.state == .failed(
            message: CoreL10n.string("core.connect.jumpPasswordEmpty"),
            field: .jumpPassword))
    }

    @Test @MainActor func aJumpLeavingLoginSetModeWithATypedPasswordSaves() {
        let vm = makeVM()
        vm.beginEditing(sshSession(
            name: "web", host: "h", username: "u",
            jump: StoredSession.JumpSpec(host: "bastion", username: "j",
                                         loginSetID: UUID())))
        vm.jumpLoginMode = .manual
        vm.jumpPassword = "typed"

        #expect(vm.validateForEditSave() != nil)
        #expect(vm.state == .idle)
    }
```

- [ ] **Step 2: Tests laufen lassen, Rot bestätigen**

```bash
swift test --filter "aJumpLeavingLoginSetModeWithAnEmptyPasswordIsRefused"
```

Erwartet: FAIL — `validateJump` wird heute fest mit `requireSecret: false`
gerufen.

- [ ] **Step 3: Die Regel einbauen**

Der bestehende Kommentar über dem Aufruf („requireSecret: false for the same
reason as above") wird ersetzt, weil er nach dieser Änderung nicht mehr
stimmt — der Wert ist keine Konstante mehr.

```swift
        // M30: the jump's own half of the rule above. Its `loginSetID` and
        // its `secretID` slot mirror the session's, so it has the same way
        // back into a stale credential. A session-mode jump cannot reach this
        // at all -- `validateJump` returns early for it and such a jump owns
        // no secret.
        let jumpLeftLoginSet = editingOriginal?.jump?.loginSetID != nil && jumpLoginMode == .manual
        if let jumpFailure = validateJump(requireSecret: jumpLeftLoginSet) {
            state = jumpFailure
            return nil
        }
```

- [ ] **Step 4: Tests laufen lassen, Grün bestätigen**

```bash
swift test --filter "ConnectionViewModelTests"
```

Erwartet: PASS.

- [ ] **Step 5: Volle Suite**

```bash
swift test
```

Erwartet: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/macSCPCore/Presentation/ConnectionViewModel.swift Tests/macSCPCoreTests/ConnectionViewModelTests.swift
git commit -m "fix(core): demand the jump's secret when it leaves its login set

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Abschluss

**Files:**
- Create: `docs/superpowers/specs/2026-08-19-m30-abschluss.md`

**Interfaces:**
- Consumes: die Commits aus Task 1 und 2
- Produces: nichts

- [ ] **Step 1: Volle Suite, Ausgabe lesen BEVOR committet wird**

```bash
swift test
```

Die Zahl der Tests und Suiten notieren. (Frühere Phase hat einen roten Test
mitcommittet, weil Lauf und Commit im selben Befehl standen — deshalb hier
getrennt.)

- [ ] **Step 2: Prüfen, dass die Änderung wirklich nichts löscht**

```bash
git diff origin/develop..HEAD -- Sources/ | grep -n "deletePassword" || echo "kein deletePassword im Diff"
```

Erwartet: `kein deletePassword im Diff`. Das ist die zentrale Zusicherung
der Spec — sie wird geprüft, nicht behauptet.

- [ ] **Step 3: Abschlussbericht schreiben**

`docs/superpowers/specs/2026-08-19-m30-abschluss.md`, Deutsch, mit: was
umgesetzt wurde, das Ergebnis von Step 2, die Suite-Zahlen aus Step 1, und
ausdrücklich was offen bleibt (Schaden 1 — der Slot einer Sitzung, die
gebunden IST, sowie `applyMerge` und die Jump-Bindung, die mit `try?` lesen
und trotzdem löschen).

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/specs/2026-08-19-m30-abschluss.md
git commit -m "docs(m30): record the close

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```
