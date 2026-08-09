# M28 — Die zwei löschenden Binder (Design)

**Stand:** 2026-08-09. Vorgänger: der am selben Tag zurückgenommene
Login-Set-Slot-Fix (`479d018`). Dieser Meilenstein greift das Problem an der
Stelle an, die vier Anläufe verfehlt haben.

## Wie dieser Meilenstein zu seinem Ziel kam

Der zurückgenommene Fix wollte den **veralteten Slot** beseitigen: eine
Sitzung, die an ein Login-Set gebunden wird, behält ihr altes Passwort im
Schlüsselbund, und beim Zurückschalten auf manuell greift es wieder. Vier
adversariale Reviews, vier Wege, auf denen dabei die **einzige** Kopie eines
Secrets verschwand. Zurückgenommen.

Die Aufklärung danach hat die Zielsetzung widerlegt:

> **Der veraltete Slot ist der milde Zustand.** Es geht nichts verloren, und
> für SSH-Passwort und S3 verweigert der Connect ehrlich
> („Password must not be empty." / „Fill in all required S3 fields.").
>
> **Gefährlich sind zwei Stellen, die der zurückgenommene Fix nie berührt
> hat** — und die schon vorher da waren.

Fünf Stellen binden eine Sitzung oder einen Jump an ein Login-Set. **Genau
zwei davon löschen dabei einen Schlüsselbund-Slot, und keine von beiden fragt
heute irgendeine Bedingung ab.**

| # | Binder | löscht? |
|---|---|---|
| 1 | Formular „Speichern & verbinden" (`save`) | nein — der Secret-Block ist bei gesetztem `loginSetID` komplett übersprungen |
| 2 | Edit-Save (`validateForEditSave`) | nein — reine Wertberechnung |
| 3 | **`applyMerge`** | **ja** — löscht den eigenen Slot jeder zusammengeführten Sitzung |
| 4 | „Als neues Set sichern" (`onSaveEdited`) | nur mittelbar, und nur für Agent-Sitzungen |
| 5 | **Jump-Bindung (`buildJumpSpec` → `cleanOrphanedJumpSlot`)** | **ja** — löscht den bisherigen manuellen Jump-Slot, *weil* der neue Jump im Set-Modus ist |

## Die zwei Defekte

### `applyMerge` verwechselt „kein Secret" mit „nicht lesbar"

Die Quell-Secrets werden mit `try?` gelesen. Liefern alle Reads `nil` — der
Slot ist leer **oder die Keychain antwortet nicht** —, bleibt `carryError`
leer, **kein Rollback greift**, das Set entsteht ohne Secret, jede Sitzung
wird daran gebunden, und im selben Schleifendurchlauf wird jeder eigene Slot
gelöscht.

`LoginMergePlanner` verengt das, schließt es aber nicht: ein
`.credential`-Secret, das nicht lesbar ist, fällt bei der Kandidatenbildung
raus — zur *Planzeit* hatte also mindestens ein Mitglied ein lesbares Secret.
`applyMerge` liest jedoch **erneut**, und zwischen beiden Reads liegt ein
Bestätigungsdialog. Ein `.passphrase`-Secret wird zur Planzeit ohnehin nie
gelesen.

### Die Jump-Bindung löscht wegen des Modus, nicht wegen der Deckung

`cleanOrphanedJumpSlot` löscht den Slot des bisherigen manuellen Jumps, sobald
der neue Jump eine `loginSetID` trägt. Ob dieses Set ein Secret hält, wird
nicht gefragt. Ein gewöhnlicher Nutzerweg: Jump von „Manuell" auf ein
secretloses Set umstellen ⇒ Bastion-Passwort weg, Jump nicht mehr anmeldbar.

### Wie ein secretloses Set überhaupt entsteht — leichter als gedacht

