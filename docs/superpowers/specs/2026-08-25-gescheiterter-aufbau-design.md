# Gescheiterter Verbindungsaufbau: eigene Fläche statt Rückfall aufs Formular

**Stand:** Entwurf, vom Maintainer abgenommen 2026-08-25 (Sichtprüfung am
gebauten Bundle).

## Der Befund

Ein **Abriss** zeigt seit dem Verbindungszustands-Zweig eine Fehleransicht
im Tab. Ein **gescheiterter Aufbau** tut das nicht: `ConnectionSurfacePlan`
bildet nur den Zustand ab, und ein fehlgeschlagener Versuch hinterlässt
`liveness == nil`, was auf `.form` abbildet. Der Tab fällt also aufs
Formular zurück, als sei nichts gewesen.

Maintainer-Wortlaut: *„wenn dann gleich verbinden wieder kommt ist man eher
verwirrt."* Man wollte verbinden, es ging nicht, und statt einer Auskunft
steht wieder die Eingabemaske da.

**Das ist meine Entscheidung aus Task 6 gewesen**, begründet damit, dass der
Fehlertext „schon immer" im Formular gewohnt habe. Die Begründung stimmt und
trägt trotzdem nicht: sie erklärt, wo der Text liegt, nicht warum die Fläche
wechseln soll.

## Die Fläche

Eigene Meldung, nicht dieselbe wie beim Abriss — „Verbindung verloren" wäre
falsch, es bestand nie eine. Vorschlag: **„Keine Verbindung möglich"**, dazu
ein allgemeiner Satz ohne technische Einzelheiten.

Vier Handlungen:

| Handlung | Wirkung | Sichtbar |
|---|---|---|
| **Erneut versuchen** | derselbe Verbindungspfad wie ein frischer Aufbau | immer |
| **Bearbeiten** | Formular, mit den Werten vorausgefüllt | immer |
| **Sitzung bearbeiten** | der Sitzungs-Editor, dauerhafte Änderung | nur bei gespeicherter Sitzung |
| **Schließen** | Tab schließen | immer |

Dazu ein **Details-Dialog** mit der vollständigen technischen Meldung —
Maintainer-Entscheidung: allgemeine Meldung auf der Fläche, alles Genaue in
einem Dialog fürs Debuggen.

Warum beide Bearbeiten-Wege: ein einmaliger Tippversuch („liegt es am
Port?") soll die gespeicherte Sitzung nicht verändern; ein echter Fehler in
der Sitzung soll dauerhaft korrigierbar sein. Das sind zwei Absichten, und
eine Fläche, die nur eine anbietet, zwingt zur falschen.

## Auflage für den Details-Dialog

Der Dialog zeigt die Meldung der darunterliegenden Schicht. Er darf
enthalten, was der Nutzer selbst eingegeben oder gespeichert hat — Host,
Port, Benutzername — und **niemals ein Geheimnis**: kein Passwort, keine
Passphrase, kein Schlüsselmaterial, auch nicht in einem eingebetteten
Fehlertext einer Bibliothek.

Das ist keine Formsache: die Projektregel „kein Geheimnis in Protokoll,
Export, Fehlermeldung oder Testfehlertext" gilt hier zum ersten Mal für eine
Fläche, die einen **rohen** Fehlertext zeigt. Alle bisherigen Flächen des
Zweigs waren baulich sicher, weil sie nur feste Schlüssel trugen. Diese ist
es nicht — sie braucht eine geprüfte Bereinigung.

## Was unverändert bleibt

- **Erneut versuchen** läuft durch **denselben** Verbindungspfad wie ein
  frischer Aufbau. TOFU bleibt ein harter Stopp, die Keychain-Regeln bleiben.
  Der Wächter des Zweigs deckt das bereits ab und muss die neue Aufrufstelle
  mit erfassen.
- Der Abriss-Fall (`.lost`) und seine Texte bleiben, wie sie sind. Diese
  Fläche kommt daneben, nicht an seine Stelle.
- Eine offene Host-Schlüssel-Abfrage überschreibt weiterhin jede Fläche.

## Abgrenzung

Ein Aufbau, der an einer **Frage** scheitert, die nur ein Mensch beantworten
kann (geänderter Host-Schlüssel, fehlende Passphrase), hat bereits einen
eigenen Weg und wird davon nicht berührt. Diese Fläche ist für das, was
`lastFailureKind == .other` bedeutet: Zeitüberschreitung, Namensauflösung,
abgewiesen.

## Prüfbarkeit

Welche Handlungen bei welchem Zustand erscheinen und welche Meldung gilt,
gehört in einen prüfbaren Wert neben `LostConnectionPlan` — die Fläche
selbst zeichnet nur. Die Bereinigung des Details-Textes gehört gegen echte
Fehlerwerte geprüft, nicht gegen erfundene.
