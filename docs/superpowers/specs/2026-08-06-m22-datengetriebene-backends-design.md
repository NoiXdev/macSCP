# M22 — Data-driven backend registration

**As of:** 2026-08-06
**Predecessors:** M12 (capability framework), M21 (WebDAV as a third backend)

## Purpose

M21 built WebDAV as a third backend and in doing so measured the limits of
the M12 framework. The result, in M21/Task 8's ledger evaluation: the
generic layers (browser, transfer engine, queue) stayed untouched — but
the compiler flagged **six** `switch` statements that were no longer
exhaustive, and **none** could be served from the descriptor.

These six spots are not protocol capabilities. They are form fields, CLI
conventions, error texts and login sets — four things the framework never
described. M22 describes them.

**The maintainer's explicit wish (2026-08-04):** login sets should support
WebDAV too, and the `kind` checks should go away — derived from the
interface instead of hand-branched. The two feed into each other: login
sets fail today for exactly the reason that `LoginSet` carries
protocol-specific fields.

## Binding decisions

From the brainstorming session, in the order they were settled:

1. **SSH is included.** Not just S3 and WebDAV — the dispatcher should
   actually disappear in the end, not shrink to one branch.
2. **The schema is fully declarative.** Nothing stays custom-built; SSH's
   auth kinds, key selection and jump block are described too.
3. **Field IDs are typed, per backend.** One enum per backend, from which
   both schemas, the factory and the adapter all draw.
4. **Two separate schemas** — one for the connection form, one for the
   login-set editor.
5. **The persistence format does not change.** On disk everything stays
   typed and `Codable`; only the path in between becomes generic.

Point (4) needs a clarification: because (3) holds, these are **not two
lists of loose strings**, but two lists drawn from the same enum. A field
that does not exist cannot be written into either. What remains is the
risk of a field that is in *neither* — the completeness test guards
against that (see Tests).

## The vocabulary

### Typed field IDs

```swift
public protocol BackendFieldID: RawRepresentable, CaseIterable, Hashable, Sendable
where RawValue == String {}

enum WebDAVField: String, CaseIterable, BackendFieldID {
    case baseURL, username, password, useNextcloudPath
}
```

One source for both schemas, the factory and the adapter. There are no
more loose strings, so there are no more typos either.

### Field kinds

```swift
enum Kind {
    case text, number, secret, toggle
    case picker(OptionSource)
    case group([LeafField])        // LeafField.Kind knows no .group
}

enum OptionSource {
    case managedKeys                    // from the ManagedKeyStore (App layer)
    case loginSets(kind: ConnectionKind)
    case fixed([Option])                // e.g. auth kind
}

struct Condition { let field: String; let equals: String }
```

Two cuts here are chosen deliberately:

**The nesting is a type property, not a runtime check.** A `.group`
contains `LeafField`, and `LeafField.Kind` has no `.group` case. "Exactly
one level deep" is thereby guaranteed by the compiler, not by a test
someone can forget. The jump block is the one group that is needed.

**The condition can do exactly one thing:** "field X has value Y". No
and, no or, no negation. That covers the one real case (SSH: key path
only when `authKind == .privateKey`) and cannot grow into an expression
language. If a backend ever needs more, that is cause for reflection, not
for extending it.

### Values

```swift
values[WebDAVField.baseURL]     // compiles
values["basURL"]                // does not exist
```

`FieldValues` is a thin wrapper around a dictionary whose access runs
through the field enum.

## The descriptor

```swift
BackendDescriptor(
    kind: .webdav,
    capabilities: …,                    // unchanged from M12
    connectionSchema: [ … ],
    credentialSchema: [ … ],
    makeConfig: { values, secret in … },
    displaySummary: { values in … },
    connect: { config, deciders in … },
    secretEnvironmentVariable: "MACSCP_PASSWORD",
    requiresSecret: true)
```

`secretEnvironmentVariable` and `requiresSecret` are the two axes that
M21/Task 8 surfaced as missing — with them, the CLI's hard-coded spots
disappear.

`makeConfig` is a closure in which the backend switches over its **own**
enum. Completeness is thereby checked by the compiler at the spot where
it matters: a new field without handling is a build error.

### `displaySummary`

The sidebar, tab title and audit log today build `user@host` from fields
that S3 and WebDAV don't fill — which is why the audit log shows
`host: "unused"` and a WebDAV tab is named `tim@`. The M21 closing review
named this as drift. A per-backend summary fixes it along the way.

## Data flow

```
connectionSchema  →  form renders  →  FieldValues
                                              ↓
                                        makeConfig
                                              ↓
                                       ConnectionConfig  →  connect
```

