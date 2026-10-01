# Security policy

## Reporting a vulnerability

Write to **security@noix.dev**. Please do not open a public issue for
anything you believe is a security problem — the issue tracker is public
from the moment you press the button.

Include whatever you have: what you did, what happened, and which version
you were running (macSCP → About macSCP). A proof of concept helps, and so
does an explanation of what an attacker gains — but a report you are unsure
about is still worth sending. A false alarm costs one reply; an unreported
flaw costs more.

**Do not include credentials.** Not yours, not a test server's. If a
password, passphrase, private key, or a server address of the shape
`scheme://user:secret@host` is part of the reproduction, describe its role
and leave the value out.

## What is in scope

macSCP connects to other people's servers and holds the means to do so, so
the interesting surface is mostly about those two things:

- **Stored credentials.** Passwords and passphrases live in the macOS
  Keychain and nowhere else; the session and tunnel stores are JSON and
  never contain them. A path that writes a secret into a file, a log, an
  error message, an exported session, or a diagnostics report is a bug worth
  reporting.
- **Host-key handling.** A changed host key is a hard stop, not a dialog,
  and there is no accept-anything path. Anything that gets a connection past
  a mismatch, or stores a key the user never confirmed, is in scope.
- **The diagnostics report and the diagnostic log.** Both are built to carry
  no credentials. Finding one in there is a bug.
- **The command-line tool.** It never takes a secret — no flag, no standard
  input — and reads the app's Keychain entry read-only. A way to make it
  accept, print, or write one is in scope.
- **Transport.** Certificate or host-key validation that can be bypassed,
  and anything that downgrades a connection without saying so.
- **Update checks**, and anything that could turn one into code execution.

## What is not

- Reports produced only by running macSCP against a server you do not
  control, where the finding is the server's.
- A server presenting a certificate or host key macSCP correctly refuses.
- Anything that needs an attacker to already have local access to the
  machine macSCP runs on with the user's own account unlocked. The Keychain
  is the boundary there, and it is the system's.
- Results from automated scanners with no reproduction attached.

## Which versions

The latest release. There are no maintenance branches — development happens
on `develop` and releases are tagged from it, so a fix ships in the next
release rather than as a patch to an older one. The current release is on
the [releases page](https://github.com/NoiXdev/macSCP/releases/latest).

## What happens next

You will get a reply. If the report is a vulnerability, it is fixed and the
release notes say what changed; you will be credited by whatever name you
ask for, or not at all if you prefer. If it turns out not to be one, you get
the reasoning rather than silence — the measurement either way is the point.
