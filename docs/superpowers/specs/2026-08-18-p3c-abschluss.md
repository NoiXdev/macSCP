# P3c — Abschluss: Terminal aus dem Host-Kontextmenü

Abgeschlossen 2026-08-18. Drei inhaltliche Commits plus zwei Ledger-Docs:

```
267930c refactor(core): resolve a connection config without dialing it
1081142 refactor(core): keep the save-name rule out of the shared resolution
af2de15 feat(app): open a terminal straight from a host's context menu
4b3cb35 docs(app): record context-menu export everywhere as P3f
547dcef docs(app): record the retained password-hint config as P3g
```

## Wie die Auflösung geteilt wird

`ConnectionViewModel.resolveConfigWithoutDialing() -> ConfigResolution`
(`Sources/macSCPCore/Presentation/ConnectionViewModel.swift`) enthält alles,
was `connect()` vor dem Dial tut, und nichts sonst: die Schema-Prüfung
(`descriptor.firstViolation(requireSecrets: true)`), `validateJump`,
`descriptor.makeConfig` und `attachingJump(to:)`. `connect()` behält nur den
Re-Entrancy-Guard, die Save-Name-Prüfung, `state = .connecting`, den Dial samt
Host-Key-Decider und die `lastConnectedConfig`-Aufzeichnung; es wiederholt
keinen Auflösungsschritt.

`ConfigResolution` ist ein eigener Rückgabetyp (`.resolved(ConnectionConfig)`
/ `.failed(State)`), kein optionales `ConnectionConfig?`: der Fehlerfall
trägt den exakten `State`, den `connect()` sonst zuweisen würde, damit die
Fehlerabbildung (Meldung + Feld) an einer Stelle bleibt. Die Funktion
**veröffentlicht nichts** — ein Fehlschlag wird zurückgegeben, nicht in
`state` geschrieben, sonst würde eine extern ausgelöste Auflösung das
`.connecting` überschreiben, das ein laufendes `connect()` besitzt — und
**behält nichts**: das aufgelöste Klartext-Secret gehört dem Aufrufer für die
Dauer seines Aufrufs, `lastConnectedConfig` wird weiterhin ausschließlich von
einem erfolgreichen `connect()` geschrieben.

Der **Äquivalenz-Wächter** (`Tests/macSCPCoreTests/ConnectionConfigResolutionTests.swift`,
8 Tests) füllt zwei identisch konfigurierte View-Models — eines wählt, eines
löst nur auf — und vergleicht, was das eine gewählt hat, mit dem, was das
andere aufgelöst hat. Er geht rot, wenn `connect()` wieder selbst irgendetwas
auflöst. Er hält aber **nicht** das Verhalten der geteilten Funktion selbst
fest: `connect()` delegiert an sie, also bewegt eine Änderung dort beide
Seiten des Vergleichs gleichzeitig mit — dafür stehen die fallweisen
Zusicherungen (Hop-Host/-Port, jede Fehlermeldung samt Feld) daneben, nicht
der Wächter.

## Warum die Save-Name-Regel nicht in der geteilten Funktion steht

Ein Formular trägt legitim `shouldSaveSession == true` mit leerem
Speichern-Namen, während der Nutzer eine Ad-hoc-„Speichern & Verbinden" noch
tippt — das ist kein Fehlerzustand der Konfiguration, sondern eine
Buchhaltungsregel des Formulars. Der Kontextmenü-Aufrufer speichert nichts
und dürfte für eine Regel, die ihn nicht betrifft, nicht abgewiesen werden.
Die Prüfung steht deshalb weiterhin in `connect()`, vor dem Aufruf von
`resolveConfigWithoutDialing()`.

(Task 1 hatte diesen Punkt zunächst umgekehrt umgesetzt und begründet — die
Save-Name-Prüfung anfangs *in* der geteilten Funktion. Die Review widerlegte
die Begründung, der Fix landete in `1081142`, per Mutation nachgewiesen:
Regel zurückschieben → Wächter rot; eine Mutation innerhalb der geteilten
Funktion → Äquivalenztests bleiben grün, die fallweisen fangen sie. Der
Task-1-Bericht wurde dazu nachträglich vom Koordinator korrigiert; der Code
und dieser Abschluss folgen der Korrektur.)

## Die zwei Kontextmenü-Einträge

Unter „Verbinden" in der Sitzungszeile:

- **„Terminal öffnen"** (`ContentView.openTerminalFromSidebar`) — verbindet
  in macSCP wie `connect()`/`connectFromSidebar` (Zielwahl, Re-Entrancy,
  Füllen, Fehleranzeige — alles unverändert), nur mit
  `paneVisibility: .terminalOnly` statt der gespeicherten Aufteilung. Nichts
  wird persistiert.
- **„In externem Terminal öffnen"** (`ContentView.openExternalTerminalFromSidebar`)
  — füllt ein **Wegwerf-`ConnectionViewModel`** (lokal, Connector wirft),
  löst darauf `resolveConfigWithoutDialing()` auf und übergibt an den
  eingestellten externen Terminal-Client. macSCP baut dabei keine eigene
  Verbindung auf; das Wegwerf-Objekt überlebt den Aufruf nicht, damit das
  aufgelöste Klartext-Secret keinen zweiten Ort bekommt.

