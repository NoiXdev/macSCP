# M25 — Die letzten Platzhalter-Leser (Design)

**Stand:** 2026-08-08. Vorgänger: M24 (`2026-08-08-m24-abschluss.md`), dessen
Gesamtreview diesen Meilenstein als Eröffnungszug benannt hat.

## Ziel

`StoredSession.host`/`port`/`username`/`authKind` liefern für eine `.s3`- oder
`.webdav`-Sitzung die SSH-Rückfallwerte `""`/`22`/`""`/`.password` — der
Platzhalter, den M23 loswerden wollte, in neuer Schreibweise. M24 hat per
Compiler-Probe fünf **ungeschützte** Leser in `SessionListViewModel`
festgestellt und die Accessoren bewusst stehen lassen, weil die Spec dort
nichts zugesagt hatte.

M25 räumt diese fünf ab und **prüft anschließend**, ob die vier Accessoren
löschbar sind. Geprüft wird, nicht versprochen: beide Ausgänge sind ein
gültiges Ergebnis.

## Die drei Änderungen

### 1. `delete` — hochziehen, nicht umstellen

`SessionListViewModel.delete(_:)` berechnet `bastionUsername`,
`bastionAuthKind`, `bastionKeyPath` und holt `bastionSecret` aus dem Keychain
(Zeilen 248–257). **Alle vier Werte werden ausschließlich innerhalb der
Schleife über `affected` benutzt** — und `affected` ist seit M24 für jede
Nicht-SSH-Sitzung leer (`session.kind == .ssh ? sessionsUsingAsJump(...) : []`).

Das ist also kein Protokollproblem, sondern toter Aufwand. Die Berechnung
wandert in ein `if !affected.isEmpty`.

Der Nebeneffekt ist der eigentliche Gewinn: beim Löschen einer S3-Sitzung wird
nicht länger deren **Secret Access Key** aus dem Keychain geholt, nur um
verworfen zu werden. Ein Zugriff auf ein Geheimnis, den niemand braucht, ist
einer zu viel — auch wenn der Wert nirgends hinfließt.

Drei der fünf Leser (Zeilen 249, 250, 255) verschwinden damit. Die beiden
verbleibenden (262, 263) liegen bereits in der Schleife und sind geschützt.

### 2. Eine neue Frage am `BackendDescriptor`

Zwei Stellen fragen dasselbe in SSH-Vokabular:

| Stelle | heute | Bedeutung |
|---|---|---|
| `updateSession` | `updated.authKind == .agent` | „braucht keine Anmeldung, alten Slot aufräumen" |
| `exportPayload` | `authKind != .agent` | „hat ein Secret, das exportiert werden kann" |

Dieselbe Beschwörung steht ein drittes Mal in
`StoredSessionConnectionConfig.build` — dort bereits schema-getrieben, aber
ausgeschrieben. Also ein Mitglied:

```swift
/// The secret field this stored session currently shows, or nil when it
/// needs none (M25) — the schema's answer to "does this login carry a
/// secret at all", asked without `StoredSession.authKind`.
public func visibleSecretField(for session: StoredSession) -> ConnectionField?
```

Rumpf: `credentialSchema.visibleSecretField(in: sessionValues(session),
namespace: fieldNamespace)`. Drei Aufrufstellen, eine Regel.

**Es wächtert nicht selbst.** `hasStoredConfiguration` bleibt Sache der
Aufrufer: `StoredSessionConnectionConfig.build` prüft heute vorher und
behält das, `updateSession` und `exportPayload` haben ihre eigenen Wachen.
Ein Mitglied, das mal wächtert und mal nicht, wäre schlimmer als drei
Aufrufer, die ihre Frage selbst stellen.

**Äquivalenz, Fall für Fall geprüft:**

| Sitzung | heute | mit dem Schema |
|---|---|---|
| SSH `.agent` | `authKind == .agent` → aufräumen | kein Secret-Feld sichtbar → `nil` → aufräumen |
| SSH `.password`/`.privateKey` | nicht aufräumen | Feld sichtbar → nicht aufräumen |
| S3 / WebDAV | `authKind` fälscht `.password` → nicht aufräumen | Feld sichtbar → nicht aufräumen |
| SSH ohne Block (`ssh == nil`) | `authKind` fällt auf `.password` → nicht aufräumen | `values(from:)` liest durch dieselben Rückfälle → Feld sichtbar → nicht aufräumen |

Die letzte Zeile ist der Grund, warum das Mitglied `sessionValues` benutzt und
nicht etwa den leeren Beutel: für `.ssh` liest `SSHFieldSchema.values(from:)`
durch die Accessoren in einen **gefüllten** Beutel, für `.s3`/`.webdav` liefert
ein fehlender Block einen leeren. Das ist dokumentiertes Verhalten
(`BackendDescriptor.sessionValues`) und in beiden Fällen dasselbe Ergebnis wie
heute.

### 3. `exportPayload` — nur der Fallback-Zweig

Dort steht `let authKind = resolved?.authKind ?? session.authKind`. **Die
Agent-Eigenschaft einer set-gebundenen Sitzung kommt aus dem Set, nicht aus der
Sitzung.** Wer das pauschal durch eine Schema-Frage an die Sitzungswerte
ersetzt, ändert Verhalten: eine Sitzung an einem Agent-Set würde plötzlich ein
Secret suchen und, wenn keines da ist, im nutzer-sichtbaren „N Passwörter
fehlen" mitgezählt.

