# Backlog: CLI — Autovervollständigung, Hilfe, Host-Liste

**Angelegt:** 2026-08-20, aus Maintainer-Zuruf. Gesicherte Ideen, **kein Design**.

## Ausgangslage, gemessen

`macscp-cli` ist klein: **430 Zeilen**, fünf Unterbefehle (`ls`, `get`, `put`,
`mkdir`, `rm`) auf `swift-argument-parser`. Sitzungen werden als
`name:/pfad` referenziert. `--json` gibt es bereits (in `SessionConnecting`,
also für alle verbindenden Befehle).

**Es gibt keinen Befehl, der Sitzungen auflistet.** Wer den Namen nicht
auswendig weiß, muss die App öffnen.

Jeder Befehl hat einen einzeiligen `abstract`, **keiner** hat ein
`discussion`. Die `name:/pfad`-Schreibweise wird nirgends als Konzept
erklärt, sondern nur in einzelnen Argument-Hilfetexten beispielhaft gezeigt.

## 1. Host-Liste mit Filtern — zuerst bauen

Ein Unterbefehl, der die gespeicherten Sitzungen ausgibt, mit Filter-Argumenten
(Gruppe, Backend-Art, Namensmuster). `--json` ist als Muster bereits gesetzt
und sollte hier gelten.

**Sicherheitsauflage, nicht verhandelbar:** die Auflistung darf **keine
Geheimnisse** ausgeben und **den Keychain nicht anfassen**. Sie liest den
Sitzungs-Store, der per Projektinvariante keine Geheimnisse enthält. Kein
Auflösen von Login-Sets, keine Passphrasen-Abfrage, kein Verbindungsaufbau —
die Liste ist eine reine Store-Abfrage.

**Warum zuerst:** Punkt 2 braucht genau diese Abfrage. Baut man die
Vervollständigung zuerst, entsteht die Auflistungslogik zweimal.

## 2. Autovervollständigung

**Der halbe Weg ist schon gegangen.** `swift-argument-parser` erzeugt
Completion-Skripte für bash, zsh und fish von sich aus
(`--generate-completion-script`), und die Fehlerbehandlung in
`MacSCPCLI.main()` behandelt eine Completion-Anforderung bereits wie eine
Hilfe-Anforderung (Beendigungscode 0). Es fehlt also nicht der Mechanismus,
sondern zweierlei:

1. **Ausliefern und Einrichten.** Das Skript muss beim Nutzer landen. Zu
   klären: erzeugt das Installationsskript es mit, oder dokumentieren wir nur
   den Befehl? Die CLI liegt im App-Bundle und wird per Symlink erreichbar
   gemacht — das ist der Ort, an dem sich das entscheidet.
2. **Dynamische Werte.** Sitzungsnamen kommen aus dem Store, nicht aus einer
   festen Liste; dafür gibt es `@Argument(completion: .custom { … })`.

**Die Entwurfsfrage, die vor dem Bau beantwortet werden muss:** wie weit geht
die Vervollständigung?

- **Sitzungsnamen** sind lokal, billig und gefahrlos. Klarer Fall.
- **Entfernte Pfade** hinter dem Doppelpunkt wären der eigentliche Komfort —
  aber ein Druck auf Tab würde dann **eine Verbindung aufbauen**. Das ist
  langsam, überraschend, und kann in einer nicht-interaktiven Shell auf eine
  TOFU-Entscheidung laufen, die niemand beantworten kann. Empfehlung:
  zunächst **nur Sitzungsnamen**; entfernte Pfade allenfalls später und
  ausdrücklich eingeschaltet.

## 3. Hilfe, die erklärt, wie man es benutzt

Die Einzeiler beschreiben, was ein Befehl tut, nicht wie man ihn aufruft.
Konkret fehlt:

- Ein `discussion` am **Wurzelbefehl**, das die `name:/pfad`-Schreibweise
  einmal als Konzept erklärt — inklusive des Hinweises, woher die Namen
  kommen (Punkt 1 liefert dann den Befehl, der sie zeigt).
- Beispielaufrufe je Unterbefehl. `swift-argument-parser` nimmt sie im
  `discussion` entgegen.
- Ein Wort dazu, dass die CLI **im App-Bundle** liegt und wie man sie in den
  Pfad bekommt — steht heute nur in der README, nicht in der Hilfe selbst.

## Reihenfolge

**1 → 3 → 2.** Die Auflistung ist die Datenquelle für die Vervollständigung
und gleichzeitig das, worauf die Hilfe verweisen will. Die
Vervollständigung kommt zuletzt, weil sie als einzige eine Auslieferungsfrage
aufwirft.
