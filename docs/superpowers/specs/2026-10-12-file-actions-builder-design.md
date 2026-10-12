# The builder for user-defined file actions — design

**Date:** 2026-10-12. **Base:** `develop` at `c0762fac`.
**Wishlist item:** 15, `docs/BACKLOG.md`, the row opening
"Custom actions in the file context menu (maintainer wishlist)".
**Predecessor:** `docs/superpowers/specs/2026-10-06-archive-actions-design.md`,
whose archive half shipped 2026-10-09.

## What this covers

A `FileAction` is a user-authored command template, applied from the file
context menu to the current selection. This design covers the type, its
store, its editor, the two execution paths, and the trust boundary between
the two sources a template's values come from.

## The predecessor's reason for the split is withdrawn, the split is not

The 2026-10-06 design is corrected where it says why this work was deferred.
It reads, verbatim:

> **Out of scope, and deliberately so: the builder for user-defined actions.**
> It is a second subsystem, not a second half of this one. A user-authored
> command template interpolating file names is arbitrary remote command
> execution, and this project today runs a strict whitelist against exactly
> that shape

**The clause "is arbitrary remote command execution" is withdrawn.** On the
remote side nothing in Core executes anything: the resolved command is sent
to the shell the user already has, as text, the way a snippet is
(`SnippetSendPlanner`, `Sources/macSCPCore/Terminal/SnippetSendPlan.swift:28`).
The narrow-capability rule that sentence was defending therefore stays intact
without this design having to argue for an exception —
`Sources/macSCPCore/RemoteFS/RemoteChecksumProvider.swift:73` keeps standing
as written: "A general execution entry point would have been the
alternative, and it would have been a new surface every future reviewer had
to watch."

**"It is a second subsystem, not a second half of this one" stands**, and so
does the maintainer's ruling to split. What is new, and what this design is
mostly about, is a different thing:

**File names are not user-authored.** They come from the server's directory
listing. A hostile or merely careless remote can name a file so that it
changes the meaning of a command the user wrote themselves. That is the trust
boundary this design exists to hold, and the archive work already built the
seam for it.

## Decisions

Taken by the maintainer on 2026-10-12.

1. **Its own type, machinery shared.** A `FileAction` is not a `Snippet`. It
   gets its own store, editor and import/export, so an export cannot mix the
   two kinds. **The security machinery stays one copy** and is used from the
   snippet subsystem, never reimplemented — this is the condition under which
   the separate type is affordable, because the next security fix must have
   only one place to land.
2. **Server data is the new risk**, user-authored templates are not. See the
   withdrawal above.
3. **Both panes**, remote and local, as the archive actions do.
4. **The action declares where it may run** — remote, local, or both.
5. **Multi-selection is a per-action choice**: once with every path, or once
   per file.
6. **Remote output goes to the terminal panel**, local output to the
   per-pane result surface the archive work introduced.
7. **Three selection-derived variables**: the absolute path, the file name,
   the directory.
8. **Prompted variables are allowed too**, as a snippet's are.
9. **`FileAction` carries no `skipsPlaceholderPlacementCheck`.** The
   placement check is not switchable off for an action.

## Values: two sources, two trust levels

| Variable | Source | Can begin with `-`? |
|---|---|---|
| `{{PATH}}` | the listing, **absolute** | no |
| `{{DIR}}` | the listing, **absolute** | no |
| `{{NAME}}` | the listing, the file name alone | **yes** |
| a declared variable, e.g. `{{MODE}}` | the user, before the run | yes |

**Absolute, because this feature issues no `cd`.** A remote action is typed
into the user's shell, and that shell's working directory is whatever the
user left it at — not the directory the browser pane is showing. Resolving a
selection to a relative name would run the command on a different file, or on
none. A `cd` would silently change the state of a shell the user is also
using by hand, so it is not an option either.

Every value is wrapped by `PosixQuoting.singleQuoted`
(`SnippetVariableSubstitution.resolve`,
`Sources/macSCPCore/Terminal/SnippetVariableSubstitution.swift:100`), and
`SnippetVariableSubstitution.firstDeclarationProblem` runs on every action,
with no per-action escape. Variable names obey `SnippetVariable.isValidName`.

**`{{NAME}}` is the one that can begin with a hyphen**, and that is the
residual risk on the local path, where there is no shell to inject into and
so the only way a value can stop being a value is by being read as an option.
The archive work already answers it: every user-controlled operand there is
prefixed `./`. Counted 2026-10-12:

```
/usr/bin/grep -c -F '.operand("./" + ' Sources/macSCPCore/Archive/ArchivePlan.swift
```

printed `6`. This design does the same for `{{NAME}}` wherever it is resolved
into an argv.

## The template language is inherited, not chosen

