# M28 — Die zwei löschenden Binder: Implementierungsplan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Die zwei Stellen, die beim Binden an ein Login-Set einen
Schlüsselbund-Slot löschen, hören auf, das ohne Bedingung zu tun.

**Architecture:** Eine Deckungsfrage in Core beantwortet „hält dieses Set,
was ein daran gebundener Login braucht" über das Schema. Die Jump-Bindung
stellt sie vor dem Löschen. `applyMerge` braucht sie **nicht** — dort ist der
Defekt ein anderer (siehe unten). Dazu meldet der Login-Set-Import, wenn Sets
ohne Passwort ankommen.

**Tech Stack:** Swift 6, `.swiftLanguageMode(.v5)`, SwiftPM, macOS 15+,
Swift Testing, SwiftUI.

Spec: `../specs/2026-08-09-m28-loeschende-binder-design.md`

## Abweichung von der Spec, ausgewiesen statt geglättet

Die Spec formuliert **eine** Regel für beide Binder. Beim Planen hält das
nicht: die zwei Defekte sind verschieden.

- **Die Jump-Bindung** löscht einen Slot, den **nichts überträgt** — der alte
  Bastion-Slot ist die einzige Kopie. Dort ist die Deckungsfrage die richtige:
  hält das neue Set etwas, oder braucht es nichts?
- **`applyMerge`** überträgt sehr wohl — es liest ein Mitglieds-Secret und
  schreibt es aufs Set. Sein Defekt ist nicht die fehlende Frage, sondern der
  **verschluckte Read**: `try?` macht aus „nicht lesbar" ein „nichts da", und
  danach wird gelöscht. Die Deckungsfrage würde daran nichts verbessern; ein
  **werfender** Read schon: nicht lesbar ⇒ Abbruch, wirklich leer ⇒ es gibt
  nichts zu verlieren, und das Löschen leerer Slots ist folgenlos.

Beide Fixes stehen im Plan, mit ihrer je eigenen Begründung. Die Spec bleibt
in der Sache richtig — ihre Verallgemeinerung war eine Ebene zu grob.

**Zweite Abweichung — und ihre Korrektur nach der Task-1-Review.** Die Spec
nennt die Managed-Key-Probe als Sonderfall, den das Schema nicht beantworten
kann. Der Plan hat daraus zunächst geschlossen, sie werde gar nicht gebraucht.
**Das war zu breit, und die Task-1-Review hat es gefangen:**

- Für die **Deckungsfrage selbst** stimmt es: ein `.privateKey`-Set zeigt
  `passphrase`, das Feld ist nicht `isRequired`, der „nicht erforderlich ⇒
  gedeckt"-Zweig trägt den Fall. Task 1 braucht keine
  `ManagedKeyStore`-Abhängigkeit und hat keine.
- Für die **Löschentscheidung** stimmt es **nicht**. Ein Binder, der allein auf
  dieser Antwort löscht, entfernt den Passphrase-Slot einer Sitzung, deren
  Schlüssel verschlüsselt ist und deren Set nichts hält — die Passphrase ist
  dann nirgends mehr. Die Deckungsfrage sagt „braucht das Set ein Secret", nicht
  „verliert der Login etwas, das er braucht".

**Task 3 kombiniert deshalb beide Fragen**, und die Probe wirft weiterhin,
statt zu raten. Task 2 ist davon unberührt: dort wird übertragen, nicht
gedeckt.

## Global Constraints

- **Code, Kommentare, Bezeichner, Testnamen: nur Englisch.** Interne Doku
  Deutsch.
- **Ein Secret-Wert wird nie gedruckt, geloggt oder in einen Fehler
  eingebettet — auch nicht in eine Testfehlermeldung.**
- **Kein `try?`-Read entscheidet über eine Löschung.** Ein werfender Read
  bricht ab. Eine unbeantwortbare Deckungsfrage löscht nicht.
- **Die Deckungsfrage stellt nie `LoginSet.authKind`.** `authKind` und `kind`
  sind unabhängig und werden vom Import wörtlich übernommen.
- Das `SecretStore`-Protokoll bekommt **kein** neues Mitglied.
- Der veraltete Slot einer set-gebundenen Sitzung wird **nicht** gelöscht;
  die drei nicht löschenden Binder bleiben unberührt.
- App-UI über alle vier Kataloge en/de/fr/pl mit identischen Schlüsselmengen.
- Conventional Commits, englische Nachricht, Footer auf jedem Commit:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- **Nicht pushen.** Die GUI nicht starten. `scripts/release` nicht ausführen.
- Testzahl-Basis: **1640**.