Ersetzt wird deshalb ausschließlich der Rückfall auf die Sitzung:

```swift
let needsSecret = resolved.map { $0.authKind != .agent }
    ?? (descriptor.visibleSecretField(for: session) != nil)
```

Der `.agent`-Vergleich auf `ResolvedLogin` **bleibt** und ist kein Rückfall in
alte Gewohnheiten: `resolvedSSHLogin` ist seit M22/T9 absichtlich SSH-geformt
(Jump-Pfad und Exportformat sprechen genau diese vier Spalten). Ein
`StoredSession`-Accessor ist es nicht.

**Die lokale Bindung `authKind` verschwindet dabei ganz** — nachgeprüft, nicht
angenommen: sie wird innerhalb von `exportPayload` an genau einer Stelle
gelesen, nämlich in dieser Wache. Die beiden anderen `authKind`-Vorkommen der
Funktion sind `resolved.authKind.rawValue` für die Feldablage (liest das
Resolved-Login direkt) und der eigene `authKind` des Jumps.

Die beiden anderen kind-Bedingungen der Zeile — `session.kind != .s3` und
`session.kind != .webdav || session.webdav != nil` — **bleiben unangetastet**
(Maintainer-Entscheidung 2026-08-08). Sie sind Format-Logik, kein
Protokoll-Dispatch: das Exportformat hat getrennte Secret-Spalten, und M23/P3
hat beide Wachen nach einem Befund ausdrücklich wiederhergestellt.

## Die Probe

Nach den drei Änderungen: `@available(*, deprecated, message: "…")` auf die vier
Accessoren, `swift build`, jeden Treffer einzeln beurteilen.

- **Bleiben nur `SSHFieldSchema.values(from:)` und geschützte Stellen** →
  Accessoren löschen, volle Suite erneut, Ergebnis im Abschlussbericht.
- **Bleibt etwas Ungeschütztes** → Accessoren bleiben, und jeder verbleibende
  ungeschützte Leser wird **namentlich mit Datei und Zeile** genannt.

Die Probe ist ein Compiler-Lauf, kein `grep`: M24 hat gezeigt, dass der Grep auf
`.host`/`.port` 241 Treffer liefert, von denen die große Mehrheit URLs und
fremde Typen sind.

## Erfolgskriterien

| # | Kriterium | Nachweis |
|---|---|---|
| 1 | Das Löschen einer Nicht-SSH-Sitzung fasst den Keychain nicht mehr an | Test mit lesefeindlichem `SecretStore` (Muster: `agentSetResolvesWithoutKeychainRead`) |
| 2 | Das Löschen einer SSH-Bastion restauriert unverändert | die bestehenden `delete`-Tests bleiben grün, ohne Anpassung |
| 3 | `updateSession` räumt für ssh-agent auf und für S3/WebDAV nicht | je ein Test, beide Richtungen |
| 4 | Eine Sitzung an einem **Agent-Login-Set** exportiert weiterhin kein Passwort und wird nicht als fehlend gezählt | Test — das ist die Stelle, an der eine pauschale Umstellung Verhalten geändert hätte |
| 5 | `visibleSecretField(for:)` hat drei Aufrufstellen; die ausgeschriebene Kopie in `StoredSessionConnectionConfig` ist verschwunden | grep |
| 6 | Die Probe ist gelaufen und ihr Ergebnis steht im Abschlussbericht | beide Ausgänge zulässig, ungeschützte Leser namentlich |
| 7 | Keine Verhaltensänderung sonst; Testzahl ≥ 1587 | volle Suite, gegatete Suiten, vier Kataloge `plutil`-clean |

## Test-Hinweise

- Sitzungen über die Fixtures (`sshSession`, `s3Session`, `webdavSession`),
  nie `StoredSession` direkt.
- Für Kriterium 1 und für jede „liest nicht" -Zusage: ein `SecretStore`, dessen
  `password(for:)` den Test scheitern lässt. Das Muster steht am Ende von
  `LoginMergePlannerTests.swift`.
- Kriterium 2 ist die Regressionsklammer: müssen die bestehenden
  `delete`-Tests angefasst werden, hat die Verlagerung Verhalten verschoben —
  das ist ein Befund und gehört gemeldet, nicht weggeschrieben.

## Für die Release-Notes

**Nichts.** M25 ist eine reine Innenumstellung ohne nutzer-sichtbare Wirkung.
Sollte die Probe eine Verhaltensänderung ans Licht bringen, gehört sie hier
nachgetragen.

## Offen, bewusst nicht Teil von M25

- Die Secret-Spalten des Exportformats zu vereinheitlichen (`password` /
  `s3SecretAccessKey` / `jumpPassword` → eine Spalte, das Schema sagt welche).
  Das wäre die Vollendung von M23/P3, ist aber eine **Formatänderung** mit
  `.macscp`-Version 3, Migration und dem Ende des Austauschs mit v2-Dateien.
  Eigener Meilenstein, eigene Spec.
- Die Blocklos-Wachen (`session.s3 != nil`, `session.webdav != nil`) auf
  `hasStoredConfiguration` zu ziehen.
- Die vertagten M24-Minors (`ssh.managedKeyID`-Test, Komparator-Tiebreaker,
  zwei irreführende Kommentare, das deutsche Zitat in einem Doc-Kommentar,
  `actions/checkout@v4` → `@v5`).
- Der 0-%-CPU-Testsuite-Hänger (eigene Akte:
  `2026-08-08-testsuite-haenger-untersuchung.md`).
