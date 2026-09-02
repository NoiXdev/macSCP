# macSCP test rig

`docker compose -f docker/test-server/compose.yml up -d` from the main
checkout (never from a git worktree — the seed mounts are relative to this
compose file).

## MinIO / S3 rig

`minio` (host ports 19000/19001) is seeded by the one-shot `minio-init`
service, which reruns on every `up` and is idempotent. Two buckets and
two identities:

| identity | access key / secret | can list buckets? | access |
|---|---|---|---|
| root | `macscp` / `macscpsecretkey` | yes (all) | full admin |
| scoped | `macscp-scoped` / `macscpscopedsecret` | see below | `macscp-seed` only (List/Get/Put/Delete); no access to `macscp-second` |

Buckets: `macscp-seed` (root's original seed bucket — `a.txt` and
`sub/b.txt`) and `macscp-second` (added 2026-09-02, holds one object,
`second.txt`, seeded so the bucket-list case is a genuine two-bucket
listing).

The scoped identity's policy (`docker/test-server/minio/scoped-seed-policy.json`,
policy name `scoped-seed` on the server) grants `s3:ListBucket` on
`arn:aws:s3:::macscp-seed` and `s3:GetObject`/`s3:PutObject`/`s3:DeleteObject`
on `arn:aws:s3:::macscp-seed/*` — nothing else, and deliberately no
`s3:ListAllMyBuckets`.

**Measured deviation from the original task brief:** the brief expected an
account-level bucket listing (`mc ls scoped`, no bucket given) to fail
outright with `AccessDenied` once `s3:ListAllMyBuckets` is omitted. That is
not what this MinIO version (`RELEASE.2024-07-16T23-46-41Z`) does: MinIO's
`ListBuckets` implementation returns every bucket the caller has *any*
access to, regardless of `s3:ListAllMyBuckets` — confirmed by adding an
explicit `Deny` statement for that action to a throwaway test policy and
re-running the same call: the result was unchanged, still the filtered
one-bucket list, never `AccessDenied` (the throwaway policy was removed and
the user's policy set back to `scoped-seed` afterwards; see the fork/rig
discipline this repo already applies — measure, then record). So the
achievable, verified behavior for a bucket-scoped key on this rig is: an
account-level listing returns only the bucket(s) it is scoped to (here,
exactly one — `macscp-seed`), and reading any *other* bucket's contents is
a hard `AccessDenied`. There is no policy shape on this MinIO version that
makes the account-level listing itself return `AccessDenied` while the key
still has any bucket access at all. Whoever writes the Swift-side test for
"a key scoped to one bucket" should assert the single-bucket-filtered list
and the cross-bucket `AccessDenied`, not an `AccessDenied` on the listing
call itself.

### Proof, measured 2026-09-02

