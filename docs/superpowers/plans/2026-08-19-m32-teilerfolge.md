# M32 — Teilerfolge, die trotzdem löschen: Implementierungsplan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Ein fehlgeschlagener Store-Write in `applyMerge` darf das
Geheimnis der betroffenen Sitzung nicht mehr löschen.

**Architecture:** `try? store.upsert` wird zu `do/catch`; die Löschung des
Slots hängt am Erfolg des Writes. Die Schleife läuft für die übrigen
Mitglieder weiter, und eine Meldung sagt, dass Sitzungen ihr eigenes
Passwort behalten haben.

**Tech Stack:** Swift 6 (`.swiftLanguageMode(.v5)`), SwiftPM, macOS 15+,
Swift Testing.

**Spec:** `docs/superpowers/specs/2026-08-19-m32-teilerfolge-design.md`

## Global Constraints

- Code, Kommentare, Testnamen, Commit-Messages **Englisch**; Doku Deutsch.
- Conventional Commits, Footer:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- Nutzer-sichtbare Strings über `CoreL10n.string`, in **allen vier**
  Sprachen unter `Sources/macSCPCore/Resources/<lang>.lproj/`.
- **Kein Geheimnis in einer Meldung**, auch nicht in einer Test-Meldung:
  erst in ein `Bool` heben, dann prüfen.
- TDD rot→grün. Suite: `swift test`.
- **Die Prosa dieses Plans ist eine zu prüfende Behauptung.** Stimmt etwas
  nicht: melden, nicht still umbauen.

## Was der Test wissen muss

Zwei gemessene Eigenschaften, ohne die der Test nicht funktioniert:

1. **`SessionStore.persist` schreibt mit `options: .atomic`.** Ein
   schreibgeschütztes `sessions.json` nützt deshalb nichts — der atomare
   Write legt eine Temp-Datei an und benennt sie um, wofür nur das
   **Verzeichnis** beschreibbar sein muss. Gesperrt wird also das
   Verzeichnis.
2. **`applyMerge` schreibt ZUERST das Login-Set.** Läge es im selben
   gesperrten Verzeichnis, schlüge dieser Write zuerst fehl und die Funktion
   kehrte zurück, bevor die Schleife läuft. Der Test gibt den beiden Stores
   deshalb **getrennte Verzeichnisse**.

---

### Task 1: Die Löschung an den Erfolg des Writes koppeln

**Files:**
- Modify: `Sources/macSCPCore/Presentation/SessionListViewModel.swift` (Rewire-Schleife in `applyMerge`, plus deren Doc-Kommentar)
- Modify: `Sources/macSCPCore/Resources/{en,de,fr,pl}.lproj/Localizable.strings`
- Test: `Tests/macSCPCoreTests/SessionListViewModelTests.swift`

**Interfaces:**
- Consumes: `SessionListViewModel.applyMerge(_:name:)`, `InMemorySecretStore`
- Produces: nichts

- [ ] **Step 1: Die zwei Tests schreiben**

Ans Ende von `SessionListViewModelTests`. Der zweite ist die
Positivkontrolle: ohne ihn bliebe der erste auch dann grün, wenn
`applyMerge` überhaupt nichts mehr löscht.

```swift
    /// M32: a failed session write must not take the session's secret with
    /// it. Before this, the loop rewired and deleted with two `try?` in a
    /// row, so a store that refused the write left the session unbound --
    /// still reading its own slot -- and deleted exactly that slot.
    ///
    /// The failure is PRODUCED, not simulated: the session directory is made
    /// read-only, so `upsert` genuinely fails. `SessionStore.persist` writes
    /// with `.atomic`, which renames a temp file into place, so locking the
    /// FILE would not do it -- the directory has to go. The login-set store
    /// gets its own writable directory, because `applyMerge` writes the set
    /// first and would otherwise fail before reaching the loop.
    @Test func aFailedRewireKeepsTheSessionsOwnSecret() throws {
        let sessionDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-m32-sessions-\(UUID().uuidString)")
        let loginDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macscp-m32-logins-\(UUID().uuidString)")
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: sessionDir.path)
            try? FileManager.default.removeItem(at: sessionDir)
            try? FileManager.default.removeItem(at: loginDir)
        }
        let secrets = InMemorySecretStore()
        let vm = SessionListViewModel(
            store: SessionStore(directory: sessionDir), secrets: secrets,
            loginSetStore: LoginSetStore(directory: loginDir))

        let stored = vm.save(
            name: "web",
            values: sshValues(host: "h", port: 22, username: "u"),
            password: "the-only-copy")!

        // Lock the directory only AFTER the session exists, or there would be
        // nothing to merge.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: sessionDir.path)

        let candidate = LoginMergeCandidate(
            kind: .ssh, values: sshValues(host: "h", port: 22, username: "u"),
            sessionIDs: [stored.id])
        _ = vm.applyMerge(candidate, name: "Shared")

        // Hoisted into a Bool first: `#expect` expands its receiver, and a
        // secret must never reach a failure message.
        let keptItsSecret = try secrets.password(for: stored.id) == "the-only-copy"
        #expect(keptItsSecret)
    }

    /// Positive control for the test above: with a writable directory the
    /// merge does its job -- the session is rewired and its own slot goes.
    /// Without this, a version of `applyMerge` that deleted nothing at all
    /// would satisfy the first test.
    @Test func asuccessfulRewireStillTakesTheSessionsOwnSecret() throws {
        let (vm, secrets, dir) = makeVM()
        defer { try? FileManager.default.removeItem(at: dir) }

        let stored = vm.save(
            name: "web",
            values: sshValues(host: "h", port: 22, username: "u"),
            password: "carried")!
        let candidate = LoginMergeCandidate(
            kind: .ssh, values: sshValues(host: "h", port: 22, username: "u"),
            sessionIDs: [stored.id])

        let set = vm.applyMerge(candidate, name: "Shared")

        #expect(set != nil)
        let slotIsGone = try secrets.password(for: stored.id) == nil
        #expect(slotIsGone)
        #expect(vm.sessions.first { $0.id == stored.id }?.loginSetID == set?.id)
    }
