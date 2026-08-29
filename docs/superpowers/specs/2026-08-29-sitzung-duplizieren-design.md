# Sitzung duplizieren — Entwurf

**Stand:** 2026-08-29. Umsetzung von **Punkt 1** aus
`docs/superpowers/specs/2026-08-20-backlog-verwaltungs-sheets.md`.

---

## Was das Datenmodell schon beantwortet

Der Eintrag stellt drei Fragen. Zwei davon beantwortet der Baum, wenn man
nachsieht.

**Das Geheimnis einer Sitzung liegt im SecretStore unter der Sitzungs-`id`
selbst** — das Fach *ist* die Kennung. Eine Kopie mit frischer `id` hat
deshalb kein Geheimnis; „auf denselben Eintrag zeigen" ist gar nicht
ausdrückbar, ohne es aktiv zu **kopieren**.

**Und die Namensregel existiert bereits:**
`SessionNameCollision.freeName(basedOn:avoiding:)`, angelegt für die
vorbefüllten Namen und geprüft — sie benutzt denselben Vergleich wie
`SessionListViewModel.save`, was der Fallstrick an dieser Stelle war. Eine
zweite Namensarithmetik daneben ist damit weder nötig noch erlaubt.

## Entscheidung des Maintainers (2026-08-29)

**Nichts kopieren, Referenzen mitnehmen.**

Die Kopie erbt alles, was ein **Verweis** ist — Gruppe, Tags,
Login-Set-Bindung, Jump-Spezifikation — und nichts, was ein **Geheimnis**
ist.

Daraus folgt eine Asymmetrie, die kein Nachteil ist, sondern die Regel bei
der Arbeit: **eine Sitzung an einem Login-Set funktioniert sofort**, weil
ihr Kreditiv ohnehin am Set hängt und nicht an ihr. Eine Sitzung mit
eigenem Passwort fragt beim ersten Verbinden einmal.

Der Grund ist die Zusage, die dieses Projekt an einer Stelle hält: Geheimes
liegt ausschließlich dort, wo der Nutzer es hingetan hat. Ein Passwort ohne
sein Zutun zu vervielfachen erzeugt einen zweiten Keychain-Eintrag, von dem
er beim Ändern oder Widerrufen wissen müsste — und genau das weiß man beim
zweiten nie.

## Der Entwurf

### Duplizieren ist ein reiner Wert

Was die Kopie trägt und was nicht, hängt nur an der Vorlage und den
vorhandenen Namen. Das gehört als prüfbare Funktion nach Core — nach dem
Vorbild von `SessionNameCollision` und `SidebarOrdering` —, nicht in eine
Menüaktion.

Der Wert entscheidet; die Seitenleiste ruft ihn und speichert das Ergebnis.

### Was übernommen wird und was nicht

| | |
|---|---|
| **Übernommen** | Protokollart und alle Verbindungsfelder, Gruppe, Tags, Login-Set-Bindung, Jump-Spezifikation |
| **Frisch** | `id`, und damit ein leeres Geheimnis-Fach |
| **Nicht übernommen** | jedes Geheimnis, in jedem Fach |
| **Name** | `freeName(basedOn:avoiding:)` über den Namen der Vorlage |

**Die Jump-Spezifikation ist der Fall, der Aufmerksamkeit braucht.** Sie
trägt ein eigenes `secretID` — ein *anderes* Fach als das der Sitzung. Ein
roh übernommenes `secretID` ließe die Kopie auf das Geheimnis der Vorlage
zeigen, und dann wäre die Entscheidung oben genau an der Stelle umgangen,
an der niemand hinsieht. **Die Kopie bekommt ein frisches `secretID`.**

Trägt der Jump dagegen eine `loginSetID` oder eine `sessionID`, sind das
Verweise und wandern mit.

### Wo der Eintrag sitzt

Im Kontextmenü der Seitenleiste, neben Umbenennen und Löschen. Die Kopie
landet in derselben Gruppe wie die Vorlage und wird ausgewählt, damit
sichtbar ist, was entstanden ist.

**Nur zeigen, was möglich ist** — die stehende Regel; nichts wird
ausgegraut.

## Was kein Test dieses Projekts sehen kann

Prüfbar ist alles Entscheidbare: dass Verweise wandern und Geheimnisse
nicht, dass Sitzungs- **und** Jump-Fach frisch sind, dass der Name der
vorhandenen Regel folgt, und dass eine Login-Set-Sitzung nach dem
Duplizieren vollständig ist, eine mit eigenem Passwort dagegen nicht.

**Nicht prüfbar** bleibt, dass der Nutzer die Kopie in der laufenden
Seitenleiste an der erwarteten Stelle sieht.

## Was ausdrücklich nicht dazugehört

- **Kein Kopieren irgendeines Geheimnisses**, auch nicht auf Nachfrage.
- **Keine zweite Namensregel.** `freeName(basedOn:avoiding:)` oder gar
  keine.
- **Keine Änderung an `SessionListViewModel.save`** und seinem Upsert über
  den Namen.
- **Kein Mehrfach-Duplizieren einer Auswahl** — ein Eintrag, eine Sitzung.