Sichtbarkeitsregel: `SessionRowTerminalMenuPlan.build(for:)`
(`Sources/MacSCPAppKit/SessionSidebar.swift`) — `.shown`, wenn
`BackendDescriptor.capabilities.supportsShell` zutrifft, sonst `.hidden`.
Beide Einträge werden **ausgeblendet, nicht ausgegraut**, wenn eine Sitzung
keine Shell hat: ein dauerhaft toter Eintrag an einem S3-Bucket erklärt
nichts.

Das Füllen des Formulars (~240 Zeilen: Kind/Values, Login-Set-Auflösung,
Keychain, Managed-Key-Passphrase, Jump-Auflösung) war inline in
`connect(in:stored:)` und wurde nach `ContentView.fillForm(_:from:) throws
-> Bool` gezogen — beide Wege (Sidebar-Connect wie externer Start) rufen
dieselbe Funktion. Die Verbatim-Eigenschaft dieser Extraktion wurde
**mechanisch**, nicht durch einen Test geprüft: ein `diff` des extrahierten
Blocks gegen den vorherigen Inline-Code zeigt exakt **sieben** Zeilen
Unterschied, alle `return` → `return false`, plus Signatur und
abschließendem `return true`. `ContentView` ist aus den Tests nicht
instanziierbar (kein Rendering-Werkzeug im Projekt), ein Test war hier also
strukturell nicht möglich — der `diff` plus die grüne volle Suite sind der
Ersatz.

## Zurückgestellt: P3g

Aus der Gesamtprüfung von Task 2: `pendingPasswordHintRequest`
(`ContentView.swift`) kann eine `SSHConnectionConfig` mit einem
Klartext-Passwort halten, solange der einmalige Passworthinweis-Alert offen
ist. Beide Alert-Knöpfe und jede SwiftUI-Auflösung des Dialogs setzen sie auf
`nil` — aber `disconnect` und `clearRetainedSecrets` erreichen sie nicht.
Vorbestehend seit M11d; diese Phase weitet den Zustand aus, weil der externe
Weg jetzt auch für eine Sitzung erreichbar ist, mit der sich macSCP **nie**
verbindet. Genau das, wovor der Doc-Kommentar von
`resolveConfigWithoutDialing` warnt. Als eigene, kleine Phase P3g im Nachtrag
der Spec (`docs/superpowers/specs/2026-08-18-p3-ordnung-design.md`) und im
Commit `547dcef` festgehalten — kein Blocker, kein Teil dieser Phase.

## GUI: nicht gestartet

Die App wurde in dieser Phase **nicht** gestartet. Für den Maintainer, zur
Verifikation von Hand:

- Beide Einträge erscheinen am Kontextmenü einer gespeicherten **SSH**-Sitzung.
- **Keiner** der beiden Einträge erscheint an einer **S3**- oder
  **WebDAV**-Sitzung.
- „Terminal öffnen" kommt ohne Dateibrowser hoch — nur das Terminal.
- „In externem Terminal öffnen" zeigt beim ersten Mal den Passworthinweis
  (bei Passwort-Auth), wie der bestehende Toolbar-Weg auch.

## Messung

```
swift test          → 2076 tests in 178 suites, alle grün
plutil -lint         → alle acht *.strings-Kataloge OK
```

Unverändert gegenüber Task 2 (2076/178) — kein Test kam zwischen Task-2-Abschluss
und diesem Abschluss hinzu oder ging verloren.

## Build-Verifikation (`scripts/package-app`, im Hintergrund gestartet)

```
lipo -archs dist/macSCP.app/Contents/MacOS/macSCP      → x86_64 arm64
lipo -archs dist/macSCP.app/Contents/MacOS/macscp-cli  → x86_64 arm64
Resources/*.bundle                                      → macSCP_MacSCPAppKit.bundle, macSCP_macSCPCore.bundle
Resources/*.lproj                                        → de, en, fr, pl (alle vier)
plutil -lint Info.plist                                  → OK
UTExportedTypeDeclarations                                → 3 (dev.noix.macscp.sessions, .logins, .snippets)
```

Die App wurde **nicht** gestartet; `scripts/release` wurde nicht ausgeführt.

## Brief-Fehler

Der Auftrag dieser Phase enthielt keinen neuen Fehler gegenüber dem, was das
Ledger bereits festhält (die vierzehnte Fehlbenennung von
`resolveConfigWithoutDialing()` in Plan und Brief von Task 2, dort schon
korrigiert). Der Task-1-Bericht selbst blieb nach dem Fix `1081142`
unkorrigiert stehen und widerspricht dem heutigen Code in einem Punkt (Ort
der Save-Name-Prüfung) — der Koordinator-Nachtrag am Ende dieses Berichts
klärt das; dieser Abschluss folgt durchgehend dem Code, nicht dem
unkorrigierten Abschnitt.
