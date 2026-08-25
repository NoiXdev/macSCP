# Backlog: Die App sollte gar nicht wählen können

**Angelegt:** 2026-08-22, nach vier Prüfrunden an einem Wächter. Ein
Architekturvorschlag, **kein Entwurf** — und eine Grenze, die ehrlich
benannt gehört.

## Was gesichert werden soll

Ein Wiederaufbau nach Verbindungsverlust muss durch **denselben**
Verbindungspfad laufen wie ein frischer Aufbau. Daran hängen TOFU als
harter Stopp, die Keychain-Regeln, das Auflösen von Login-Sets und die
Passphrasen-Abfrage. Ein zweiter Weg an dieser Stelle ist eine zweite
Gelegenheit, eine Sicherheitsregel zu vergessen.

## Was versucht wurde, und wie weit es trägt

Ein Quelltext-Wächter, in vier Runden immer weiter umgedreht:

1. **Delegation geprüft** — verankert an einer Funktion. Umgangen: der
   Zeitplan erreichte den Pfad an einer anderen Stelle.
2. **Erlaubnisliste der Aufrufstellen** — jede Wähl- und Übergabestelle muss
   benannt sein. Umgangen: die *Erkennung* war weiter eine Aufzählung —
   `.connect(` mit Klammer, eine feste Wurzelliste, ein Zeilenanfangs-Muster.
3. **Erkennung umgedreht** — Kategorie-Muster statt Namen, Wurzeln aus
   Dateisystem *und* `Package.swift` abgeleitet, positionsfreie Muster.
   Umgangen: ein **symbolisch verlinktes Verzeichnis** wird kompiliert, aber
   nicht durchlaufen.
4. **Symlinks geschlossen.** Und dann blieb der Fall, der bleibt.

## Die Grenze

**Ein Wählvorgang in Core unter anderem Namen, von der App aufgerufen, ist
textuell nicht erkennbar.** `QuickOpenHelper.open(config)` nennt kein
`connect`, keinen Backend-Typ, braucht keinen neuen Import. Core ist als
Wurzel ausgenommen, weil dort das Wählen **hingehört** — ein App-Aufruf in
eine beliebig benannte Core-Funktion sieht aus wie jeder andere Core-Aufruf.

Das zu fangen hieße zu wissen, welche Core-Funktionen wählen. Das ist
dasselbe Problem eine Ebene tiefer.

## Der Vorschlag

Nicht besser **beobachten**, sondern die Fähigkeit **entziehen**: die
App-Schicht kann eine Verbindung nicht herstellen, außer über einen Typ, den
sie halten muss und den nur der gemeinsame Pfad ausgibt. Dann ist „am Pfad
vorbei" kein Verstoß, den ein Test finden müsste, sondern etwas, das sich
nicht formulieren lässt.

Vor einem Entwurf zu klären: wo dieser Typ entsteht, wer ihn weitergeben
darf, und was er für CLI und Tests bedeutet — beide brauchen heute einen Weg
zur Verbindung, der nicht durch die App-Oberfläche führt.

## Warum es überhaupt hier steht

Vier Runden, vier Löcher, jedes in der Schicht, die noch niemand umgedreht
hatte. Die Lektion, die dabei am meisten wert ist:

> **Mutationstests belegen die Empfindlichkeit eines Wächters, nie seinen
> Geltungsbereich.**

Ein Wächter, der nach der Umsetzung geschrieben wird, ist auf die gerade
geschriebenen Zeilen zugeschnitten — und alle Mutationen, die man sich dazu
ausdenkt, stammen aus demselben Denkmodell. Was fehlt, ist die Frage
*woher könnte die Eigenschaft überhaupt verletzt werden*, und die stellt man
vor dem Schreiben oder gar nicht.

Zwei weitere Umgehungen sind bekannt und im Wächter selbst dokumentiert:
ein Keypath-Schreibzugriff und ein `Mirror`-Zugriff über Feldnamen. Beide
exotisch, beide benannt statt beschwiegen.

---

## Nachtrag 2026-08-25: Runde 6, und was sie über die Priorität sagt

Die Abschlussdurchsicht des Plans *gescheiterter Aufbau* hat den Wächter ein
sechstes Mal geschlagen — und diesmal **nicht** an der oben benannten
Grenze. Es war die *benannte, direkte* Form:

```swift
async let dialed = BackendDescriptor.descriptor(for: config.kind).connect(
    config, { _ in true }, { _ in true }, 30)
```

Ein roher Backend-Wählvorgang mit Akzeptiere-alles-Entscheidern, in einer
neuen App-Datei. Kompiliert, ganze Suite grün. Die Kontrollen im selben
Durchgang — dieselbe Zeile mit `await`, und ein `Task.detached` darum —
waren beide rot, der Scan erreichte die Datei also sehr wohl.

Der Grund: die Diskriminierung fragte nach dem **Wort** `await`, und
`async let` ruft eine `async`-Funktion auf, ohne es zu schreiben. Der
Suitenkommentar behauptete ausdrücklich das Gegenteil („jeder Wählvorgang in
diesem Projekt ist `async` und kann daher nicht ohne `await` aufgerufen
werden"), womit ein Leser der Lückenliste korrekt zu dem Schluss kam, diese
Form sei erfasst.

Geschlossen (die Diskriminierung kennt jetzt beide Schreibweisen), und die
Lückenliste sagt jetzt, was sie weiter nicht sieht.

**Was das für diese Notiz bedeutet.** Solange die Grenze oben als „ein Scan
kann eine umbenannte Core-Funktion nicht sehen" gelesen wurde, war sie
akademisch. Runde 6 zeigt, dass auch die direkte, benannte Form entkommt,
sobald die Schreibweise das Muster meidet — und dass die Behebung wieder
darin bestand, **die gerade gefundene Schreibweise aufzuschreiben**.

> Ein Scan über einer Sprache mit mehreren Schreibweisen pro Semantik
> verliert dieses Rennen dauerhaft. Nicht weil er schlampig ist, sondern
> weil er nur aufzählen kann, was jemand schon gedacht hat.

Sechs Runden, sechs Schreibweisen, jede aus dem Inneren der jeweils
vorherigen Runde vollständig aussehend. Das ist das Argument für die
Fähigkeitsgrenze — **höher zu priorisieren**, nicht ein siebtes Muster zu
ergänzen.
