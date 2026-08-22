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