---

### Task 1: Die Deckungsfrage

**Files:**
- Modify: `Sources/macSCPCore/Capabilities/BackendDescriptor.swift`
- Modify: `Sources/macSCPCore/Presentation/SessionListViewModel.swift`
- Test: `Tests/macSCPCoreTests/BackendDescriptorTests.swift`,
  `Tests/macSCPCoreTests/SessionListViewModelTests.swift`

**Interfaces:**
- Produces: `BackendDescriptor.visibleSecretField(for set: LoginSet) -> ConnectionField?`
  — der Zwilling zur vorhandenen `StoredSession`-Fassung, über
  `loginSetValues(_:)` statt `sessionValues(_:)`.
- Produces: `SessionListViewModel.setCoversItsLogin(_ set: LoginSet) throws -> Bool`
  — `true`, wenn das Set kein Secret braucht **oder** eines hält. **Wirft**,
  wenn der Schlüsselbund nicht antwortet.

- [ ] **Step 1: Die Tests schreiben**

Für den Zwilling, in `BackendDescriptorTests`:

```swift
/// The LoginSet twin of the StoredSession question. Both ask
/// `visibleSecretField` over the same schema; only the value source differs.
@Test func aPasswordLoginSetShowsItsPasswordField() throws { … }
@Test func anAgentLoginSetShowsNoSecretField() throws { … }
@Test func aPrivateKeyLoginSetShowsAnOptionalPassphraseField() throws { … }
```

Für die Deckungsfrage, in `SessionListViewModelTests` — **eine je Zeile der
Spec-Tabelle**, das ist Erfolgskriterium 4:

```swift
@Test func aPasswordSetWithoutASecretIsNotCovered() throws { … }
@Test func aPasswordSetHoldingASecretIsCovered() throws { … }
@Test func anAgentSetIsCoveredWithoutReadingTheKeychain() throws { … }
@Test func aPrivateKeySetIsCoveredWithoutASetSecret() throws { … }
@Test func anS3SetWithoutASecretIsNotCovered() throws { … }
@Test func aWebDAVSetIsCoveredWithoutASecret() throws { … }
```

Dazu die zwei, an denen der letzte Anlauf gescheitert wäre:

```swift
/// Erfolgskriterium 5, der wichtigste Test dieses Meilensteins. `kind` and
/// `authKind` are independent columns and the login-set importer copies both
/// verbatim, so a set can declare S3 storage with agent auth. Asking
/// `authKind` would call this covered and delete a session's only secret
/// access key. Asking the schema does not.
@Test func anS3SetDeclaringAgentAuthIsStillNotCovered() throws { … }

/// A keychain that will not answer is not an empty one. Everything in M28
/// hangs on this: the two deleting binders decide from this answer.
@Test func anUnreadableKeychainMakesCoverageThrowRatherThanFalse() throws { … }
```

`anAgentSetIsCoveredWithoutReadingTheKeychain` braucht ein Double, dessen
`password(for:)` den Test scheitern lässt — das Muster steht mehrfach im Repo.

- [ ] **Step 2: Rot sehen**

```bash
swift test --filter Covered
swift test --filter LoginSetShows
```
Erwartet: FAIL, die Member existieren nicht.

- [ ] **Step 3: Den Zwilling umsetzen**

In `BackendDescriptor`, neben `visibleSecretField(for session:)`:

```swift
/// The login set's currently visible secret field, or nil when the set needs
/// no secret at all.
///
/// The twin of the `StoredSession` question above, over `loginSetValues`
/// instead of `sessionValues`. Both exist because "which field is the secret
/// right now" is a schema question, and a login set answers it from its own
/// values -- never from `LoginSet.authKind`, which is a separate column from
/// `kind` and is copied verbatim out of an imported file, so the two can
/// disagree.
public func visibleSecretField(for set: LoginSet) -> ConnectionField? {
    credentialSchema.visibleSecretField(
        in: loginSetValues(set), namespace: fieldNamespace)
}
```

- [ ] **Step 4: Die Deckungsfrage umsetzen**

In `SessionListViewModel`:

```swift
/// Whether `set` holds what a login bound to it will need.
///
/// Two arms, and the order matters: a set whose visible secret field is
/// absent or optional needs nothing, and answering that FIRST is what keeps
/// the Keychain from being read for an agent or key login that has no slot
/// (the M10d rule). Only a set that declares a required secret is asked
/// whether it actually holds one.
///
/// THROWS rather than answering false when the Keychain will not respond. A
/// failed read is not proof of an empty slot, and the callers of this decide
/// whether to delete a credential from its answer -- reading "not covered"
/// out of a locked Keychain would destroy an intact secret.
func setCoversItsLogin(_ set: LoginSet) throws -> Bool {
    let descriptor = BackendDescriptor.descriptor(for: set.kind)
    guard descriptor.visibleSecretField(for: set)?.isRequired == true else { return true }
    return !((try secrets.password(for: set.id)) ?? "").isEmpty
}
```

