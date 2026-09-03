# CLI Test Matrix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The built `macscp-cli` is driven end to end against every
backend the rig offers — SSH (sshd 2222), S3 (MinIO 19000), WebDAV
(Apache) — through every file subcommand and the flags no test drives
today. Measured 2026-09-03 (`docs/BACKLOG.md`, "CLI test coverage"):
only an SSH `put → ls → get → rm` roundtrip runs end to end; `mkdir`,
`--recursive`, the `--on-conflict` variants beyond refuse,
`--password-command` in a real invocation, `sessions --group/--tag`
and the S3/WebDAV backends are not driven through the binary.
Scheduled after the Cyberduck importer (maintainer, 2026-09-03).

**Architecture:** one gated suite per backend built from one shared
matrix helper (`Tests/macSCPCoreTests/Support/CLIMatrix.swift`):
a fixture that writes a temporary session store with one session per
backend (secrets through the CLI's environment variable, never a file),
runs the binary through `SubprocessRunner`, and asserts on `--json`
output where the command has it and on the remote state through the
backend's own `RemoteFileSystem` otherwise. Every case is parameterised
over the backend (`@Test(arguments:)`), so a backend that lacks a
capability is `skipped` by the descriptor's `ProtocolCapabilities`, not
by a per-backend list typed into the test.

**Tech Stack:** Swift Testing parameterised tests, `SubprocessRunner`,
the Docker rig (`MACSCP_ITEST=1`), `ProtocolCapabilities`.

## Global Constraints

- English only; Conventional Commits; footer exactly `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`; commit per task; zero warnings; do not push.
- No secret in argv, in a file, or in any failure message: secrets travel in the child's environment (`MACSCP_PASSWORD`, the S3 secret's variable — read `BackendDescriptor.secretEnvironmentVariable`), and a test that holds one computes its Bools before the expectation.
- No blocking wait; every child through `SubprocessRunner`; the rig only (127.0.0.1), from the main checkout.
- The matrix is derived (backends from `ConnectionKind.allCases`, commands from the CLI's `subcommands` list read through `--help` once), never a typed enumeration; a backend's unsupported operation is skipped through its capabilities with the reason printed.
- No wall-clock ceilings in assertions.

---

### Task 1: The matrix helper and the three backend sessions

**Files:**
- Create: `Tests/macSCPCoreTests/Support/CLIMatrix.swift` (temporary store with one session per backend, environment with the secret, `run(_ arguments: [String]) async throws -> SubprocessResult`, remote cleanup through the backend's file system)
- Test: `CLIMatrixSSHITests`, `CLIMatrixS3ITests`, `CLIMatrixWebDAVITests` — first case each: `ls --json` on the root returns a JSON array.

- [ ] Red first (the S3 and WebDAV cases fail today because no session fixture exists); commit `test(cli): a matrix helper drives the binary against every rig backend`.

### Task 2: The file commands × backends

- [ ] Parameterised cases per backend: `mkdir`, `put` (file), `put --recursive` (a tree), `ls --json` (names, sizes, kinds), `get`, `get --recursive`, `rm`, `rm --recursive` (with `--allow-root-delete` refused on the root); `--on-conflict` overwrite / rename / skip on `put` over an existing file; remote state verified through the backend's file system after each; commit `test(cli): every file command runs against SSH, S3 and WebDAV`.

### Task 3: Sessions and secrets flags

- [ ] `sessions --json --group <name>` and `--tag <name>` filter as documented (the temporary store carries two groups and two tags); `--password-command` in a real invocation (a shell printing the secret, the value never in argv or output — Bools first); `--non-interactive` + an unknown host key refused for every backend that has host keys; commit `test(cli): sessions filters and the password command, driven through the binary`.

### Task 4: Closeout

- [ ] `docs/BACKLOG.md` "CLI test coverage" → Done with the counts (cases per backend, skipped operations and why); commit `docs(backlog): the CLI matrix covers every backend the rig offers`.
