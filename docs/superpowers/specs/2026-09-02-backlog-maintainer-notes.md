# Backlog: the maintainer's notes of 2026-09-02 (evening)

**Created:** 2026-09-02, from a list the maintainer dictated in chat while
the fork and S3 work was running. Recorded as given — each item is a
wish, not a design, and none is measured yet unless a line says so. The
classification (bug / small / feature / needs design) is the recorder's
first reading and is there to order the work, not to bind it. Nothing
here is scheduled; the order agreed the same evening (checksum column →
CLI completion → connection tools → FTP/FTPS → SMB) stands first.

## Bugs (measure first, then fix)

1. **The terminal does not resize with the window.** It keeps its
   initial size, also in full screen — visible with `nano` and long
   command lines. *Bug.* First step: reproduce, read how `SwiftTerm`'s
   view receives its frame and whether the PTY gets a `TIOCSWINSZ` on
   layout; this is a measurement of one code path, not a feature.

## Small (one plan each, likely a task or two)

2. **Duplicate opens the edit form.** After "Duplicate" on a session the
   copy's edit form opens at once, instead of a silent copy.
3. **Drag & drop a folder to the root level** of the sidebar (today only
   into other groups?). Measure what the drop target refuses today.
4. **Drag & drop for sessions** is missing (moving a session between
   groups by drag).
5. **Context menu on a folder: "Move to…"** (a group's move, without
   drag).
6. **Compact sidebar mode** as a setting (denser rows for the session
   list).
7. **Cancel active transfers** — one, and all at once — as actions beside
   the "clean up" button in the transfers view. Check what the queue's
   `cancelAll` already offers and whether it is only wired for
   teardown.
8. **The path bar's double-click area** spans the whole width, not only
   the text, so the cursor can be placed without aiming.
9. **Show full source and destination paths in a transfer row**
   (expandable), so a file can be found again afterwards.
10. **A status line under the explorer** in the look of the columns:
    number of files and folders in the view, and the selected count
    when there is a selection.
11. **Cmd-click on a URL in the terminal opens it in the browser**, with
    a setting for the browser app. Read what `SwiftTerm` already
    detects as a link.
12. **Space in the explorer opens a preview** (Quick Look-like) of the
    file's content, where possible — for a remote file that means a
    download to a temporary place first; say so in the design.

## Features (need a design before a plan)

13. **Single click on a session shows a preview** instead of connecting:
    the session's details, the last connections from the audit log, and
    perhaps a snippet-run icon. Connecting stays on double click / the
    context menu. (The "single click no longer connects" line in the
    index's ranked list is the first half of this.)
14. **A wastebasket for deleted groups and sessions**, restorable, purged
    after 30 days. Secrets: the keychain slot must follow the session
    into the basket and out again — a design question of its own.
15. **Folder colours** per group, for visual separation.
16. **Custom icons** per group.
17. **Detach a connection tab into its own window**, optionally "sticky"
    (floating above other windows). Touches the one-connection-per-window
    invariant: a detached tab IS a window; the invariant holds, the
    ownership moves.
18. **S3: show the key's access level** — a probe of which S3 API rights
    the key has, in the context menu / connection info. Fits the
    connection-tools seam decided the same evening (per-protocol
    diagnostics): this is S3's first contribution.
19. **"What's new" dialog after an update**, with the release's changes,
    plus an action in Settings / the menu to open it again; skippable and
    hideable until the next update.
20. **`..` row in the tree** when a parent exists, to go up one level —
    excluded automatically from every mass action (a recursive action on
    a selected `..` is too dangerous). Measure how selection and
    `enqueueTree` treat a synthetic row before designing.
21. **Docker volume support** — connect straight to a Docker volume. Needs
    a scoping question first: via the Docker socket on the local machine
    (a local backend, no network), or over SSH to a remote daemon?
22. **rsync for SSH sessions** — sync a folder or files in either
    direction, recursive or one level, to ease mass uploads. SSH-only by
    nature (it runs `rsync` on both ends); the remote side may not have
    it — a capability probe first.

## Also noted

23. The list was given as a whole; nothing in it changes the order of
    the work already agreed. Items 2–12 are candidates for a "sidebar and
    explorer polish" plan once the current strand is through; items
    13–22 each want a brainstorm.

## Decided 2026-09-02 (night) — what goes first

From the list above the maintainer picked, for the first polish plan:
**the terminal-resize bug (item 1)** — measured first — and **the
transfers items (7 and 9)**: cancel one or all active transfers beside
the clean-up button, and full source/destination paths in a row. The
first feature to get a brainstorm: **detachable, optionally sticky tabs
(item 17)**. Everything else in the list waits.

## Brainstormed 2026-09-02/03 — item 17

Detachable, optionally sticky tabs: four questions answered by the
maintainer, design written in `2026-09-03-detachable-tabs-design.md`
(a detached tab is a full window; sticky = above all windows; tabs move
both ways and an emptied window closes unless it is the last; restoration
is a setting, default off, and restores windows without connections).