From inside `minio-init`'s image (`docker compose -f
docker/test-server/compose.yml run --rm --entrypoint sh minio-init -c
'...'`), with `local` aliased to the root credentials and `scoped` aliased
to the scoped credentials:

```
--- 1: root mc ls local ---
[2026-09-02 10:22:29 UTC]     0B macscp-second/
[2026-09-01 09:04:36 UTC]     0B macscp-seed/
--- 2: scoped mc ls scoped ---
[2026-09-01 09:04:36 UTC]     0B macscp-seed/
--- 3: scoped mc ls scoped/macscp-seed ---
[2026-09-02 10:24:31 UTC]     8B STANDARD a.txt
[2026-09-02 10:26:15 UTC]     0B sub/
--- 4: scoped mc ls scoped/macscp-second ---
mc: <ERROR> Unable to list folder. Access Denied.
```

Root sees both buckets (1). The scoped key's account-level listing shows
only the one bucket it has access to, not both — see the deviation note
above (2). The scoped key can list and read inside `macscp-seed` (3). The
scoped key gets a hard `AccessDenied` reading `macscp-second`, the bucket
its policy does not name (4).

`docker compose up -d` against an already-running rig recreates only
`minio-init` — `minio`, both `sshd`, `webdav` and the five
`sshd-hostkey-*` containers keep their existing container IDs (checked via
`docker ps --format '{{.ID}} {{.Names}}'` before and after; every ID
matched).

## SSH host-key-types rig (2026-09-02)

`sshd` and `sshd2` offer all three host-key types the base image generates
at once (rsa, ecdsa P-256, ed25519), so every client negotiates ed25519
regardless of which type is under test. These five services each restrict
`HostKeyAlgorithms` to exactly one type via their own
`sshd_config.d-hostkey/<type>` include, so the gated host-key-handling
tests can pin each type individually. All five are `testuser`/`testpass`,
seed-less (the tests only connect).

| service | port | HostKeyAlgorithms |
|---|---|---|
| `sshd-hostkey-ed25519` | 2231 | `ssh-ed25519` |
| `sshd-hostkey-ecdsa256` | 2232 | `ecdsa-sha2-nistp256` |
| `sshd-hostkey-ecdsa384` | 2233 | `ecdsa-sha2-nistp384` |
| `sshd-hostkey-ecdsa521` | 2234 | `ecdsa-sha2-nistp521` |
| `sshd-hostkey-rsa` | 2235 | `rsa-sha2-512,rsa-sha2-256` |

The base image's own init only runs `ssh-keygen -A`, which produces rsa,
ecdsa (P-256) and ed25519 host keys — never P-384 or P-521. The
`ecdsa384`/`ecdsa521` services mount a `custom-cont-init.d-hostkey/<type>`
hook at `/custom-cont-init.d` (the image's documented custom-init support,
run as root before sshd starts) that generates the missing curve key with
`ssh-keygen` if absent, and hands its ownership to the same user sshd
itself runs as (matched from the sibling rsa key the base image already
owns correctly) — sshd runs as `${USER_NAME}` via `s6-setuidgid` and
cannot read a private key it does not own. Generated keys live only in
each service's own `/config` container volume (an anonymous Docker
volume, exactly like `sshd`'s own host keys) — nothing is bind-mounted
back to this repo, so no key material is ever committed.

### Proof, measured 2026-09-02

`ssh-keyscan -p <port> 127.0.0.1 2>/dev/null | grep -v '^#' | awk '{print $2}'`
for each port, run against a freshly started rig
(`docker compose -f docker/test-server/compose.yml up -d`) with the
`ecdsa384`/`ecdsa521` services' `/config` volumes freshly created (so the
curve keys were generated by the custom-init hook in this same run, not
left over from an earlier one):

```
$ ssh-keyscan -p 2231 127.0.0.1 2>&1
[127.0.0.1]:2231 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGJfJwJjIW0d9eeFHXQBAaCWblMvq3g2yENdEoJ753bW

$ ssh-keyscan -p 2232 127.0.0.1 2>&1
[127.0.0.1]:2232 ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBFUsLg2tOj5c8l7pYBp4jvRmM6ggF8s3ItboPDoDn+CE+Jx7Jod9OSJwPOuR5StiQbudwtNCRQQPE2zIVAiQAZQ=

$ ssh-keyscan -p 2233 127.0.0.1 2>&1
[127.0.0.1]:2233 ecdsa-sha2-nistp384 AAAAE2VjZHNhLXNoYTItbmlzdHAzODQAAAAIbmlzdHAzODQAAABhBF2nookto/KsLgV4fko3fyWye1PCW1AAmMUMklBkdURjYBzBvqWM1Etm5SXPC6HayshcYX6Se7mopyFPMorL1WxiafBUZubcmYdoagOk24YeFnVr4PeogBlJLIDr/GFBqQ==

$ ssh-keyscan -p 2234 127.0.0.1 2>&1
[127.0.0.1]:2234 ecdsa-sha2-nistp521 AAAAE2VjZHNhLXNoYTItbmlzdHA1MjEAAAAIbmlzdHA1MjEAAACFBAG6E4lcWdl5WgRrzZS3aXF7eTz0bpI8mi9FX5dmVFhHrJ8X3hBrVBcG0EN3NSibAQJp362I25D1zrKAFUmxFroszgESj80PHBW+3lKU7AjW4KhHhdxDjxlamqb5iURT7Vw3CkyR/j0RFx0w5DA+a+Y6E7/tCsWSuPqa+5ZQf7D8SD+FAQ==

