# How many Keychain items one command-line run reads

Measured 2026-09-25, on `develop` at `736c1308`, for the backlog row
"An unattended CLI run may need a second Keychain consent"
(2026-09-24 answered-decisions plan, Task 3).

**Outcome: for the pair the row names — the session's own slot and the
managed key's slot — both reads are necessary, and no production code
changed.** The second is reached only when the first produced nothing, so
it is never a redundant read. One avoidable read was found elsewhere, on
the jump half of `diagnose`; it is recorded in section 4 and was NOT
fixed here, because it is a different pair of items, in different code,
shared with the App.

## 0. The instruments

- `RecordingSecretStore` in `Tests/macSCPCoreTests/CLISecretSourcesTests.swift`
  records every slot id it is asked for. It is what makes "how many items
  does this run read" a number rather than a reading of the code.
- The real login Keychain, behind `MACSCP_KEYCHAIN=1`, for the one
  question a fake cannot answer: what an empty saved value becomes.
- Both measurements below were taken with throwaway test files, removed
  afterwards. What survives is one case in
  `SecretSourcesManagedKeyTests`,
  `theManagedKeysSlotIsReadOnlyWhenTheSessionsOwnSlotAnswersNothing`,
  which pins the three read-count shapes of section 1.

## 1. Which runs read both items, in what order, under what shapes

The command line has **eight** subcommands
(`MacSCPCLI.configuration.subcommands`). Of its verbs, **seven** build a
secret chain, counted 2026-09-25 from the call sites of
`resolveSession(_:options:)` and `secretChain(for:options:)`
(`Sources/MacSCPCLI/SessionConnecting.swift:56`, `:87`):

| verb | how it gets the chain |
| --- | --- |
| `ls`, `get`, `put`, `rm`, `mkdir` | `withConnection` → `connect(to:options:)` → `resolveSession` |
| `diagnose` | `resolveSession` (`Sources/MacSCPCLI/DiagnoseCommand.swift:358`) |
| `tunnels start` | `secretChain(for:options:)` (`Sources/MacSCPCLI/TunnelStartCommand.swift:176`) |

`sessions` and the four `tunnels` store verbs build none. There is still
exactly one `secretSources(` call site under `Sources/MacSCPCLI`
(`SessionConnecting.swift:90`), as that file's own comment claims.

The chain is built by
`secretSources(for:passwordCommand:keychainStore:keyStore:)`
(`Sources/macSCPCore/Sessions/CLISecretSources.swift:236`), in this
order:

1. `--password-command`, when one was given
2. the backend's secret environment variable
3. **the session's own Keychain item**, addressed by `sessionID`
   (`:267-268`; `KeychainSecretStore`,
   `Sources/macSCPCore/Sessions/SecretStore.swift:31`, reads
   `kSecAttrAccount = sessionID.uuidString`)
4. **the managed key's Keychain item**, addressed by `ManagedKey.id`
   (`:275-282`), appended only when `session.ssh?.authKind == .privateKey`
   and the trimmed `keyPath` is non-empty

So both items are in the chain for exactly one session shape: an SSH
session with private-key auth and a key path. The order is always
session's own item first, managed key's item second.

**Measured read counts** (private-key SSH session, key path pointing at a
managed key that has a stored passphrase, environment link filtered out):

| the session's own item | items read, in order | who answered |
| --- | --- | --- |
| present, non-empty | `[session]` — **1** | `keychain` |
| present, holding the empty string | `[session, key]` — **2** | `managed key passphrase` |
| absent | `[session, key]` — **2** | `managed key passphrase` |

A session's own item holding the **empty string** is not a hypothetical
shape. `SessionListViewModel.upsert` writes
`secrets.savePassword(password, for: session.id)` for every session whose
backend `requiresSecret` (`SessionListViewModel.swift:284-285`), and SSH's
`requiresSecret` is false only for `.agent`
(`BackendDescriptor.swift:455-457`). A private-key session saved with a
blank passphrase field therefore gets an item that exists and holds
nothing — and against the real Keychain (`MACSCP_KEYCHAIN=1`, this
machine, 2026-09-25) such a save creates a full item, which reads back as
`""` and which `KeychainSecretPresence` reports as present. An absent item
answers `nil` and is reported absent, as expected.

Neither of the five `connect`-based verbs can read a jump hop's items at
all: `StoredSessionConnectionConfig.build` refuses a session with a jump
(`jumpSessionsNotSupported`), and `tunnels start` refuses one too
(`TunnelCarriers.swift:60-61`). Only `diagnose` walks a jump — see
section 4.

## 2. Is the second read reachable when the first already answered?

**No.** Two places apply "first non-empty wins", and both `continue` only
past a nil-or-empty source and return at the first hit:

- `SecretResolver.resolve(for:)`
  (`Sources/macSCPCore/Sessions/SecretResolver.swift:53-59`) — what
  `connect` and `tunnels start` walk
- `ChainedSecretSource.secret(for:)`
  (`CLISecretSources.swift:326-335`) — the same rule re-applied as a
  `SecretSource`, which `diagnose` holds for the run; it additionally
  memoizes a HIT per session id, so a repeated ask re-reads nothing

Nothing reads ahead. The row-1 table above is the measurement of this:
one item read when the session's own item answers, two when it does not.
The managed-key link has a second short circuit of its own — it reads
`managed_keys.json` (a file, no Keychain) and returns before any Keychain
read for a path the app does not manage or a key that is not encrypted
(`ManagedKeyPassphraseSecretSource.swift:87`, already pinned by
`anUnencryptedManagedKeyReadsNoSlot` and
`aCorruptKeyStoreDoesNotStopAnUnmanagedKeysChain`).

