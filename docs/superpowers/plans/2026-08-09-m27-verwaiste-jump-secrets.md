# M27 — Verwaiste Jump-Secrets: Implementierungsplan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Die Schlüsselbund-Einträge entfernen, die die M23-Migration
zurückgelassen hat — ausgelöst vom Nutzer, ohne je etwas Lebendiges zu treffen.

**Architecture:** Ein Core-Typ `LegacyJumpSecretSweep` liest die aufgehobene
`sessions.json` über einen neuen, ausschließlich lesenden Zugang am
`SessionStore`, zieht alles ab, was heute noch beansprucht wird, und löscht den
Rest über die vorhandene `SecretStore.deletePassword`. Die App bekommt einen
Knopf in Einstellungen › Daten verwalten.

**Tech Stack:** Swift 6, `.swiftLanguageMode(.v5)`, SwiftPM, macOS 15+,
Swift Testing, SwiftUI.

Spec: `../specs/2026-08-09-m27-verwaiste-jump-secrets-design.md`

## Global Constraints

- **Code, Kommentare, Bezeichner, Testnamen: nur Englisch.** Interne Doku
  Deutsch.
- **Ein Secret-Wert wird nie gedruckt, geloggt oder in einen Fehler eingebettet
  — auch nicht in eine Testfehlermeldung.** Der Sweep ruft `password(for:)`
  **nie** auf.
- **Kein `try? … ?? []` auf irgendeinem Pfad dieses Meilensteins.** Jeder
  Lesefehler bricht ab.
- **Der Sweep fasst den ViewModel-Zustand nicht an**, sondern die Stores.
- Die Legacy-Datei wird **gelesen und nicht verändert**.
- Das `SecretStore`-Protokoll bekommt **kein** neues Mitglied.
- App-UI über alle vier Kataloge en/de/fr/pl mit identischen Schlüsselmengen;
  CLI ist englisch und wird nicht angefasst.
- Conventional Commits, englische Nachricht, Footer auf jedem Commit:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- **Nicht pushen.** Die GUI nicht starten. `scripts/release` nicht ausführen.
- Testzahl-Basis: **1619**.

---

### Task 1: Der lesende Zugang zur Legacy-Datei

**Files:**
- Modify: `Sources/macSCPCore/Sessions/SessionStore.swift`
- Test: `Tests/macSCPCoreTests/SessionStoreTests.swift`

**Interfaces:**
- Produces: `SessionStore.legacyJumpSecretIDs() throws -> [UUID]` — jede
  `jump.secretID` aus `sessions.json`, in Dateireihenfolge, Duplikate
  entfernt. Leeres Array, wenn die Datei fehlt. **Wirft**, wenn sie da und
  nicht lesbar/dekodierbar ist.

- [ ] **Step 1: Die Tests schreiben**

In `SessionStoreTests`, im Stil der vorhandenen handgeschriebenen Fixtures
(siehe `blocklessSSHFixture` und die Begründung darüber, warum von Hand):

