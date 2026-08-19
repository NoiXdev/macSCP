# M33 — Der eigene Slot einer gebundenen Sitzung (Design)

Stand 2026-08-19. „Schaden 1" aus der M30-Spec, dort bewusst ausgeklammert.

## Der Befund

Eine Sitzung, die an ein Login-Set gebunden ist, behält ihren eigenen
Schlüsselbund-Slot. Er ist unsichtbar (das Formular lädt Geheimnisse nie),
unbenutzt (der Connect löst über das Set auf) und hat kein Verfallsdatum.

Seit M30 kann er nicht mehr stillschweigend wieder aktiv werden — beim
Verlassen des Set-Modus verlangt der Validator ein neues Geheimnis. Was
bleibt, ist ein Zugangsdatum, das der Nutzer für abgelöst hält und das
trotzdem im Schlüsselbund liegt.

## Warum vier Anläufe gescheitert sind

Alle vier (2026-08-09, zurückgenommen in `479d018`) haben **beim Binden**
gelöscht. Das ist der schlechteste denkbare Moment: in ihm weiß niemand, ob
das Set überhaupt ein brauchbares Geheimnis hält. Ein Set aus einem Import
ohne Secrets, ein Set, dessen eigener Slot leer ist, ein `authKind`, der
nicht zum `kind` passt — jede Runde schloss einen dieser Wege und öffnete
einen neuen, und jeder endete damit, die einzige Kopie eines Zugangsdatums
zu vernichten.

**Der Ausweg ist nicht ein besserer Wächter, sondern ein anderer Moment.**
Ein späterer Durchgang kann prüfen, was zur Bindezeit unbekannt war: ob das
Set für diese Sitzung tatsächlich ein Geheimnis auflöst.

## Der Entwurf

**Ein Aufräum-Durchgang, vom Nutzer angestoßen**, in „Einstellungen › Daten
verwalten" — derselbe Ort und dieselbe Bauart wie M27s Durchgang für
verwaiste Jump-Slots.

**Kandidaten.** Sitzungen mit `loginSetID != nil`, die einen nicht-leeren
eigenen Slot halten. Abgeleitet aus `sessions.json`, nicht aus einer
Aufzählung des Schlüsselbunds — `SecretStore` hat bewusst keine, und eine
Kandidatenliste aus dem Bestand kann keine fremde ID treffen.

**Der Wächter, der allen vier Anläufen fehlte.** Ein Slot wird nur gelöscht,
wenn das gebundene Set für diese Sitzung ein **nicht-leeres** Geheimnis
auflöst. Löst es nichts auf — Set ohne Secret, Set gelöscht, Schema ohne
sichtbares Geheimfeld —, bleibt der Slot liegen. Er ist dann nämlich
möglicherweise die einzige Kopie.

**Womit geprüft wird — nachgemessen 2026-08-19.**
`SessionListViewModel.resolvedCredentials(for:)` ist genau dieser Wächter:
sie löst über das Set auf, liefert die Werte samt Geheimnis und **wirft**
bei einer baumelnden `loginSetID`, statt still auf die eigenen Daten der
Sitzung zurückzufallen (Spec §2 aus M22/T9). Ein Fehlschlag ist damit
strukturell von „das Set hält nichts" unterscheidbar — die Unterscheidung,
an der alle vier Anläufe gescheitert sind. Ob das aufgelöste Geheimnis
nicht-leer ist, beantwortet
`BackendDescriptor.visibleSecretField(for: session)` über den zugehörigen
Schlüssel im Feldbeutel.

**Fehlgeschlagene Lesevorgänge sind kein „nichts da".** Jeder Lesefehler
führt zum Überspringen dieses Kandidaten, nie zu einer Löschung. Das ist
dieselbe Regel, die M28/T2 für `applyMerge` durchgesetzt hat: ein
Schlüsselbund, der nicht antwortet, sieht sonst aus wie eine Sammlung
leerer Slots.

**Das Geheimnis des Sets wird nie angefasst.** Der Durchgang entfernt
ausschließlich Slots von Sitzungen, und ausschließlich solche, für die
nachweislich ein Ersatz existiert.

**Rückmeldung.** Der Durchgang liefert die Zahl entfernter Slots; die
App-Schicht rendert sie über den vorhandenen Plural-Katalog, der dort
existiert. Null entfernte Slots ist ein normales Ergebnis und wird als
solches gemeldet, nicht als Fehler.

## Tests

Vier Fälle, die zusammen die Regel in beide Richtungen festnageln:

1. Gebundene Sitzung, Set löst ein Geheimnis auf → Slot ist weg.
2. Gebundene Sitzung, Set löst **nichts** auf → Slot bleibt. **Das ist der
   Test, den die vier Anläufe nicht bestanden hätten.**
3. Ungebundene Sitzung mit eigenem Slot → unberührt.
4. Lesefehler beim Set → Slot bleibt.

Fall 1 ist zugleich die Positivkontrolle: ohne ihn wären 2–4 auch von einem
Durchgang erfüllt, der überhaupt nichts löscht.

## Was nicht dazugehört

- **Kein automatisches Aufräumen.** Weder beim Binden noch beim Start. Der
  Nutzer stößt es an und sieht das Ergebnis — bei einer Operation, die
  Zugangsdaten entfernt, ist das keine Bequemlichkeitsfrage.
- **Keine Änderung am Bindepfad.** Er bleibt genau so, wie M28 und M30 ihn
  hinterlassen haben.
- **Keine Aufzählungs-API für `SecretStore`.** Ihr Fehlen ist eine bewusste
  Grenze und zugleich der Grund, warum die Kandidaten aus dem Bestand
  kommen müssen.