So the second item is read only in the case where it is the only place
left that could hold the answer. **There is nothing to remove.**

## 3. What macOS actually asks for, and what stays unmeasured

What the code establishes:

- Every chain read is `SecItemCopyMatching` with `kSecReturnData`
  (`SecretStore.swift:60-72`). That is the query an item's ACL governs,
  because it decrypts the item's data.
- The attributes-only query is the one that does not raise the dialog —
  `KeychainSecretPresence.hasSecret(for:)`
  (`Sources/macSCPCore/Sessions/SecretPresence.swift:68-80`) exists for
  that reason and says so. It cannot stand in for a chain read: a read
  that only asks whether an item exists delivers no secret, and an item
  that does not exist is already free (`errSecItemNotFound` comes back
  before anything is decrypted).
- The two items are addressed by different accounts — `sessionID.uuidString`
  and `ManagedKey.id` — so they are two items with two ACLs. **Answering
  for one grants nothing for the other**, whatever the answer was.
- The grant is per binary identity, not per invocation: "Always Allow"
  puts the reading binary on that item's ACL, which is why a signed,
  shipped CLI keeps it and a locally rebuilt, ad-hoc-signed one is asked
  again (`CLISecretSources.swift:261-267`).

What stays unmeasured, and cannot be measured from this repository:
**whether a given read actually raises the dialog.** That is decided by
the item's ACL and by the code signature of the binary doing the reading,
and the pair that matters here is "an item the App created, read by the
CLI" — two differently signed binaries. A test process creates its own
items and is therefore already on their ACLs, so the gated
`MACSCP_KEYCHAIN=1` suite can establish what an item IS (section 1) but
never how many dialogs a foreign reader would see. The prompt count is
not measurable here. The READ count is, and the read count is the only
half the code controls.

One consequence worth writing down, because it is a property of the
data and not of the code, and no change can remove it: **which items a
run reads depends on what the chain finds.** A priming run that hits on
the session's own item never reads the managed key's item, and so can
never grant it. If that first item later stops answering — the app drops
it once the key's slot holds the passphrase
(`ContentView.convertedKeyImported(_:for:)`), or the passphrase field is
cleared and saved — the next run reaches a second item for the first
time. That is where an unattended run stalls, and the fix for it is
documentation, not code: reading the second item eagerly, to grant it in
advance, would ADD a consent prompt to every run that does not need one.

## 4. The one avoidable read found — a different pair, not fixed here

`diagnose` is the only verb that walks a jump hop, and its jump half does
NOT have the short circuit the target chain has.

`DiagnosticJump.stored(for:sets:sessions:secrets:keys:)`
(`Sources/macSCPCore/Diagnostics/DiagnosticJump.swift:129-164`) resolves
the hop's SHAPE with a `NoSecretsStore()` — reading no Keychain item —
and then, inside the deferred `secret` closure, does two things in this
order:

1. `LoginResolver.resolveJump(...)` with the real store, which reads the
   one slot the hop is bound to (its own `secretID`, its login set's id,
   or the referenced session's id)
2. `LoginResolver.preferringManagedKeyPassphrase(...)`
   (`LoginResolver.swift:241-277`), which reads the managed key's item —
   and, since the maintainer answer of 2026-09-19, **wins over** whatever
   step 1 read

Measured, for a private-key hop whose key is managed and has a stored
passphrase:

| the hop's own slot | items read, in order | the key's value won |
| --- | --- | --- |
| present, non-empty | `[hopSlot, key]` — **2** | yes |
| absent | `[hopSlot, key]` — **2** | yes |

The first read's value is discarded in both rows. The precedence was
inverted on 2026-09-19; the read order was not. And the closure is not
memoized the way `ChainedSecretSource` is — calling it twice reads four
items, measured `[hopSlot, key, hopSlot, key]` — against **three** call
sites, counted 2026-09-24 in `DiagnosticJump.missingSecretReason`'s own
comment and re-checked today: `ConnectionDiagnostics.dialJump`
(`:690`), `ConnectionDiagnostics.throughput` (`:896`) and
`DiagnosticJumpStep.dialViaJump` (`DiagnosticJump.swift:500`).

So one `macscp diagnose` of a private-key session dialling through a
private-key bastion can read **four different Keychain items** — the
hop's slot, the hop's key's slot, the session's slot, the session's
key's slot — one of which (the hop's slot) is read for nothing whenever
the key answers, and the jump pair of which can be re-read once per jump
dial.

**Not fixed here, deliberately.** It is a different pair of items in
different code; `DiagnosticJump.stored` is shared with the App's own
diagnosis sheet; and the shape of the fix — asking the managed key first
and falling back to `resolveJump` only when it answers nothing — is a
behaviour change that wants its own red-first tests and its own review.
It belongs on the backlog, not in a task whose row named the target
chain.

## Conclusion

For the row's pair: both reads are necessary; the second is unreachable
when the first answered; the CLI still reads the app's Keychain items
read-only and takes no secret by flag, prompt, environment variable or
cache. No production code changed. What changed is one test that turns
the measurement into a guard, this record, and the user documentation,
which now says that a first run may be asked for more than one item and
why a later run can be asked again.