- [ ] **Step 5: Grün sehen und die Gegenprobe fahren**

```bash
swift test --filter Covered
swift test --filter LoginSetShows
```

Dann, nacheinander, jeweils zurücknehmen:

1. `descriptor.visibleSecretField(for: set)?.isRequired == true` durch
   `set.authKind != .agent` ersetzen → `anS3SetDeclaringAgentAuthIsStillNotCovered`
   muss rot werden. **Das ist der Fehler des letzten Anlaufs**, hiermit
   festgenagelt.
2. `try secrets.password` durch `(try? secrets.password(for: set.id)) ?? nil`
   ersetzen → `anUnreadableKeychainMakesCoverageThrowRatherThanFalse` muss rot
   werden.

Beide Rot-Zustände wörtlich in den Bericht, dann sauber zurücknehmen und
`git status --porcelain` als leer nachweisen.

- [ ] **Step 6: Committen**

```bash
git add Sources/macSCPCore Tests/macSCPCoreTests
git commit -m "feat(core): ask the schema whether a login set holds what it needs"
```

---

### Task 2: `applyMerge` hört auf, „nicht lesbar" für „leer" zu halten

**Files:**
- Modify: `Sources/macSCPCore/Presentation/SessionListViewModel.swift`
- Test: `Tests/macSCPCoreTests/SessionListViewModelTests.swift`

**Interfaces:**
- Consumes: nichts aus Task 1 — siehe die Abweichungsnotiz oben.

- [ ] **Step 1: Die Tests schreiben**

```swift
/// The merge carries one member's secret onto the set and then deletes every
/// member's own slot. A read that FAILS must abort that -- otherwise a locked
/// Keychain looks like a group of empty slots, nothing is carried, no
/// rollback fires, and every member's only copy is deleted.
@Test func anUnreadableMemberSecretRollsTheMergeBackAndDeletesNothing() throws {
    // Double whose password(for:) throws for one member.
    // Expect: set gone from the store, storedIDs unchanged, errorMessage set.
}

/// Genuinely empty slots are not the same case: there is nothing to carry and
/// nothing to lose, so the merge proceeds.
@Test func genuinelyEmptyMemberSlotsStillMerge() throws { … }

/// The carry itself is unchanged: one member's secret lands on the set and
/// the members' own slots go.
@Test func aReadableMemberSecretIsCarriedAndTheOwnSlotsGo() throws { … }
```

- [ ] **Step 2: Rot sehen**

```bash
swift test --filter Merge
```
Erwartet: der erste Test rot — heute wird gelöscht statt abgebrochen.

- [ ] **Step 3: Umsetzen**

Die beiden `try?`-Reads werfen lassen und den Wurf in denselben
Rollback-Zweig führen, den es für den Carry-Fehler schon gibt. Der Kommentar
muss sagen, **warum**, nicht nur was:

```swift
// Both reads throw rather than swallowing: a Keychain that will not answer
// looks exactly like a group of empty slots, and the loop below deletes every
// member's own slot. Reading "nothing to carry" out of a failure would take
// the only copy each member has. A genuinely empty group is a different case
// and still merges -- there is nothing to carry and nothing to lose.
```

Der Rollback-Zweig bleibt, wie er ist: Set löschen, nichts umhängen, nichts
löschen, melden.

- [ ] **Step 4: Grün sehen und die Gegenprobe fahren**

```bash
swift test --filter Merge
```

Gegenprobe: die Reads wieder auf `try?` stellen → der erste Test muss rot
werden, und zwar mit **verschwundenem Credential** (`storedIDs` leer), nicht
bloß mit einem abweichenden Flag. Rot-Ausgabe in den Bericht, zurücknehmen,
`git status --porcelain` leer.

- [ ] **Step 5: Committen**

```bash
git add Sources/macSCPCore Tests/macSCPCoreTests
git commit -m "fix(core): abort the merge on an unreadable secret instead of deleting"
```

---

### Task 3: Die Jump-Bindung fragt, bevor sie löscht

**Files:**
- Modify: `Sources/macSCPCore/Presentation/SessionListViewModel.swift`
  (`cleanOrphanedJumpSlot`)