```swift
/// The sweep's candidate source. A jump's `secretID` is the only thing M23
/// left behind, so this reads exactly that -- and nothing else about the
/// legacy shape leaks out of the store.
@Test func legacyJumpSecretIDsReadsEveryJumpFromTheOldFile() throws {
    let dir = try makeTempDirectory()
    let a = UUID(), b = UUID()
    try legacyFixture(withJumpSecretIDs: [a, b]).write(
        to: dir.appendingPathComponent("sessions.json"))
    let store = SessionStore(directory: dir)
    #expect(try store.legacyJumpSecretIDs() == [a, b])
}

@Test func legacyJumpSecretIDsIsEmptyWhenTheOldFileIsGone() throws {
    let store = SessionStore(directory: try makeTempDirectory())
    #expect(try store.legacyJumpSecretIDs().isEmpty)
}

/// An unreadable file must NOT read as "no candidates". Everything in M27
/// hangs on this: a silent empty result here is the one shape that cannot
/// be distinguished from a clean install.
@Test func legacyJumpSecretIDsThrowsOnAnUnreadableFile() throws {
    let dir = try makeTempDirectory()
    try Data("{ not json".utf8).write(
        to: dir.appendingPathComponent("sessions.json"))
    let store = SessionStore(directory: dir)
    #expect(throws: (any Error).self) { try store.legacyJumpSecretIDs() }
}

/// A session without a jump contributes nothing, and the same secretID
/// appearing twice contributes once.
@Test func legacyJumpSecretIDsSkipsJumplessRecordsAndDeduplicates() throws {
    let dir = try makeTempDirectory()
    let a = UUID()
    try legacyFixture(withJumpSecretIDs: [a, nil, a]).write(
        to: dir.appendingPathComponent("sessions.json"))
    let store = SessionStore(directory: dir)
    #expect(try store.legacyJumpSecretIDs() == [a])
}

/// M23 keeps sessions.json as the downgrade snapshot. Reading it must not
/// touch it.
@Test func readingLegacyJumpSecretIDsLeavesTheFileByteIdentical() throws {
    let dir = try makeTempDirectory()
    let url = dir.appendingPathComponent("sessions.json")
    try legacyFixture(withJumpSecretIDs: [UUID()]).write(to: url)
    let before = try Data(contentsOf: url)
    _ = try SessionStore(directory: dir).legacyJumpSecretIDs()
    #expect(try Data(contentsOf: url) == before)
}
```

Der Fixture-Helfer, daneben im selben File — von Hand geschrieben, weil kein
Schreibpfad der App die Legacy-Form noch erzeugt:

```swift
/// A pre-M23 `sessions.json`. Hand-written for the same reason the blockless
/// fixtures above are: nothing in the app writes this shape any more.
/// `nil` in the array means a session without a jump.
private func legacyFixture(withJumpSecretIDs ids: [UUID?]) -> Data {
    let records = ids.enumerated().map { index, secretID -> String in
        let jump = secretID.map {
            """
            ,"jump":{"host":"bastion.example.com","port":22,\
            "username":"tim","authKind":"password","secretID":"\($0.uuidString)"}
            """
        } ?? ""
        return """
        {"id":"\(UUID().uuidString)","name":"legacy-\(index)",\
        "host":"example.com","port":22,"username":"tim",\
        "authKind":"password"\(jump)}
        """
    }
    return Data("[\(records.joined(separator: ","))]".utf8)
}
```

- [ ] **Step 2: Rot sehen**

```bash
swift test --filter legacyJumpSecretIDs
```
Erwartet: FAIL, `value of type 'SessionStore' has no member 'legacyJumpSecretIDs'`.

- [ ] **Step 3: Umsetzen**

In `SessionStore`, neben `migrateFromLegacy()`:

> **Korrektur 2026-08-09 (Task-1-Review, Critical).** Der Beispielcode unten
> war falsch: `sessions.json` hat **zwei** Legacy-Formen, und
> `migrateFromLegacy()` behandelt beide — erst den Container
> `{"groups":…,"sessions":…}` per `try?`, dann als Rückfall das nackte Array
> per hartem `try`. Nur das Array zu dekodieren lässt den Zugriff auf jeder
> Installation mit Gruppen **werfen** — also seit vor 1.0. Die Umsetzung
> spiegelt `migrateFromLegacy()`. **Die tragende Eigenschaft dabei:** der
> `try?` auf den Container ist nur harmlos, weil der Array-Versuch danach ein
> hartes `try` ist; wären beide optional, würde aus „nicht lesbar" wieder
> „keine Kandidaten".

