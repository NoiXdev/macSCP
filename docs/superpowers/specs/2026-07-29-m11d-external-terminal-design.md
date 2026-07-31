# M11d — Externes Terminal (Design)

Datum: 2026-07-29 · Status: vom Maintainer freigegeben („ja los gehts")

## Ziel

Die SSH-Sitzung wahlweise im eingebauten Terminal ODER in einer externen
Terminal-App öffnen (Terminal.app, iTerm, frei wählbare App).

**Maintainer-Entscheidungen (2026-07-29):**

1. Bei Verbindungen mit gespeichertem PASSWORT wird trotzdem geöffnet;
   `ssh` fragt dort selbst. Beim ersten Mal ein Hinweis mit „nicht mehr
   anzeigen". Das Passwort verlässt NIE den Schlüsselbund — kein
   Weiterreichen, kein Kopieren in die Zwischenablage (ausdrücklich
   abgelehnt: die Zwischenablage ist für jede laufende App lesbar).
2. Start über ein kurzlebiges `.command`-Skript + `open -a`, NICHT über
   AppleScript.

## 1. Befehlsbau (Core, pur)

- `SSHCommandBuilder.arguments(for config: SSHConnectionConfig) -> [String]`
  — reine Funktion, liefert die `ssh`-ARGUMENTLISTE (kein String):
  - `-p <port>` nur wenn `port != 22`
  - `-l <username>`
  - `-i <keyPath>` nur bei `authKind == .privateKey`
  - `-J <user>@<host>[:<port>]` wenn ein Jump gesetzt ist (Port nur wenn
    != 22). Der Jump ist zu diesem Zeitpunkt bereits aufgelöst — bei
    einem Session-referenzierten Jump (M11a) liefert die App die
    aufgelösten Werte.
  - Agent-Auth (`.agent`) braucht KEIN Argument (`ssh` findet den Agent
    über `SSH_AUTH_SOCK` selbst).
  - zuletzt der Host.
- Passwörter tauchen NIRGENDS auf (weder Argument noch Umgebung).
- `SSHCommandBuilder.shellCommand(for:) -> String` setzt jedes Argument
  EINZELN in Single-Quotes und maskiert enthaltene Quotes nach dem
  POSIX-Muster (`'` ⇒ `'\''`). Damit sind Leerzeichen und Sonderzeichen
  in Pfaden/Benutzernamen kein Einfallstor.

## 2. Skript + Start (App)

- `TerminalScriptWriter` (App-Schicht, aber der INHALT kommt aus einer
  reinen Core-Funktion `SSHCommandBuilder.scriptContents(for:)`):
  Shebang `#!/bin/sh`, Selbstlöschung (`rm -f -- "$0"` unmittelbar vor
  dem `exec`, damit das Skript auch bei langer Sitzung nicht liegen
  bleibt), dann `exec ssh <quoted args>`.
- Ablage: `<temp>/macscp-terminal/<uuid>.command`, Rechte 0700 (nur der
  Benutzer). Sweep beim App-Start wie die Editor-Temp-Dateien aus M5e
  (dasselbe Muster, eigener Unterordner).
- Start: `NSWorkspace.shared.open([scriptURL], withApplicationAt: appURL,
  configuration:)` bzw. `open -a`-Äquivalent. Funktioniert mit JEDER
  Terminal-App; KEINE AppleScript-Automatisierung, daher KEINE
  zusätzliche TCC-/Automation-Berechtigung nötig (die App ist nicht
  sandboxed, läuft aber mit Hardened Runtime — eine AppleScript-Lösung
  bräuchte `com.apple.security.automation.apple-events` plus
  Nutzer-Zustimmung und app-spezifische Skripte).

## 3. Einstellung + Bedienung

- `SettingsStore.terminalTarget: TerminalTarget`
  (`enum TerminalTarget: String, Codable`: `builtIn`, `terminalApp`,
  `iTerm`, `custom`) plus `customTerminalAppPath: String?`.
  Vorwärtskompatibel (alte `settings.json` ⇒ `builtIn`).
- Terminal-Tab der Einstellungen: Auswahl `Eingebaut | Terminal.app |
  iTerm | Eigene App…` (bei „Eigene App" ein `fileImporter` auf
  `/Applications`, gespeichert wird der Pfad).
- Die Einstellung bestimmt, was **⌘T** und der Toolbar-Knopf tun.
- ZUSÄTZLICH immer beide Wege explizit erreichbar: ein Menüeintrag
  „Im externen Terminal öffnen" (auch bei `builtIn`) und — bei
  eingestelltem externen Ziel — bleibt das eingebaute Terminal über
  einen eigenen Eintrag erreichbar. Niemand verliert eine Fähigkeit
  durch die Einstellung.
- Passwort-Verbindungen: öffnen trotzdem; beim ERSTEN Mal ein Hinweis
  („macSCP kann das gespeicherte Passwort nicht an ein externes Terminal
  übergeben — `ssh` fragt dort selbst danach.") mit „Nicht mehr
  anzeigen", persistiert als `externalTerminalPasswordHintShown: Bool`.

## 4. Fehler ehrlich

- Gewählte App nicht vorhanden (deinstalliert, Pfad ungültig) ⇒ konkrete
  Meldung mit dem Namen/Pfad; KEIN stiller Rückfall auf eine andere App
  und KEIN stiller Wechsel auf das eingebaute Terminal.
- Skript-Schreibfehler ⇒ eigene Meldung.
- Beides sind eigene typisierte Fälle, keine Sammel-Fehlermeldung.

## 5. Tests

- Argumentbau: Passwort-Auth (nur `-l` + Host), Key-Auth (`-i`),
  Agent-Auth (kein Extra-Argument), Port 22 vs. abweichend, Jump mit und
  ohne abweichenden Port, Jump + Key gleichzeitig.
- Quoting: Leerzeichen im Key-Pfad, Single-Quote im Benutzernamen,
  Semikolon/Backtick im Host (Ergebnis muss unschädlich sein).
- Skript-Inhalt: Shebang, Selbstlöschung vor `exec`, exakt ein `exec ssh`,
  kein Passwort-Vorkommen.
- KEIN Test startet einen Prozess oder öffnet eine App.
- Settings: Vorwärtskompatibilität (altes JSON ⇒ `builtIn`), Roundtrip
  aller Fälle inkl. `custom` + Pfad.

## 6. Aufteilung

T1 Core (Argumentbau, Quoting, Skript-Inhalt) → T2 App (Settings-Auswahl,
Start, Menüeinträge, Passwort-Hinweis, Fehlerfälle, Sweep, EN/DE) →
T3 Abschluss. KEIN Release.

## 7. Bewusst NICHT in M11d

Kein Weiterreichen von Passwörtern (auch nicht über Zwischenablage,
Umgebungsvariable, `sshpass` o. Ä.); kein AppleScript und keine
app-spezifische Automatisierung; kein Öffnen im aktuellen
Arbeitsverzeichnis des Remote-Panes (Backlog: `-t "cd … && exec $SHELL"`);
keine Übernahme der Terminal-Darstellungseinstellungen (Schrift/Cursor
gelten weiter nur fürs eingebaute Terminal).
