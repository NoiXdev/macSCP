# Bereiche aus dem Reiter-Menü umschalten — Entwurf

**Stand:** 2026-08-27. Umsetzung von Abschnitt **B** aus
`docs/superpowers/specs/2026-08-27-backlog-reiter-feinschliff.md`, und damit
zugleich die Antwort auf **I4** aus der Abschlussprüfung des Tab-Menüs.

---

## Zwei Korrekturen am Backlog-Eintrag, beide gemessen

Der Eintrag stützte sich auf zwei Annahmen. Beide sind falsch, und beide machen
diesen Vorgang **kleiner**, nicht größer.

**1. Die „zwei Wahrheiten" sind längst zusammengeführt.** Der Doku-Kommentar an
`PaneVisibility` vertagt das Verhältnis zu `TerminalPanelViewModel.isVisible`
auf „die Entscheidung einer späteren Aufgabe". Diese Aufgabe hat inzwischen
stattgefunden: `SessionTab.effectivePaneVisibility(terminalIsVisible:hasShell:)`
ist der eine Zusammenbau-Punkt —

```swift
PaneVisibility(showsFiles: showsFiles, showsTerminal: terminalIsVisible && hasShell)
```

— und sein eigener Kommentar hält fest, dass es **nur einen** geben darf. Der
Kommentar an `PaneVisibility` ist damit veraltet und wird in diesem Vorgang
richtiggestellt.

**2. `terminalTarget` gehört ausdrücklich NICHT hierher.** I4 las sich als
Inkonsistenz („Werkzeugleiste und ⌘T folgen der Einstellung, das Reiter-Menü
nicht"). Gemessen folgt nur der Werkzeugleisten-Knopf ihr. Das „Terminal"-Menü
trägt zwei Einträge, die sich **bewusst nie** mit der Einstellung ändern, mit
der Begründung im Quelltext:

> …sodass ein Umstellen nie eine Fähigkeit wegnimmt.

Das Reiter-Menü der Einstellung folgen zu lassen hätte es also **inkonsistent**
gemacht, nicht konsistenter — und hätte einem Nutzer, der auf ein externes
Terminal umstellt, den eingebauten Bereich aus diesem Menü genommen. **I4 ist
damit beantwortet: der Eintrag folgt der Einstellung nicht, und das ist
richtig so.**

---

## Die Regel, die alles andere entscheidet

**Nur zeigen, was möglich ist.** Kein ausgegrauter Eintrag — ein Eintrag, den
man sieht und nicht benutzen kann, verwirrt mehr, als ein fehlender fehlt
(Maintainer, 2026-08-27). Das ist dieselbe Regel, der die übrigen Einträge
dieses Menüs seit `519c2df` folgen.

Für die Bereichsumschalter heißt das zweierlei:

- Ist eine Aktion nicht möglich, **fehlt der Eintrag** — nicht `.disabled`.
- Die Beschriftung nennt die Aktion, die möglich ist: **„Terminal einblenden"**
  oder **„Terminal ausblenden"**, je nach Zustand. Ein Eintrag pro Bereich,
  wechselnde Beschriftung.

Das unterscheidet sich bewusst vom „Terminal"-Menü der Menüleiste, das seine
Einträge ausgraut. Dort ist es richtig, weil eine Menüleiste ihre Struktur
behalten muss; ein Kontextmenü hat diese Verpflichtung nicht.

## Was das Menü künftig trägt

| Eintrag | Bedeutung | Erscheint, wenn |
|---|---|---|
| Dateien ein-/ausblenden | Bereichsumschalter | `toggleState(for: .files, …).isEnabled` |
| Terminal ein-/ausblenden | Bereichsumschalter, **immer der eingebaute** | `toggleState(for: .terminal, …).isEnabled` |
| Externes Terminal öffnen | eigener Weg, **immer extern** | verbunden **und** `supportsShell` |

Der bisherige einseitige Eintrag **„Terminal öffnen" entfällt** und wird durch
den Umschalter ersetzt. Er blendete nur ein und kehrte wortlos zurück, wenn das
Terminal schon sichtbar war — aus diesem Menü führte kein Weg zurück zu den
Dateien.

**Warum die Invariante die Umschalter von selbst richtig macht:**
`PaneVisibility` kann „keine Hälfte sichtbar" nicht darstellen; sein
Initialisierer repariert das auf „Dateien gewinnen". `toggleState` meldet
deshalb für die **einzige noch sichtbare** Hälfte `isEnabled == false`. Nach
der Regel oben fehlt dieser Eintrag dann schlicht — und damit gibt es keinen
Klick, der das Fenster leeren könnte, ohne dass irgendwo eine zweite Prüfung
dafür geschrieben werden müsste.

**Beide Hälften sichtbar** ist ein gültiger Zustand, und das Paar drückt ihn
korrekt aus: dann erscheinen beide Einträge, jeder blendet seine Hälfte aus.
Ein einzelner Umschalter „Terminal ↔ Dateien" könnte das nicht.

## Woher die Fakten kommen

Nichts davon wird neu gerechnet. `TabContextMenu.entries(…)` bekommt die
fertige Antwort als Eingabe, so wie es `supportsShell`, `isAdHoc` und
`isConnected` heute schon bekommt — die Ansicht entscheidet nichts, und
`ConnectionKind` kommt an keiner Stelle vor.

Der Wert, der hineingeht, stammt aus `effectivePaneVisibility(…)` und
`toggleState(for:hasShell:)`, also aus genau den Funktionen, aus denen auch
die Werkzeugleiste liest. Damit können Werkzeugleiste, Menüleiste und
Reiter-Menü nicht auseinanderlaufen — sie beantworten dieselbe Frage an
derselben Stelle.

Was ein Klick bewirkt, beantwortet `applyingClick(on:hasShell:)`; für das
Terminal bleibt `TerminalPanelViewModel.toggle()` der einzige Schreibweg, weil
er den Lebenszyklus der Shell besitzt (er öffnet sie beim Einblenden). Ein
nackter Bool-Schreibvorgang würde das umgehen — der Quelltext sagt das an
dieser Stelle bereits ausdrücklich, und dieser Vorgang ändert daran nichts.

## Was kein Test dieses Projekts sehen kann

Prüfbar ist, welche Einträge bei welchem Zustand erscheinen und wie sie heißen
— das ist ein Wert in Core mit Tests, wie die übrigen Einträge auch.

**Nicht prüfbar** ist, dass ein Klick auf den Eintrag den Bereich in der
laufenden App tatsächlich ein- oder ausblendet. Das entscheidet ein Blick des
Maintainers und wird nicht als „grün" verbucht.

---

## Was ausdrücklich nicht dazugehört

- Keine Änderung an `terminalTarget`, an der Werkzeugleiste oder am
  „Terminal"-Menü der Menüleiste.
- Kein Ausgrauen im Reiter-Menü — die Regel ist Weglassen.
- Keine Änderung daran, wie `TerminalPanelViewModel.isVisible` geschrieben
  wird: `toggle()` bleibt der einzige Weg.
- Keine Antwort auf I5 (Speichern überschreibt namensgleich) — eigener Punkt.