```swift
/// Every jump `secretID` in the preserved pre-M23 `sessions.json`, in file
/// order, without duplicates -- the candidate set for M27's sweep.
///
/// This is the only reader of the legacy file besides `migrateFromLegacy`,
/// and it is deliberately narrow: it hands out `secretID`s and nothing else,
/// so the legacy shape does not leak back into the app. The file is read and
/// left alone; M23 keeps it as the downgrade snapshot.
///
/// A MISSING file means a clean install and yields no candidates. A file that
/// is there and cannot be decoded THROWS -- reading it as "no candidates"
/// would make an unreadable disk indistinguishable from a clean one, and the
/// sweep decides what to delete from exactly this answer.
public func legacyJumpSecretIDs() throws -> [UUID] {
    guard FileManager.default.fileExists(
        atPath: legacyFileURL.path(percentEncoded: false)) else { return [] }
    let data = try Data(contentsOf: legacyFileURL)
    let legacy = try JSONDecoder().decode([LegacyStoredSession].self, from: data)
    var seen = Set<UUID>()
    return legacy.compactMap { $0.jump?.secretID }.filter { seen.insert($0).inserted }
}
```

- [ ] **Step 4: Grün sehen**

```bash
swift test --filter legacyJumpSecretIDs
```
Erwartet: 5 Tests grün.

- [ ] **Step 5: Committen**

```bash
git add Sources/macSCPCore/Sessions/SessionStore.swift Tests/macSCPCoreTests/SessionStoreTests.swift
git commit -m "feat(core): expose the legacy file's jump secret ids for the M27 sweep"
```

---

### Task 2: Der Sweep

**Files:**
- Create: `Sources/macSCPCore/Sessions/LegacyJumpSecretSweep.swift`
- Create: `Tests/macSCPCoreTests/LegacyJumpSecretSweepTests.swift`

**Interfaces:**
- Consumes: `SessionStore.legacyJumpSecretIDs()` aus Task 1;
  `SessionStore.all() throws -> [StoredSession]`,
  `LoginSetStore.all() throws -> [LoginSet]`,
  `ManagedKeyStore.all() throws -> [ManagedKey]`,
  `SecretStore.deletePassword(for:) throws`.
- Produces: `LegacyJumpSecretSweep(sessions:loginSets:keys:secrets:)` mit
  `run() throws -> Result`, `Result(removed: Int, failed: Int)`.

- [ ] **Step 1: Die Tests schreiben**

```swift
@Suite("LegacyJumpSecretSweep")
struct LegacyJumpSecretSweepTests {

    /// The whole point: an id the legacy file names and nothing claims today
    /// is removed.
    @Test func removesAJumpSecretNoRecordClaimsAnyMore() throws { … }

    /// The counterpart, and the more important half: an SSH session kept its
    /// jump through the migration, so its secretID appears in BOTH files.
    @Test func keepsAJumpSecretThatASessionStillClaims() throws { … }

    /// Not "the id we asked about is gone" but "nothing is gone anywhere".
    /// `storedIDs` exists on the double for exactly this.
    @Test func removesNothingElseFromTheSecretStore() throws { … }

    /// The catastrophic case. A session file that cannot be read must not
    /// read as "no session claims anything" -- that would make every live
    /// jump secret a candidate.
    @Test func anUnreadableSessionFileDeletesNothingAndThrows() throws { … }

    @Test func anUnreadableLoginSetFileDeletesNothingAndThrows() throws { … }
    @Test func anUnreadableManagedKeyFileDeletesNothingAndThrows() throws { … }
    @Test func anUnreadableLegacyFileDeletesNothingAndThrows() throws { … }

    /// No legacy file at all is a clean install, not an error.
    @Test func aMissingLegacyFileIsNotAnError() throws { … }

    /// House rule: one failure does not stop the rest (same shape as
    /// removing several known hosts).
    @Test func aFailingDeleteIsCountedAndTheRestStillRun() throws { … }

    /// The sweep must never read a secret -- no access prompts, and no
    /// decision resting on a read that proves nothing when it fails.
    @Test func theSweepNeverReadsASecret() throws { … }

    /// Idempotent: a second run finds the entries gone and reports zero.
    @Test func asecondRunReportsNothingRemoved() throws { … }
}
```