```

- [ ] **Step 2: Tests laufen lassen, Rot bestätigen**

```bash
swift test --filter "aFailedRewireKeepsTheSessionsOwnSecret"
```

Erwartet: FAIL — das Geheimnis ist weg, obwohl der Write scheiterte.

Schlägt der Test **nicht** fehl, ist die Annahme falsch, dass ein
schreibgeschütztes Verzeichnis `upsert` scheitern lässt: dann misst der Test
nichts und die Ursache gehört gemeldet, nicht umgangen.

- [ ] **Step 3: Die Schleife umbauen**

```swift
        var unlinkedCount = 0
        for session in groupSessions {
            var updated = session
            updated.loginSetID = set.id
            do {
                try store.upsert(updated)
            } catch {
                // M32: the delete below hangs on THIS write. Without that, a
                // refused write left the session unbound -- still resolving
                // its login from its own slot -- and then deleted exactly
                // that slot, leaving it with no credential at all. Skipping
                // both keeps this member exactly as it was; the others are
                // unaffected, which is why the loop continues rather than
                // aborting.
                unlinkedCount += 1
                continue
            }
            try? secrets.deletePassword(for: session.id)
        }
        if unlinkedCount > 0 {
            errorMessage = CoreL10n.string("core.login.mergePartial")
        }
```

Und im Doc-Kommentar der Funktion den Satz

```
    /// is rewired and has its own secret deleted in the same iteration —
    /// both are `try?`, so a store-write failure for one session does not
    /// stop that session's secret from being deleted.
```

ersetzen durch

```
    /// is rewired and, ONLY if that write succeeded, has its own secret
    /// deleted in the same iteration (M32). A member whose write fails keeps
    /// both its binding and its secret and is reported; the others still
    /// merge.
```

- [ ] **Step 4: Die Meldung in allen vier Sprachen anlegen**

In `Sources/macSCPCore/Resources/<lang>.lproj/Localizable.strings`, neben
`core.login.mergeFailed`:

```
en: "core.login.mergePartial" = "Some sessions could not be linked to the new login set. They kept their own password.";
de: "core.login.mergePartial" = "Einige Sitzungen konnten nicht mit dem neuen Login-Set verknüpft werden. Sie haben ihr eigenes Passwort behalten.";
fr: "core.login.mergePartial" = "Certaines sessions n’ont pas pu être liées au nouveau jeu d’identifiants. Elles ont conservé leur propre mot de passe.";
pl: "core.login.mergePartial" = "Niektórych sesji nie udało się powiązać z nowym zestawem logowania. Zachowały własne hasło.";
```

- [ ] **Step 5: Tests laufen lassen, Grün bestätigen**

```bash
swift test --filter "SessionListViewModelTests"
```

- [ ] **Step 6: Volle Suite**

```bash
swift test
```

Erwartet: PASS. Ein rot werdender Bestandstest ist ein Befund über den
Umfang der Regel und gehört gemeldet.

- [ ] **Step 7: Commit**

```bash
git add Sources/macSCPCore Tests/macSCPCoreTests/SessionListViewModelTests.swift
git commit -m "fix(core): keep a session's secret when its merge write fails

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Abschluss

**Files:**
- Create: `docs/superpowers/specs/2026-08-19-m32-abschluss.md`

- [ ] **Step 1: Volle Suite, Ausgabe lesen BEVOR committet wird**

```bash
swift test
```

- [ ] **Step 2: Prüfen, dass kein `try?`-Paar mehr in der Schleife steht**

```bash
awk '/for session in groupSessions/,/^        \}$/' Sources/macSCPCore/Presentation/SessionListViewModel.swift | grep -c "try? store.upsert"
```

Erwartet: `0`. Positivkontrolle, damit ein leerer `awk`-Ausschnitt nicht als
Erfolg durchgeht:

```bash
awk '/for session in groupSessions/,/^        \}$/' Sources/macSCPCore/Presentation/SessionListViewModel.swift | grep -c "deletePassword"
```

Erwartet: mindestens 1 — sonst hat der Ausschnitt die Schleife nicht
getroffen und die erste Zahl bedeutet nichts.

- [ ] **Step 3: Abschlussbericht schreiben**

`docs/superpowers/specs/2026-08-19-m32-abschluss.md`, Deutsch: was umgesetzt
wurde, das Ergebnis von Step 2, die Suite-Zahlen, und ausdrücklich, dass
drei der fünf geerbten Backlog-Punkte sich bei der Messung auflösten —
einer davon erst, nachdem die Spec ihn bereits als offen geführt hatte.

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/specs/2026-08-19-m32-abschluss.md
git commit -m "docs(m32): record the close

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```