A template is whatever `SnippetCommandSurvey` can read. It either returns
spans or refuses, and its refusals are the whole of what an author cannot
write: `heredoc`, `unbalancedQuoting`, `commandSubstitution`, `expansion`,
`evaluation`, `unrecognizedSyntax`. Six, and `Placement` has six too —
`argument`, `reparsedArgument`, `quoted`, `commandName`, `comment`,
`afterRedirection`. Both counts were produced by this command, run from the
repository root on 2026-10-12, which prints each enum's header followed by
its own cases:

```
/usr/bin/grep -n -e '^    public enum ' -e '^        case ' Sources/macSCPCore/Terminal/SnippetCommandSurvey.swift
```

**A pipeline and a redirection are readable, not refused.** At
`SnippetCommandSurvey.swift:936` a `|` or `&` calls `advance()` then
`beginCommand()` and continues, so the next word is read in command-name
position; `<` and `>` go through `readRedirectionOperator()`. What is
constrained is therefore not the command but **where a placeholder may
stand** — only at `.argument`, for the reason that enum's own doc comment
gives, verbatim:

> Only `.argument` is a position where a single-quoted value stays one
> literal word.

An earlier draft of this design asserted the opposite — "no pipe, no
redirection" — and that was wrong in the direction that would have produced
a worse feature. The author may write what the shell can do; the restriction
sits on the value, not on the tool.

## Two execution paths, and why the asymmetry is declared rather than hidden

**Remote.** The resolved command is sent to the session's shell as text,
through the snippet send path. Core executes nothing. The user sees the
command and its output where they would read it anyway, which is the audit
property worth the most when a command the user wrote is being filled in with
names the server chose. Offered only where a shell exists, exactly as the
terminal itself is: a WebDAV or S3 session has none.

**Local.** The resolved command becomes an argv and is spawned directly,
following `ArchivePlan.localInvocation` and `LocalArchiveRunner`. There is no
shell on this path — measured 2026-10-12, this command printed nothing and
exited 1:

```
/usr/bin/grep -rln -e localShell -e LocalTerminal -e "local shell" Sources/
```

So shell injection on the local path is not prevented but **impossible**, and
that property is not traded away to make local actions more powerful.

**The consequence, and decision 4.** Because a template may contain a
pipeline, a template can be runnable remotely and not locally: the shell
interprets the pipeline, an argv cannot. So an action declares where it may
run. When "local" is declared, a template that is more than one simple
command is refused in the editor, with the reason named — the survey's spans
are what decides it, so the refusal is derived rather than guessed.

## The confirmation step

Before anything runs, a sheet shows the **resolved** command or commands. It
is not optional, and it earns its place three times over: the user sees what
the server's names became inside their own template; a selection of forty
files cannot become forty commands unnoticed; and the record of what was
about to run exists before it runs rather than after.

**Withdrawn 2026-10-12, quoted.** The first sentence above read: "Before
anything runs, a sheet shows the **resolved** command or commands, reusing
`SnippetDryRun`." The clause "reusing `SnippetDryRun`" was not met. What was
built is `FileActionPlanDisplay` (`Sources/MacSCPAppKit/FileActionConfirmSheet.swift`),
which renders a `FileActionPlan` directly and draws a control, format,
line-separator or paragraph-separator scalar as a `<U+XXXX>` marker, U+200D
excluded. [WITHDRAWN 2026-10-12: this clause first read “draws every
invisible or control scalar as a `<U+XXXX>` marker”, which claims more than
the code does. `needsMarker`
(`Sources/MacSCPAppKit/FileActionConfirmSheet.swift`) switches on
`scalar.properties.generalCategory` and marks four categories, so an invisible
scalar outside them carries no marker. Measured 2026-10-12 with
`/usr/bin/python3 -I -c "import unicodedata as u; print(u.category(chr(0x00A0)), u.category(chr(0x3164)), u.category(chr(0x2800)))"`,
which prints `Zs Lo So`: the no-break space, the Hangul filler and the blank
Braille pattern are each invisible and none of them is marked. The doc comment
above `needsMarker` was precise; this sentence was not.] The reason is that a `SnippetDryRun` describes a
SEND — a `SnippetSendPlan`, a send form, bracketed paste — and none of that is
true of a LOCAL action, which is spawned as an argv with no shell, so a
snippet-shaped description of one would have been false. The extraction the
clause anticipated was made all the same and still stands,
`SnippetDryRun.describing(command:variables:skipsPlacementCheck:values:execute:bracketedPaste:)`,
with no production caller; its own doc comment records that, and
`FileActionEditorWiringGuardTests` forbids reaching for it from the file-action
editor. Nothing else in this section changed.

**On the remote path with "once per file", N lines are sent in order, and a
failure does not stop the rest.** The app does not read the shell's output,
so it has nothing to decide on. This is written down because it is the kind
of behaviour that is otherwise discovered the third time it matters.

