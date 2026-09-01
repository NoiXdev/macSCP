# macSCP — Corporate Identity

Status: 2026-07-09 · direction approved by the maintainer ("Zwei Welten, ein Fenster")
Interactive draft: Artifact "macSCP — Design & CI" (session 2026-07-09)

## Brand idea

**Two worlds, one window.** Amber stands for everything local (warm, near),
ocean blue for everything remote (cool, far). That way every transfer
direction automatically carries its color: upload = amber, download = blue.
The app itself stays macOS-native (system colors, standard controls,
vibrancy) — the brand colors only work where they carry meaning.

## Color palette

| Name | Light | Dark | Use |
|---|---|---|---|
| Amber | `#DE9426` | `#E8A63C` | local pane, uploads |
| Ocean blue | `#2D71B8` | `#4E92D6` | remote pane, downloads, primary action |
| Deep sea | `#16344C → #0F1E2B` (gradient) | same | icon background, terminal background |
| Phosphor | `#7BD88F` | `#7BD88F` | terminal text, connected status |
| Mist | `#F4F7FA` | — | light background (web/docs) |
| Ink | `#14212E` | `#E8EFF5` (inverted) | text on background surfaces |

Rules:

- Never mix amber and ocean blue decoratively — they're semantic
  (local/remote), not ornamental.
- Status green (phosphor) is separate from the brand colors; errors use
  the system red.
- In the app, system colors take priority; the duo colors come in as
  asset colors (`LocalAmber`, `RemoteBlue`) with light/dark variants.

## App icon

Chosen: **Variant A "Two Panes"** — two outlined panes (amber/blue) on a
deep-sea squircle, exchange arrows in both directions and both colors.
Master: [`assets/icon.svg`](assets/icon.svg). For M6 (release), render the
`.icns` sizes from it (16–1024 px); until then the app runs without a
bundle icon.

Discarded variants: B "Up & Down" (arrows only — held in reserve for the
menu-bar icon), C "Prompt" (too terminal-heavy for a file manager).

## Wordmark & typography

- Wordmark: `mac` in SF Pro Display Light (300), `SCP` in Bold (750),
  tracking −2%. No custom logo typeface.
- The system font **is** the brand font: SF Pro Text for UI and body
  text, SF Mono (`ui-monospace`) for paths, terminal, and number columns
  (tabular figures).
- On web/docs: `-apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica
  Neue", sans-serif` and `ui-monospace, "SF Mono", Menlo, monospace`
  respectively.

## Language & public texts

- Tagline: **„Dateien sicher zwischen Mac und Server bewegen — in einer App,
  die sich nach Mac anfühlt."**
- Public texts (tagline, README intro, landing page) stay
  benefit-oriented and free of tech-stack terms; protocol and tool names
  appear only from the Contributing section onward (maintainer's
  convention).
- UI texts in German, worded actively; errors name the cause and the
  next step ("Anmeldung fehlgeschlagen — Benutzername oder Passwort
  prüfen.").

## Roadmap reference

The target picture (sidebar, two panes, terminal, transfer bar) comes
together across the milestones: remote browser M2a · local pane/transfers
M2b · sessions M3 · terminal M4 · queue M5 · icon/release M6. Design
tokens (asset colors) get introduced with M2b.
