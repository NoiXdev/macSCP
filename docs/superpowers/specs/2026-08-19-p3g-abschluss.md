# P3g — Abschluss

**Ziel:** Der Passworthinweis hält kein Klartext-Geheimnis mehr.
**Stand:** fertig. Suite 2110 Tests in 183 Suiten, grün.

## Was die Messung an der Spec korrigiert hat

Die Spec nahm an, das Startskript enthalte ein Passwort — der Doc-Kommentar
über `requestExternalTerminal(config:)` behauptete das ausdrücklich. Beides
war falsch. `SSHCommandBuilder` liest Host, Port, Benutzername,
Schlüssel*pfad* und Jump-Ziel; ein Geheimnis übergibt er nie, `ssh` fragt
selbst danach — genau das sagt auch der Hinweistext, den die App anzeigt.

Damit war die Reparatur nicht „noch ein Aufräumpfad", sondern: das
Geheimnis gar nicht erst zurückhalten. `redactingSecrets()` liefert eine
Kopie ohne Klartext-Nutzlasten; die Auth-Art selbst überlebt, weil Aufrufer
auf sie verzweigen. Der Zustand „Hinweis offen und Passwort im View-State"
ist jetzt nicht aufgeräumt, sondern nicht darstellbar.

## Was die Gesamtprüfung fand — und was daraus wurde

Die Phase hatte die **kleinere** der zwei Instanzen repariert.
`lastConnectedConfig` hielt dasselbe Klartext-Passwort **die ganze
Sitzung** statt der Sekunden eines offenen Alerts — und war auf der
Toolbar-Route die Quelle der Konfiguration, die in den Hinweis fließt. Die
Kopie zu schwärzen, während die Quelle den Klartext behält, senkte die
Exposition dort um null.

Nachgeprüft: `lastConnectedConfig` hat genau **einen** Verbraucher in der
Produktion, den externen Terminalstart. Es wählt nie. Also speichert
`connect()` es jetzt geschwärzt. Der reale Gewinn der Phase liegt damit
nicht mehr nur auf der P3c-Sidebar-Route.

Sieben Doc-Kommentare zogen nach: drei behaupteten weiterhin, das
Aufräumen bei `disconnect` sei der Grund, warum kein Klartext-Passwort eine
Verbindung überlebt. Die Schwärzung bei der Zuweisung ist die stärkere
Garantie; jetzt steht das auch da. `clearRetainedSecrets()` löscht
`lastConnectedConfig` weiterhin — nur ist es nicht mehr die Schranke,
sondern Sorgfalt für Host-/Benutzer-Metadaten.

## Erledigte offene Punkte der Spec

- **Sollen die Aufräumwege sie mit erfassen?** Nein — die Schwärzung bei der
  Zuweisung macht sie überflüssig, statt einen dritten Pfad zu schaffen,
  den jede spätere Änderung mitpflegen müsste.
- **Muss der Hinweis die Konfiguration überhaupt halten?** Ja, aber
  geschwärzt. Ein Neu-Auflösen nach der Bestätigung könnte scheitern und
  brächte einen zweiten Fehlerweg für nichts.
- **Braucht ein Fenster, das während des Hinweises zugeht, einen eigenen
  Weg?** Nein. Nach der Schwärzung trägt der zurückgehaltene Request nur
  noch Host/Port/Benutzer/Schlüsselpfad, und `@State` stirbt mit der View.
  Bewusst so gelassen: die Alert-Knöpfe starten ein losgelöstes `Task`, das
  den externen Terminal auch dann noch öffnet, wenn das Fenster unmittelbar
  nach dem Klick zugeht — das ist der Wunsch des Nutzers, nicht ein Leck.

## Geprüft und widerlegt

Ein Hintergrund-Scan meldete als stärksten Fund, das Jump-Geheimnis in
`values` überlebe den Disconnect, weil `clearPassword()` nur Felder der
obersten Ebene räumt und `teardown` `clearJumpFields()` nicht rufe. Der
Scan hatte das selbst als ungeprüft markiert. Nachgeprüft: `teardown` ruft
`exitEditMode()`, und das ruft `clearJumpFields()`. Kein Befund.

## Offene Spuren (ungeprüft, eigene Phase wert)

Aus demselben Scan, jeweils **nicht verifiziert** — vor einer Umsetzung erst
messen:

- Eine aus dem Keychain gelöste Managed-Key-Passphrase landet im
  langlebigen Formular (`ConnectionFormView`, `ContentView.fillForm`). Bei
  einem **gescheiterten** Connect räumt sie niemand.
- Login-Set-Geheimnisse werden vor jedem Submit ins Formular vorgefüllt;
  ein abgelehnter Submit lässt sie stehen.