The form no longer knows any protocol. It renders fields, resolves option
sources, collects values. `ConnectionViewModel` loses its typed `s3*` and
`webdav*` properties and keeps a `values: FieldValues`.

**The option sources are the one place where the App still contributes
something.** Core cannot resolve `OptionSource.managedKeys` — the key
store lives in the App. The form is handed a resolver that turns a
source into an option list: three cases, one `switch`, in exactly one
place.

## Persistence

The disk format does not change. Each backend gets a small adapter in
both directions — `FieldValues` ⇄ `StoredWebDAVConfig`. That is Codable
work the compiler checks; users' files stay untouched. No migration run,
no second read path.

`LoginSet` gets the WebDAV fields **additively**, exactly the way it got
the S3 fields in M12: new optional properties, old files read unchanged
as `nil`.

## Login sets and the resolver

```swift
// today: two functions, WebDAV would make three
LoginResolver.resolve(session:sets:secrets:)    -> ResolvedLogin?
LoginResolver.resolveS3(session:sets:secrets:)  -> ResolvedS3Login?

// going forward: one
LoginResolver.resolve(session:sets:secrets:)    -> FieldValues?
```

The resolver finds the set, has its adapter translate the typed fields
into `FieldValues`, fetches the secret from the keychain under the set
ID — and delivers a dictionary that the factory processes exactly the
same as one from the form. `ResolvedLogin` and `ResolvedS3Login` merge
into one.

The login-set editor renders the `credentialSchema` with the same generic
code as the connection form. The hand-enumerated type picker that today
offers only SSH and S3 becomes a `ForEach` over the backends — WebDAV
appears in it without "WebDAV" being spelled anywhere.

**That makes login sets for WebDAV not work, but a consequence.**

### Open point, named explicitly

`authKind` is not an ordinary field for SSH: it decides which other
fields are visible, and whether a secret is needed at all. In the schema
it becomes a `.picker(.fixed([...]))`, and the visibility conditions of
the remaining fields point to it. That is exactly what the condition
exists for — but that makes SSH's login sets the only ones whose editor
shows and hides fields. If that turns out to be unwieldy during
construction, that is the first spot where the implementation should
stop and ask.

## What disappears

| Site found (M21/Task 8) | Becomes |
|---|---|
| `ConnectionViewModel.connect()` | `descriptor.makeConfig(values, secret)` |
| `ConnectionViewModel.validateForEditSave()` | the same call, different purpose |
| `CLISecretSources` (environment variable) | `descriptor.secretEnvironmentVariable` |
| `CLISecretSources.needsSecret` | `descriptor.requiresSecret` |
| `LoginSetsSheet.isSaveDisabled` | required-field check via `credentialSchema` |
| `LoginSetsSheet` save button | ditto; the `preconditionFailure` goes away |

In addition, `CLIErrorMapping`'s `.missingWebDAVConfiguration` becomes
`.missingBackendConfiguration(kind:)`, and is thereby protocol-neutral.

`BackendConnector` disappears too, because the descriptor carries the
connection closure along with it. The one remaining `switch` over
`ConnectionKind` is then the one in `BackendDescriptor.descriptor(for:)`
itself — the registration table, not a dispatcher.

## Tests

**Completeness test per backend.** Every field of both schemas is read
by `makeConfig` and translated by the adapter; none falls between the
schemas. This catches the case that even an exhaustive `switch` doesn't
see: a field the factory handles that is in neither schema and therefore
never gets an input field.

**Round trip per backend.** Form values → configuration → stored session
→ form values. What comes out at the end matches what went in.

**Legacy-data test with real files.** A session JSON and a login-set
JSON in today's format, frozen as a fixture, must load unchanged after
the rebuild and produce the same configuration. That is the only test
that proves users' stored connections survive the milestone — and the
only one that cannot be replaced by reasoning about it.

**The existing SSH and S3 tests are the safety net.** They must not be
adjusted to fit a new implementation. If one goes red, the
implementation is wrong, not the test.

## Not in this milestone

Changes to the persistence format; UX changes to SSH's form (such as
moving the jump block into its own sheet); new protocols; the open minor
findings from M21, to the extent they aren't already on the path anyway.

## Success criteria

1. `grep -rn "kind == \." Sources/` finds no more protocol branching
   outside the descriptor registration.
2. A login set for WebDAV can be created, bound to a session, and
   connected — without any WebDAV-specific UI code existing.
3. The legacy-data test loads a session written before M22 and a
   login set written before M22 unchanged.
4. All existing SSH and S3 tests stay green, unchanged.
5. A fourth backend would need: one field enum, two schemas, one
   factory, one adapter, one connection closure — and no change to any
   generic layer.