$ ssh-keyscan -p 2235 127.0.0.1 2>&1
[127.0.0.1]:2235 ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDV0/Of8qb/CzQX5Cx4AZn9j9YmkM6JTFOz87j75iBAeyto+kjM9vDcoIHOjE8aSIsA/kaO56kMgJoq35kiGHE847qCRFSqWVdcZL+05YtdVqIXel7DIIYQOoWWsb4YkYBw81ssOPUQxWZ95iwmIzaYvTAxGU8L4jV7eojgkFih2e9YFLaP9VC9QT7IC0kmkke8ePmtTp0kRH7OUl+rT74jO+RdvS2aTp1pIu+1rigZBRnawY8NKBQrItH8J9iRkHCI1GiG9SGPFnWejpOHFLLGkRVKoSjFuPobeMN+0ojXKW0agpLOTnzsHKbnqyWQ5k4BnvXuTXHU+/3kXl0V6BLRWUxQymmL6iuLdwiUWLKIo+YLLpeGG47z0YDSn7bDW//7iTB68WCdDkCMwJ9wRm8gIPFL38BU16kNsZa5nRz5RzGoOlkbHWkeFD55SIEizyB8ShoFnL/Nw21J0g+rFq2HACI3BzFvQMYQ5l7QqdAfMLAkSANOXm1FUAfVn7CBt+U=
```

One line, one type, per port — matching the table above exactly. (This
`ssh-keyscan` build writes its `# host:port banner` lines to stdout rather
than stderr, so a plain `2>/dev/null` does not strip them; the `grep -v
'^#'` above does. Either way, only the key line carries a host-key-type
field — the banner's second field is the host:port repeated, never a
second type — so no port printed more than one type in either form of the
command.)

## SFTPGo — the rig's Go-based SSH server (2026-09-02)

`sftpgo` (`drakkan/sftpgo:v2.6.6`, arm64 and amd64 both in the manifest;
AGPL-3.0-only, run as a test-only container, never linked) is the only SSH
server here that is not OpenSSH. Its server side is `golang.org/x/crypto/ssh`,
which parses a user-auth public-key blob's leading string as a KEY FORMAT and
therefore refuses one typed `rsa-sha2-512`, where RFC 8332 §3 keeps the blob
typed `ssh-rsa` and puts the algorithm name only in `pkalg` and the signature.
That refusal was measured against the library directly on 2026-09-01
(`docs/superpowers/specs/2026-09-01-backlog-rsa-agent-go-servers.md`); this
service is what makes it measurable against a real server, which is what the
gated `GoServerRSAIntegrationTests` does.

| service | host port | container port | what |
|---|---|---|---|
| `sftpgo` | 2240 | 2022 | SFTP |
| `sftpgo` | 18091 | 8080 | admin REST API + web admin |

| identity | credentials | what it is for |
|---|---|---|
| admin | `macscpadmin` / `macscpsecretkey` | the REST API (`/api/v2`), nothing else |
| SFTP user | `testuser` / `testpass` | the login under test |

`testuser`'s home directory is the SAME read-only `./seed` mount `sshd`
serves, so a listing against SFTPGo asserts the same `hello.txt` the OpenSSH
suites assert, and a gated test can never write into the repository through
this server. Its permissions are `list`/`download` only, for the same reason.
The sqlite data provider and the host keys SFTPGo generates on first start
live in the container's own `/var/lib/sftpgo` — no bind mount, so no key
material can reach the repository. `SFTPGO_LOG_LEVEL=debug` is set so the log
names a refused offer instead of merely counting it.

### How a test installs a public key

SFTPGo keeps a user's authorized keys in its data provider, not in a file, so
there is no `authorized_keys` to append to and no `docker exec` that would do
it. `makeSFTPGoInstalledKey` in
`Tests/macSCPCoreTests/Support/InstalledKey.swift` — the twin of
`makeInstalledKey`, which does use `docker exec` for `sshd` — goes through the
documented REST flow instead:

1. `GET /api/v2/token` with the admin's HTTP basic auth → a bearer token
2. `GET /api/v2/users/testuser` → the current user object
3. `PUT /api/v2/users/testuser` → the same object with the new key APPENDED to
   `public_keys`

The append is what makes it behave like sshd's `authorized_keys`: keys from
earlier runs stay valid for as long as the container lives.

The one-shot `sftpgo-init` (`curlimages/curl:8.9.1`, `./sftpgo/init.sh`) only
creates the user; it deliberately sets no public keys. It waits for the admin
API — which answers only once the data provider is initialized and the default
admin exists, so that wait is the readiness gate for both — and then creates
`testuser` from `./sftpgo/testuser.json` only when
`GET /api/v2/users/testuser` says the user is absent. A repeated
`POST /api/v2/users` is a 500 ("username already in use"), which is why the
create is guarded rather than retried, the same "check, then act" shape
`minio-init` uses for its policy attach.

### Proof, measured 2026-09-02