Der Login-Set-**Export hat Secrets standardmäßig aus**, und der **Import sagt
kein Wort darüber**, dass die Sets ohne Passwort ankommen: die Ergebnismeldung
hat Zeilen für umbenannt, Schlüssel importiert, fehlende Pfade, Secret-Fehler —
aber keine für „diese Sets kamen ohne Passwort". Die Exportseite meldet es
(„Exported without a password: %lld"), die Importseite nicht.

## Die Regel

**Ein Binder, der löscht, stellt dieselbe Frage wie der Verbindungspfad:**

> Deklariert sich das **derzeit sichtbare Secret-Feld** dieses Sets als
> **erforderlich**?

Nicht `LoginSet.authKind`. Genau daran ist der letzte Anlauf gescheitert:
`authKind` und `kind` sind unabhängige Spalten, die der Login-Set-Import
wörtlich aus der Datei kopiert — ein `.s3`-Set mit `authKind: agent` kürzt
jeden darauf gebauten Wächter ab.

Die Schema-Frage existiert bereits und unterscheidet im Verbindungspfad alle
fünf Konfigurationen korrekt:

| Konfiguration | sichtbares Secret-Feld | erforderlich? | Set ohne Secret ist… |
|---|---|---|---|
| SSH Passwort | `password` | ja | **nicht gedeckt** |
| SSH privater Schlüssel | `passphrase` | nein | gedeckt (unverschlüsselter Schlüssel) |
| SSH Agent | keines sichtbar | — | gedeckt |
| S3 | `secretAccessKey` | ja | **nicht gedeckt** |
| WebDAV | `password` | nein | gedeckt (anonyme Freigabe — Maintainer-Entscheidung aus M23) |

Dazu der Sonderfall, den das Schema **nicht** beantworten kann: ein
Schlüssel-Set, dessen Passphrase unter der **eigenen ID des verwalteten
Schlüssels** liegt. Dafür gibt es die vorhandene Probe, und sie **wirft**
statt `false` zu liefern, wenn sie nicht antworten kann. Diese Eigenschaft
bleibt erhalten.

### Und die zweite Hälfte, an der vier Runden gescheitert sind

**Ein werfender Read bricht ab. Ein `try?`-Read entscheidet nie über eine
Löschung.** Eine gesperrte Keychain sieht aus wie ein leeres Set; wer daraus
„nicht gedeckt" ableitet und trotzdem löscht, vernichtet ein intaktes
Secret. Wer daraus „gedeckt" ableitet, ebenso.

Dieselbe Regel gilt für die Deckungsprüfung selbst: kann sie nicht beantwortet
werden, wird **nicht gelöscht**.

## Was passiert, wenn nicht gedeckt ist

**Die Bindung findet statt, der Slot bleibt, der Nutzer erfährt es.**

Nicht verweigern: die Aufklärung hat gezeigt, dass eine Verweigerung Nutzer in
den Login-Set-Editor schickt — und der verlangt beim **Bearbeiten** das Secret
erneut, bevor Speichern freigeschaltet wird, selbst wenn nur der Name geändert
wird. Wer dorthin verweist, verweist in diese Reibung.

Nicht stillschweigend: bei `applyMerge` ist der Unterschied gravierend — statt
alle Slots zu löschen und ein leeres Set zu hinterlassen, bleibt jede Sitzung
verbindungsfähig.

Für `applyMerge` gilt zusätzlich das Muster, das dort bereits für den
Carry-Fehler existiert: **Set zurückrollen, nichts umhängen, nichts löschen,
melden.** Ein Merge, der die Secrets nicht übertragen kann, darf nicht die
halbe Arbeit tun.

## Zweiter Teil: der Import sagt es

Kommen beim Login-Set-Import Sets ohne Passwort an, nennt die Ergebnismeldung
ihre Anzahl — dieselbe Form, die die Exportseite bereits benutzt. Das ist die
Stelle, an der der Zustand entsteht; dass er heute unbemerkt entsteht, ist der
Grund, warum ihn später niemand erwartet.

## Was ausdrücklich **nicht** dazugehört

- **Der veraltete Slot einer set-gebundenen Sitzung wird nicht gelöscht.**
  Das war das Ziel des zurückgenommenen Fixes. Vier Anläufe haben gezeigt,
  dass genau die Löschung das Risiko trägt, und die Aufklärung hat gezeigt,
  dass der Zustand mild ist. Wer ihn später angeht, hat mit diesem Meilenstein
  die Bedingung, die er dafür braucht — aber es ist ein eigener Durchgang mit
  eigener Entscheidung.
- **Die drei nicht löschenden Binder bleiben unberührt.** Sie zu bewachen war
  der Fehler der vier Runden: dort ist nichts zu verlieren.
- **Bestehende Waisen einsammeln.** Braucht eine Keychain-Enumeration; zwei
  Meilensteine haben sie bewusst abgelehnt.
- **Die Editor-Reibung** (Secret erneut eintippen, um einen Namen zu ändern).
  Echter Befund, eigener Fix.

## Erfolgskriterien

| # | Kriterium | Nachweis |
|---|---|---|
| 1 | `applyMerge` löscht keinen Slot, wenn das Set das Secret nicht hält | Test: Set ohne Secret, Merge läuft, `storedIDs` aller Mitglieder unverändert |
| 2 | `applyMerge` bricht ab, statt bei nicht lesbarer Keychain zu löschen | Test mit werfendem Read: Set zurückgerollt, **kein** Slot angefasst, Fehler gemeldet |
| 3 | Die Jump-Bindung löscht den alten Jump-Slot nur bei gedecktem Set | Test je Deckungsfall |
| 4 | Alle fünf Konfigurationen werden korrekt unterschieden | ein Test je Zeile der Tabelle oben |
| 5 | Ein `.s3`-Set mit `authKind: agent` gilt **nicht** als gedeckt | der Test, der den letzten Anlauf gekippt hätte |
| 6 | Die Deckungsfrage stellt nie `LoginSet.authKind` | Review; im Code als Doc-Zusage |
| 7 | Ein unbeantwortbarer Deckungstest löscht nicht | Test mit werfender Probe |
| 8 | Der Import nennt die Zahl der Sets ohne Passwort | Test über den erzeugten Text |
| 9 | Kein Secret-Wert in Meldung, Log oder Testfehlertext | Review |
| 10 | Alle vier Kataloge tragen die neuen Schlüssel | der vorhandene Wächtertest |

## Test-Hinweise

- **Jede Löschung muss unter Mutation sichtbar verschwinden.** Wächter
  entfernen ⇒ der Test zeigt das Credential als weg, nicht bloß ein
  abweichendes Flag. Die vier gescheiterten Runden hatten Tests, die grün
  blieben, während der Verlustweg offen war.
- Die vorhandenen Doubles reichen: das In-Memory-Double mit seiner
  Mengen-Aufzählung für „nirgends ist etwas verschwunden", die
  fehlschlagenden Varianten für werfende Reads und Deletes.
- **Kriterium 5 ist der wichtigste Test des Meilensteins.** Er baut ein Set,
  dessen `kind` und `authKind` sich widersprechen — genau die Form, die der
  Import ungeprüft durchlässt.

## Für die Release-Notes

**Ein Satz.** Ein gespeichertes Passwort wird nicht mehr entfernt, wenn eine
Verbindung oder ein Sprungserver auf ein Login umgestellt wird, das selbst
keines hinterlegt hat.

## Offen, bewusst nicht Teil von M28

- Der veraltete Slot der set-gebundenen Sitzung (siehe oben).
- Die Editor-Reibung beim Bearbeiten eines Sets.
- Der app-weite Audit-Bereich.
- Der Release-Stau.