- Test: `Tests/macSCPCoreTests/SessionListViewModelTests.swift`

**Interfaces:**
- Consumes: `setCoversItsLogin(_:)` aus Task 1.

- [ ] **Step 1: Die Tests schreiben**

```swift
/// Switching a jump from manual to a login set deletes the old bastion slot
/// -- and nothing carries it, so that slot is the only copy. It may only go
/// when the set holds what the jump will need.
@Test func switchingAJumpToASetWithoutASecretKeepsTheBastionSlot() throws { … }
@Test func switchingAJumpToASetThatHoldsItsSecretDropsTheOldSlot() throws { … }
@Test func switchingAJumpToAnAgentSetDropsTheOldSlot() throws { … }

/// An unanswerable Keychain does not delete.
@Test func switchingAJumpWhileTheKeychainIsSilentKeepsTheBastionSlot() throws { … }
```

Die bestehenden `cleanOrphanedJumpSlot`-Tests müssen **unverändert grün
bleiben** — der Manual-zu-Manual-Fall ändert sich nicht.

- [ ] **Step 2: Rot sehen**

```bash
swift test --filter Jump
```

- [ ] **Step 3: Umsetzen**

`cleanOrphanedJumpSlot` bekommt vor dem Löschen die Deckungsfrage. Ist der
neue Jump set-gebunden und das Set **nicht** gedeckt — oder ist die Frage
nicht beantwortbar —, bleibt der Slot.

Die Funktion ist heute wurffrei und wird von `save` und `updateSession`
gerufen; sie bleibt wurffrei. Ein unbeantwortbarer Read heißt hier **nicht
löschen**, nicht **abbrechen**: die Bindung selbst ist in Ordnung, nur die
Aufräumarbeit unterbleibt. Das ist die konservative Richtung, und der
Kommentar muss sagen, dass sie bewusst gewählt ist.

- [ ] **Step 4: Grün sehen und die Gegenprobe fahren**

Wächter entfernen → `switchingAJumpToASetWithoutASecretKeepsTheBastionSlot`
muss rot werden mit weg gelöschtem Slot. Zurücknehmen, Baum sauber nachweisen.

- [ ] **Step 5: Committen**

```bash
git add Sources/macSCPCore Tests/macSCPCoreTests
git commit -m "fix(core): keep the bastion secret when the jump's set holds none"
```

---

### Task 4: Der Import sagt, wenn Sets ohne Passwort ankommen

**Files:**
- Modify: `Sources/macSCPCore/Presentation/SessionListViewModel.swift`
  (das Login-Set-Import-Ergebnis)
- Modify: `Sources/MacSCPApp/LoginSetsSheet.swift` (`importResultText`)
- Modify: `Sources/MacSCPApp/Resources/{en,de,fr,pl}.lproj/Localizable.strings`
- Test: `Tests/macSCPCoreTests/SessionListViewModelTests.swift`

- [ ] **Step 1: Die Zählung ergänzen**

Das Ergebnis des Login-Set-Imports bekommt ein Feld für „ohne Passwort
angekommen", gezählt beim Anlegen. **Nur zählen, nicht lesen** — die Zahl
kommt aus dem geplanten Secret, nicht aus einem Schlüsselbund-Read.

- [ ] **Step 2: Den Test schreiben**

```swift
/// The export leaves secrets out by default and the import said nothing, so
/// the state that M28's guards exist for used to arrive unannounced.
@Test func importingSetsWithoutSecretsReportsTheirNumber() throws { … }
```

- [ ] **Step 3: Die vier Kataloge ergänzen**

Englisch als Referenz, im Stil der Nachbarzeilen:

```
"loginSets.import.withoutPassword %lld" = "Arrived without a password: %lld";
```

Deutsch:

```
"loginSets.import.withoutPassword %lld" = "Ohne Passwort angekommen: %lld";
```

FR und PL sinngemäß — dieselbe Schlüsselmenge, das erzwingt der vorhandene
Wächtertest.

- [ ] **Step 4: In die Ergebnismeldung einhängen**

Neben den vorhandenen Zeilen, nur wenn die Zahl größer null ist.

- [ ] **Step 5: Prüfen und committen**

```bash
for f in Sources/MacSCPApp/Resources/*.lproj/Localizable.strings; do plutil -lint "$f"; done
swift test --filter LocalizableStrings
swift build
swift test
```

```bash
git add Sources Tests
git commit -m "feat(app): say when imported logins arrived without a password"
```

---

### Task 5: Meilenstein-Abschluss