`docker compose -f docker/test-server/compose.yml up -d` against the rig with
`sftpgo` already running leaves EVERY container ID unchanged — the eleven that
predate this service, `macscp-test-sftpgo` itself, and on a steady-state rerun
`macscp-test-sftpgo-init` too (`docker ps -a --filter 'name=macscp-test-'
--format '{{.ID}} {{.Names}}'` before and after, diffed: no differences). The
one exception is the `up` immediately after the service is first created, where
compose recreates the one-shot `sftpgo-init` alone. Its rerun log on an
already-seeded provider:

```
$ docker logs macscp-test-sftpgo-init 2>&1 | tail -1
sftpgo user 'testuser' already present — nothing to do
```

The host key, and the three types SFTPGo generates for itself:

```
$ ssh-keyscan -p 2240 127.0.0.1 2>&1
# 127.0.0.1:2240 SSH-2.0-SFTPGo_2.6.6
[127.0.0.1]:2240 ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDLE/z+IIsD7wyyrb25mkRLRlBzQeT5fB2K3ftMYKAU5B2kcS7agnj0Gv32NbhaSBC8fQQ/ixP7GQLBCtVqgaHjD6D3CVlQqjIq7kXuYtrgQ/+zsfI3WIgLHnfZvpKzmfiExAwkIAXpEIpLqwkAan4MQPQNLGHb4j1nsGCDnAQmY7noLCRtZkJrzs+Ec8+xhL+Ruu3lyR7NRUK9NVx7sJl8+IDvdzNaA61hO2prawqOSP/+9cDw9Isb4diQr1ZSxbIMET1SBkU3i9mlADrxb/L4PffaYjYLxbb56zQkxlog+Y+1MdLfzl+TtnU22ddc7XJ2oawKBttPrrQR5W3F1JClU3YWiWDl7m9dXRXDuLTNwkWo9jEOTwP41gfYGsafvJxYsqqpu0f/bz4cbFW3MQBCN4bkFkCkN7hS31g8waZ6cuvGEkhWhjQr2OS7vjfuIL/YtRj0ZhjJ2Dm/ZbQpylIfdM7yXfW3mczna4ckrTUkwiEq5Chf3nUQv1bkbY+K+DE=
# 127.0.0.1:2240 SSH-2.0-SFTPGo_2.6.6
# 127.0.0.1:2240 SSH-2.0-SFTPGo_2.6.6
[127.0.0.1]:2240 ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBN+doidg2xR2aE4SqsyqWEkTHukWeZ1eMWToOBePJTqkz0l2t7uLHPppGSGqJWEq/lQuQHEnjvCec1vDrErJ1zs=
# 127.0.0.1:2240 SSH-2.0-SFTPGo_2.6.6
[127.0.0.1]:2240 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHJF8x9EtrTSSwhTu3wbhL66Y3TQ5qWaeyCIwspLFD0U
# 127.0.0.1:2240 SSH-2.0-SFTPGo_2.6.6
```

These keys are regenerated whenever the `sftpgo` container is recreated, so the
gated suite pins nothing against them — each test uses a fresh known-hosts
directory and takes the TOFU `.accept` branch, exactly as the other integration
suites do.

### The refusal, measured 2026-09-02

An ed25519 file key logs in through `CitadelFileSystem.connect` and lists
`hello.txt` — the rig works. An RSA 2048 key, from a file and through an
ssh-agent alike, does not. SFTPGo's log line for both:

```
{"level":"debug","time":"2026-09-02T16:38:55.165","sender":"sftpd","message":"failed to accept an incoming connection from ip \"192.168.65.1\": ssh: unknown key algorithm: rsa-sha2-512"}
{"level":"debug","time":"2026-09-02T16:38:55.165","sender":"connection_failed","client_ip":"192.168.65.1","username":"","login_type":"no_auth_tried","protocol":"SSH","error":"ssh: unknown key algorithm: rsa-sha2-512"}
```

macSCP surfaces it as
`macSCPCore.RemoteFSError.connectionFailed(reason: "Disconnected()")` — note
`connectionFailed`, not `authenticationFailed`: `x/crypto/ssh` cannot parse the
blob at all, so it drops the connection rather than answering the userauth
request with a failure, and its own log calls the login type `no_auth_tried`.
The identical RSA key authenticates against this rig's OpenSSH `sshd` on 2222
(the ten-cell matrix in `FileKeyTypeIntegrationTests`, and
`agentAuthConnectsRSA` for the agent route). The only difference is the server.
