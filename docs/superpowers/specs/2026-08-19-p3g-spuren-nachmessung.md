# P3g — die zwei ungeprüften Spuren nachgemessen (2026-08-19)

Der P3g-Abschluss ließ zwei Vermutungen offen, weil sie zum Zeitpunkt des
Reviews nur plausibel, aber nicht gemessen waren. Beide sind jetzt
nachgemessen. Eine war falsch, eine war echt.

## Spur 1: Passwort im erzeugten ssh-Kommando — falsch

Vermutung war, `SSHCommandBuilder` könnte ein Passwort ins Kommando
schreiben. Gemessen: tut er nicht, an keiner Stelle. Das Kommando enthält
grundsätzlich kein Geheimnis; `ssh` fragt selbst interaktiv danach. Die
Spur führte trotzdem zu etwas: `ConnectionViewModel.lastConnectedConfig`
hielt bis dahin die vollständige Config inklusive Passwort-Payload über
den Connect hinaus. Das ist mit `redactingSecrets()` behoben (die
Auth-*Case* bleibt erhalten, weil Aufrufer darauf verzweigen).

## Spur 2: Passphrase-Duplikat beim Bearbeiten-Speichern — echt

Vermutung war, der Edit-Save-Pfad könnte ein Geheimnis doppelt ablegen.
Gemessen: tut er. Beim Anlegen einer Sitzung entscheidet
`SessionSecretPolicy.valueToPersist`, dass die Passphrase eines
verwalteten Schlüssels **nicht** zusätzlich in den Sitzungs-Slot wandert.
Beim Bearbeiten wurde diese Frage gar nicht gestellt — die Passphrase
landete in einem zweiten Slot, und eine spätere Änderung an einer Kopie
ließ die andere veraltet zurückbleiben.

Behoben in `9847d8b`: `updateSession` stellt dieselbe Frage über eine
neue `usesStoredManagedPassphrase(session:keys:secrets:)`-Überladung, die
den persistierten `AuthKind` direkt liest statt über die
hauptaktor-isolierte Presentation-Schicht zu gehen. Der Guard sitzt im
ViewModel, nicht bei den Aufrufern — gleiche Begründung wie beim
Jump-Secret-Invariant daneben: ein künftiger Aufrufer kann ihn nicht
vergessen.

Zwei neue Tests in `SessionSecretPolicyTests`: verwalteter Schlüssel mit
hinterlegter Passphrase bekommt keinen Sitzungs-Slot, ohne hinterlegte
Passphrase bekommt er einen.

## Nebenbefund: ein Test, der nur außerhalb der Suite grün war

Der Delivery-Test aus P5 Task 3 wartete mit einem festen 80-ms-Schlaf
darauf, dass die Shell öffnet. Allein gelaufen immer grün, in der vollen
Suite etwa jeder dritte Lauf rot. Ein explizites Gate ersetzt den Schlaf
(`66ea90e`); danach 6 volle Suite-Läufe und 6 isolierte Läufe grün. Bei
der vorherigen Rate wäre das zu rund 9 % Zufall — Indiz, kein Beweis.
Deshalb nennt die Erwartung jetzt zusätzlich, ob die Bytes überhaupt bei
der Shell ankamen: ein künftiger Fehlschlag sagt sofort, welche Hälfte
fehlt.

## Lektion

Beide Spuren bestätigen dieselbe Regel wie schon P3e/P3f/P3g: **erst
messen, dann entwerfen.** Die Hälfte der plausiblen Vermutungen ist
falsch, und die andere Hälfte ist selten genau das, was vermutet wurde —
Spur 1 war falsch, hat aber ein anderes echtes Leck aufgedeckt.

Dazu eine neue, teurere Lektion: **ein Test, der nur in der vollen Suite
rot wird, ist gefährlicher als ein Test, der immer rot ist.** Er war
bereits committet und in der CI grün durchgelaufen, bevor die Sprödigkeit
auffiel.