## Six consequences found while planning, 2026-10-12

**This heading read "Three consequences found while planning, 2026-10-12"**
until the plan's self-review found three more; the count is withdrawn and
replaced, and nothing else in the first three changed.

Added after the design was approved, by reading the machinery it builds on
rather than by reasoning about it. Each is an addition, not a withdrawal.

**1. A local-capable action's declared variables must all be
`.placeholder`.** `SnippetVariable.Placement` has a second case,
`.environment`, which prepends `export NAME='value';` as its own statement.
There is no shell on the local path, so there is nothing to export into. The
editor refuses `.environment` for an action that declares it may run locally,
and the refusal is derived from the placement, not from a list.

**2. `PATH`, `DIR` and `NAME` are reserved and cannot be declared.** They are
the selection-derived names, so a declared variable of the same name would
have two sources. One of the three is worse than a collision: a declared
`PATH` with `.environment` placement would emit `export PATH='…';` into the
user's own shell and break every later command in that session.

**3. A selection-derived value that begins with `-` is refused on the LOCAL
path, rather than prefixed `./`.** The archive work prefixes its own operands
(`6` occurrences, counted above), and it can, because it knows each operand
is a path it chose the position of. A template's author places `{{NAME}}`
wherever they like, so macSCP cannot know whether a `./` would be correct
there. On the local path there is no shell, so the only way a value stops
being a value is by being read as an option — and the honest answer is to
refuse and say so in the confirmation sheet, which is already being shown.
The cost is that a file literally named `-foo` cannot be processed by a local
action; that is a protective outcome, the same shape as the archive design's
`gzExtractTargetExists`, and it is visible before anything runs rather than
after. `{{PATH}}` and `{{DIR}}` are unaffected, because they are absolute.

**4. The list has its own name, `{{PATHS}}`, and the form decides which
name is allowed.** The values table above lists three names; there is a
fourth. In the `onceWithEveryPath` form `{{PATH}}` has no single value and
`{{PATHS}}` is the whole selection's paths; in `oncePerFile` it is the other
way round. The alternative — one name whose meaning follows the form — was
refused by the maintainer on 2026-10-12: it reads correctly while it is being
written, and switching the form would change what the command does with
nothing on screen saying so. `{{DIR}}` fits both forms, because a pane's
listing never spans directories: `FileSearch` is "bounded strictly to the
entries already loaded -- no recursion into subdirectories".

**5. A local-capable template may hold no quoting.** The local argv is built
by splitting the template into words, and a quoted run spans word
boundaries, so a template holding quotes cannot be split that way. The
survey's spans are runs rather than words, so reconstructing a word from
them would mean a second tokenizer. Refusing quoting for a local-capable
action is the narrower and checkable answer, it is shown in the editor, and
it costs little: an argv needs no quoting in the first place.

**6. The selection's names must be synthesized as `SnippetVariable`s, or
their placement is never checked.** This is the load-bearing one, and the
design as approved did not say it.
`SnippetVariableSubstitution.firstDeclarationProblem` checks the placement of
the variables it is **given**, and `{{PATH}}`, `{{PATHS}}`, `{{DIR}}` and
`{{NAME}}` are not declared by the author — so without synthesizing a
`SnippetVariable` for each reserved name the command actually uses, the
position of `{{PATH}}` would never be checked at all. The position check is
the whole of what keeps a server-chosen name one literal word, so the design's
central claim rested on a call that was not being made. The plan's Task 2
synthesizes them, and the test that pins it plants a `{{PATH}}` inside quotes
that nobody declared.

## Testing

**Core.** The survey and the substitution have their own suites already; what
is new is the binding of the three selection-derived variables, that
`{{PATH}}` and `{{DIR}}` resolve absolute, that `FileAction` has no
placement-check escape as a property of the type, the two multi-selection
forms, and the editor's derived refusal of a non-simple command for a
local-capable action.

**App.** Wiring guards for the menu and the editor, in the family that
already exists (`TerminalKeyboardWiringGuardTests`,
`TerminalMouseWiringGuardTests`, `TerminalThemeWiringGuardTests`), positive
checks throughout.

**What no suite here establishes**, and what therefore belongs to the
maintainer by hand: that the typed command arrives in the real shell, and
that the result surface renders. Both need a running app, which this project
does not launch from a session. The plan carries them as the maintainer's
steps, named as unverified by the suite.

## Out of scope

No `cd`. No shared export between snippets and actions — the separate store
is what makes that structurally impossible rather than a rule someone has to
remember. No keyboard shortcuts for actions: EXECUTE snippets deliberately
have none, and an action triggered on server-named files has the same reason
and one more. No reading of the remote command's exit status on the typed
path, which is what the paragraph above about N lines is a consequence of.