Jeder Test baut echte Stores über temporäre Verzeichnisse plus
`InMemorySecretStore`. Für `theSweepNeverReadsASecret` ein Double, dessen
`password(for:)` `Issue.record` auslöst — das Muster steht mehrfach im Repo
(z. B. die „reads are forbidden"-Doubles in `LoginResolverTests`).

Für die Unlesbar-Tests je Datei denselben Trick wie in Task 1: kaputtes JSON
schreiben.

**Regel für alle vier Abbruch-Tests:** nach dem Wurf muss
`secrets.storedIDs` **unverändert** sein. Der Wurf allein genügt nicht — er
muss vor dem ersten Löschen passieren.

- [ ] **Step 2: Rot sehen**

```bash
swift test --filter LegacyJumpSecretSweep
```
Erwartet: FAIL, Typ existiert nicht.

- [ ] **Step 3: Umsetzen**

```swift
/// Removes the Keychain entries the M23 migration left behind.
///
/// M23 dropped a non-SSH session's `jump` when it upgraded the store and said
/// so in `LegacyStoredSession`: the jump's `secretID` named a Keychain entry
/// that nothing referenced afterwards, and the cleanup was deferred to "a
/// separate pass that owns a `SecretStore`". This is that pass.
///
/// **Candidates come from the preserved legacy file, never from the Keychain.**
/// That is what makes the sweep safe rather than merely careful: an entry a
/// future macSCP wrote cannot appear in a file written before M23, so it can
/// never become a candidate. Enumerating the Keychain would have no such
/// guarantee -- everything under the service shares one flat UUID namespace,
/// so session secrets, login-set secrets and key passphrases are
/// indistinguishable from each other and from anything a newer build stores.
///
/// **Every read error aborts before anything is deleted.** A store that reads
/// as empty when it merely failed would leave no id claimed, and every live
/// jump secret would look like an orphan. For the same reason the sweep talks
/// to the stores rather than to a view model: `reload()` turns a failure into
/// empty lists.
///
/// The sweep never calls `password(for:)`. Nothing is read, only deleted, so
/// there are no access prompts and no decision rests on a failing read.
public struct LegacyJumpSecretSweep {
    public struct Result: Equatable, Sendable {
        public var removed: Int
        public var failed: Int
        public init(removed: Int, failed: Int) {
            self.removed = removed
            self.failed = failed
        }
    }

    private let sessions: SessionStore
    private let loginSets: LoginSetStore
    private let keys: ManagedKeyStore
    private let secrets: any SecretStore

    public init(
        sessions: SessionStore, loginSets: LoginSetStore,
        keys: ManagedKeyStore, secrets: any SecretStore
    ) {
        self.sessions = sessions
        self.loginSets = loginSets
        self.keys = keys
        self.secrets = secrets
    }

    public func run() throws -> Result {
        // Order matters: every read happens before the first delete, so a
        // failure anywhere leaves the Keychain untouched.
        let candidates = try sessions.legacyJumpSecretIDs()
        guard !candidates.isEmpty else { return Result(removed: 0, failed: 0) }
        let claimed = try claimedIDs()

        var removed = 0, failed = 0
        for id in candidates where !claimed.contains(id) {
            do {
                try secrets.deletePassword(for: id)
                removed += 1
            } catch {
                // One failure does not stop the rest -- same rule as removing
                // several known hosts. The count is reported; the error is not
                // carried further, because it can only be an OSStatus and the
                // user's next step is the same either way.
                failed += 1
            }
        }
        return Result(removed: removed, failed: failed)
    }

    /// Every id anything still claims. Wider than strictly necessary -- a
    /// pre-M23 jump `secretID` cannot also be a login-set or managed-key id --
    /// and deliberately so: it costs one pass each and makes the rule "delete
    /// only what appears NOWHERE" true without case analysis.
    private func claimedIDs() throws -> Set<UUID> {
        var claimed = Set<UUID>()
        for session in try sessions.all() {
            claimed.insert(session.id)
            if let secretID = session.jump?.secretID { claimed.insert(secretID) }
        }
        for set in try loginSets.all() { claimed.insert(set.id) }
        for key in try keys.all() { claimed.insert(key.id) }
        return claimed
    }
}
```

- [ ] **Step 4: Grün sehen**

```bash
swift test --filter LegacyJumpSecretSweep
```

- [ ] **Step 5: Die Gegenprobe fahren**

Nicht optional. Nacheinander, jeweils zurücknehmen:

1. `guard !candidates.isEmpty` entfernen und `claimedIDs()` **nach** der
   Schleife aufrufen → `anUnreadableSessionFileDeletesNothingAndThrows` muss
   rot werden. Beweist, dass die Reihenfolge geprüft ist und nicht zufällig
   stimmt.
2. `try sessions.all()` durch `(try? sessions.all()) ?? []` ersetzen →
   derselbe Test muss rot werden. Das ist der Fehler, gegen den der ganze
   Meilenstein gebaut ist.

Beide Rot-Zustände in den Bericht, dann sauber zurücknehmen und
`git status --porcelain` als leer nachweisen.

- [ ] **Step 6: Committen**

```bash
git add Sources/macSCPCore/Sessions/LegacyJumpSecretSweep.swift Tests/macSCPCoreTests/LegacyJumpSecretSweepTests.swift
git commit -m "feat(core): reap the jump secrets the M23 migration orphaned"
```

---

### Task 3: Der Knopf in den Einstellungen

**Files:**
- Modify: `Sources/MacSCPApp/SettingsView.swift` (`ManageDataSettingsSection`)
- Modify: `Sources/MacSCPApp/Resources/{en,de,fr,pl}.lproj/Localizable.strings`

**Interfaces:**
- Consumes: `LegacyJumpSecretSweep` aus Task 2.

- [ ] **Step 1: Die vier Kataloge ergänzen**

Neue Schlüssel, in **allen vier** Dateien, an der Stelle der übrigen
`manageData.*`-Schlüssel. Englisch als Referenz:

```
"manageData.reapSecrets.button" = "Remove leftover credentials…";
"manageData.reapSecrets.explanation" = "Upgrading from version 1.0 could leave credentials in the keychain that nothing uses any more.";
"manageData.reapSecrets.confirmTitle" = "Remove leftover credentials?";
"manageData.reapSecrets.confirmMessage" = "Only credentials no saved connection, login set or key refers to are removed. This action cannot be undone.";
"manageData.reapSecrets.confirmAction" = "Remove";
"manageData.reapSecrets.result" = "Cleanup finished.";
"manageData.reapSecrets.resultFailures %lld" = "Could not be removed: %lld";
"manageData.reapSecrets.failed" = "The leftover credentials could not be checked. Nothing was removed.";
```

Deutsch:

```
"manageData.reapSecrets.button" = "Übrige Zugangsdaten entfernen…";
"manageData.reapSecrets.explanation" = "Beim Aufstieg von Version 1.0 können Zugangsdaten im Schlüsselbund geblieben sein, die nichts mehr benutzt.";
"manageData.reapSecrets.confirmTitle" = "Übrige Zugangsdaten entfernen?";
"manageData.reapSecrets.confirmMessage" = "Entfernt werden nur Zugangsdaten, auf die keine gespeicherte Verbindung, kein Login-Set und kein Schlüssel verweist. Das lässt sich nicht rückgängig machen.";
"manageData.reapSecrets.confirmAction" = "Entfernen";
"manageData.reapSecrets.result" = "Aufräumen abgeschlossen.";
"manageData.reapSecrets.resultFailures %lld" = "Nicht entfernt werden konnten: %lld";
"manageData.reapSecrets.failed" = "Die übrigen Zugangsdaten konnten nicht geprüft werden. Es wurde nichts entfernt.";
```

FR und PL sinngemäß übersetzen — dieselbe Schlüsselmenge, das erzwingt
`appLayerLanguagesMatchEnglishKeys`.

- [ ] **Step 2: Kataloge prüfen**

```bash
for f in Sources/MacSCPApp/Resources/*.lproj/Localizable.strings; do plutil -lint "$f"; done
swift test --filter LocalizableStrings
```
Erwartet: alle `OK`, Wächtertest grün.

- [ ] **Step 3: Den Knopf einbauen**

In `ManageDataSettingsSection`, unter den vorhandenen Verknüpfungen, ein
eigener Abschnitt. Zustand:

```swift
@State private var confirmingReap = false
@State private var reapResult: String?
```

Der Knopf, der Dialog nach Hausmuster, und der Bericht darunter:

```swift
Button(L10n.string("manageData.reapSecrets.button", "Remove leftover credentials…")) {
    confirmingReap = true
}
.confirmationDialog(
    L10n.string("manageData.reapSecrets.confirmTitle", "Remove leftover credentials?"),
    isPresented: $confirmingReap, titleVisibility: .visible
) {
    Button(
        L10n.string("manageData.reapSecrets.confirmAction", "Remove"),
        role: .destructive, action: runReap)
} message: {
    Text(L10n.string("manageData.reapSecrets.confirmMessage", "…"))
}
if let reapResult { Text(reapResult).font(.callout).foregroundStyle(.secondary) }
```

Der Aufruf. **Der Fehlerfall nennt keine Ursache** — der Nutzer kann an einer
unlesbaren Store-Datei nichts ablesen, und die Meldung soll vor allem sagen,
dass nichts entfernt wurde:

```swift
private func runReap() {
    let sweep = LegacyJumpSecretSweep(
        sessions: SessionStore(directory: SessionStore.defaultDirectory),
        loginSets: LoginSetStore(directory: LoginSetStore.defaultDirectory),
        keys: ManagedKeyStore(directory: ManagedKeyStore.defaultDirectory),
        secrets: KeychainSecretStore())
    do {
        let result = try sweep.run()
        // No removal count, deliberately: `deletePassword` maps
        // `errSecItemNotFound` to success, so `Result.removed` counts
        // successful delete CALLS, not entries that were actually there --
        // and since the legacy file stays as the downgrade snapshot, a second
        // run would report the same number for a keychain that is already
        // clean. A number nobody can trust is worse than none.
        var text = L10n.string("manageData.reapSecrets.result", "Cleanup finished.")
        if result.failed > 0 {
            text += "\n" + String(
                format: L10n.string("manageData.reapSecrets.resultFailures %lld", "Failed: %lld"),
                result.failed)
        }
        reapResult = text
    } catch {
        reapResult = L10n.string("manageData.reapSecrets.failed", "Nothing was removed.")
    }
}
```

**Die Namen der `defaultDirectory`-Eigenschaften vor dem Schreiben prüfen** —
`SessionStore.defaultDirectory` existiert (`ContentView.swift` benutzt sie);
für die anderen beiden Stores nachsehen, wie `ContentView` sie konstruiert,
und dieselbe Quelle benutzen statt einen Pfad zu erfinden. Weicht etwas ab,
ist das ein Befund für den Bericht, keine stille Anpassung.

- [ ] **Step 4: Bauen**

```bash
swift build
swift test
```
Erwartet: sauber inklusive App-Target, Suite grün, Zahl ≥ 1619 + neue Tests.

- [ ] **Step 5: Committen**

```bash
git add Sources/MacSCPApp
git commit -m "feat(app): offer the leftover-credential cleanup in settings"
```

---

### Task 4: Meilenstein-Abschluss

**Files:**
- Create: `docs/superpowers/specs/2026-08-09-m27-abschluss.md`

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

Bleibt ein Lauf bei 0 % CPU stehen, ist das der seit M20 bekannte Hänger
(`2026-08-08-testsuite-haenger-untersuchung.md`) — abbrechen, neu starten, im
Bericht vermerken, **nicht** als M27-Befund zählen. Danach
`pgrep -fl swiftpm-testing-helper` auf Waisen prüfen.

Kataloge:

```bash
for f in Sources/MacSCPApp/Resources/*.lproj/Localizable.strings Sources/macSCPCore/Resources/*.lproj/Localizable.strings; do plutil -lint "$f"; done
```

- [ ] **Step 2: Die Gegenprobe zum Protokoll**

Belegen, dass das `SecretStore`-Protokoll **unverändert** ist — die Zusage der
Spec, dass keine der zwölf Konformitäten angefasst werden musste:

```bash
git diff 05a1811..HEAD -- Sources/macSCPCore/Sessions/SecretStore.swift
```

Erwartet: leer. Ein leeres Diff ist hier ein echter Beleg, weil eine
Protokolländerung zwingend in dieser Datei stünde — anders als bei einem Grep,
dessen Leerergebnis nichts beweist.

- [ ] **Step 3: Den Bericht schreiben**

Form von `2026-08-08-m26-abschluss.md`. Muss enthalten: die Verifikation mit
Zahlen; die elf Erfolgskriterien der Spec mit **Beleg statt Behauptung**; die
beiden Rot-Zustände der Gegenprobe aus Task 2 Step 5 im Wortlaut; die zwei
Entscheidungen, die während der Umsetzung zurückgenommen wurden (der
Rohdatei-Weg als Gürtel statt tragender Wand; der Audit-Eintrag, den das
sitzungsgebundene Log nicht halten kann) mit dem, was sie über das Vorgehen
sagen; was offen bleibt (abgestandenes Secret im Login-Set-Modus,
Managed-Key-Rollback-Waisen, app-weites Audit); und die Zahl der unversendeten
Commits (`git rev-list --count origin/develop..develop`).

- [ ] **Step 4: Committen, nicht pushen**

```bash
git add docs/superpowers/specs/2026-08-09-m27-abschluss.md
git commit -m "docs(m27): record the milestone close"
```

Der Push erfolgt ausschließlich auf ausdrückliche Anordnung des Maintainers.

---

## Selbstreview des Plans

**Spec-Abdeckung.** Kriterium 1–2 → T2/Step 1 (die ersten beiden Tests);
3 → T2/Step 1 (`anUnreadableSessionFileDeletesNothingAndThrows`) und T2/Step 5
(die Gegenprobe, die ihn scharf macht); 4 → T2/Step 3, Signatur nimmt Stores,
kein ViewModel; 5 → T1/Step 1 und die drei Unlesbar-Tests in T2; 6 → T1 und
T2 je ein Test; 7 → T2 `theSweepNeverReadsASecret`; 8 → T2
`aFailingDeleteIsCountedAndTheRestStillRun`; 9 → T1
`readingLegacyJumpSecretIDsLeavesTheFileByteIdentical`; 10 → T3, der Bericht
formatiert nur Zahlen; 11 → T3/Step 2.

**Typkonsistenz.** `LegacyStoredSession.jump` ist `StoredSession.JumpSpec?`
mit `secretID: UUID`; `StoredSession.jump` ist `ssh?.jump`, ebenfalls
`JumpSpec?`. Beide Seiten lesen dieselbe Eigenschaft.

**Zwei bewusste Unschärfen, ausgewiesen statt versteckt:**

1. **Die `defaultDirectory`-Namen für `LoginSetStore` und `ManagedKeyStore`
   habe ich nicht verifiziert.** `SessionStore.defaultDirectory` ist belegt;
   für die anderen beiden sagt der Plan, wo nachzusehen ist, statt einen Namen
   zu erfinden, den der Implementierer dann glaubt. Eine Planzeile, die ich
   nicht geprüft habe, ist eine Hypothese — und diese ist als solche markiert.
2. **Die Testrümpfe in Task 2 Step 1 sind Namen plus Doc-Kommentar, kein
   fertiger Code.** Das ist hier Absicht: jeder dieser Tests baut drei echte
   Stores über temporäre Verzeichnisse, und die Helfer dafür stehen bereits in
   den vorhandenen Suiten. Ausgeschriebene Rümpfe wären elf Mal derselbe
   Aufbau, den der Implementierer ohnehin an einer Stelle zusammenzieht. Was
   der Plan **nicht** offenlässt, ist die Frage, was jeder Test beweisen muss
   — das steht im Doc-Kommentar, und Step 5 nagelt die zwei wichtigsten per
   Mutation fest.