**Files:**
- Create: `docs/superpowers/specs/2026-08-09-m28-abschluss.md`

- [ ] **Step 1: Volle Verifikation**

```bash
swift build
swift test
```

Docker-Rig **aus dem Haupt-Checkout**, nie aus einem Worktree:

```bash
docker compose -f docker/test-server/compose.yml up -d
MACSCP_ITEST=1 swift test
MACSCP_KEYCHAIN=1 swift test --filter Keychain
```

Bleibt ein Lauf bei 0 % CPU stehen, ist das der seit M20 bekannte Hänger —
abbrechen, neu starten, vermerken, **nicht** als M28-Befund zählen. Danach
`pgrep -fl swiftpm-testing-helper`.

Kataloge:

```bash
for f in Sources/MacSCPApp/Resources/*.lproj/Localizable.strings Sources/macSCPCore/Resources/*.lproj/Localizable.strings; do plutil -lint "$f"; done
```

- [ ] **Step 2: Die Gegenprobe zum Verlustweg**

Den Test aus Task 1, der den letzten Anlauf gekippt hätte
(`anS3SetDeclaringAgentAuthIsStillNotCovered`), gegen die **damalige**
Formulierung fahren: Deckungsfrage probeweise auf `set.authKind != .agent`
umstellen, Test rot sehen, zurücknehmen. Das Ergebnis kommt in den Bericht —
es ist der Beleg, dass M28 den Fehler seines Vorgängers wirklich abfängt und
nicht nur anders schreibt.

- [ ] **Step 3: Den Bericht schreiben**

Form von `2026-08-08-m26-abschluss.md`. Muss enthalten: die Verifikation mit
Zahlen; die zehn Erfolgskriterien der Spec mit **Beleg statt Behauptung**; die
Rot-Zustände aller drei Gegenproben im Wortlaut; die **Abweichung von der
Spec** (eine Regel wurde zwei) mit dem, was sie über das Verallgemeinern
sagt; die Vorgeschichte in einem Absatz (vier zurückgenommene Runden, und
warum das Ziel verschoben wurde); was offen bleibt (der veraltete Slot, die
Editor-Reibung, der app-weite Audit-Bereich, der Release-Stau); und die Zahl
der unversendeten Commits.

- [ ] **Step 4: Committen, nicht pushen**

```bash
git add docs/superpowers/specs/2026-08-09-m28-abschluss.md
git commit -m "docs(m28): record the milestone close"
```

---

## Selbstreview des Plans

**Spec-Abdeckung.** Kriterium 1–2 → T2; 3 → T3; 4 → T1/Step 1 (sechs Tests,
einer je Tabellenzeile); 5 → T1 (`anS3SetDeclaringAgentAuthIsStillNotCovered`)
und T5/Step 2; 6 → T1/Step 5, Gegenprobe 1; 7 → T1
(`anUnreadableKeychainMakesCoverageThrowRatherThanFalse`) und T3; 8 → T4;
9 → Review; 10 → T4/Step 5.

**Typkonsistenz.** `BackendDescriptor.loginSetValues(_:)` und
`credentialSchema.visibleSecretField(in:namespace:)` existieren beide und sind
oben mit ihren echten Signaturen zitiert; `ConnectionField.isRequired` ist das
Feld, das `StoredSessionConnectionConfig` bereits in derselben Komposition
abfragt.

**Zwei bewusste Unschärfen, ausgewiesen statt versteckt:**

1. **Die Testrümpfe in T2 und T3 sind Namen plus Doc-Kommentar**, kein
   fertiger Code. Was jeder Test beweisen muss, steht fest; der Aufbau —
   Merge-Gruppe, Jump-Spec, passendes Double — ist mehrfach im Repo vorhanden
   und beim Implementierer besser aufgehoben als in einer Planzeile, die ich
   nicht ausgeführt habe.
2. **Die genaue Gestalt der Import-Zählung in T4 ist offen.** Ich weiß, dass
   das Ergebnis Zählfelder hat und die Meldung sie zeilenweise ausgibt; welches
   Feld wie heißt und wo genau gezählt wird, sieht der Implementierer im Code
   nach. Eine Planzeile, die ich nicht geprüft habe, ist eine Hypothese — und
   diese ist als solche markiert.

**Was dieser Plan bewusst nicht tut.** Er fasst die drei nicht löschenden
Binder nicht an und löscht den veralteten Slot nicht. Vier Runden haben genau
dort gearbeitet und jedes Mal einen Verlustweg hinterlassen. Wer das später
angeht, hat mit T1 die Bedingung, die dafür nötig ist.
