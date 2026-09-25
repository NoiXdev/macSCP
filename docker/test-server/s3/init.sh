#!/bin/sh
# One-shot seeding for the `s3` service (RustFS). Reruns on every
# `docker compose up` against a store that already has last run's state, so
# every step below is idempotent -- see the per-step notes.
#
# Signs with curl's own SigV4 (`--aws-sigv4`), which is why this needs no
# vendor CLI: `minio/mc`, which the MinIO-era seeding used, was withdrawn
# from Docker Hub together with the server image. Credentials come in as
# environment variables so they stay spelled in compose.yml, where the
# rig's other fixture credentials are.
set -eu

: "${S3_URL:?S3_URL must be set}"
: "${ROOT_KEY:?ROOT_KEY must be set}"
: "${ROOT_SECRET:?ROOT_SECRET must be set}"
: "${SCOPED_KEY:?SCOPED_KEY must be set}"
: "${SCOPED_SECRET:?SCOPED_SECRET must be set}"

# Every call below is signed as the root identity; only the URL and the
# body differ. `--fail-with-body` so a refusal is a non-zero exit AND
# prints what the server said, rather than one or the other.
sign() {
    curl -sS --fail-with-body \
        --aws-sigv4 "aws:amz:us-east-1:s3" --user "$ROOT_KEY:$ROOT_SECRET" "$@"
}

# The status code of a signed call, with the body discarded -- for the two
# steps whose "already done" answer is a specific non-2xx.
sign_status() {
    curl -sS -o /dev/null -w '%{http_code}' \
        --aws-sigv4 "aws:amz:us-east-1:s3" --user "$ROOT_KEY:$ROOT_SECRET" "$@"
}

# Readiness: a signed ListBuckets is the first thing that answers 200, and
# it is also the first thing the gated suites do.
until sign -o /dev/null "$S3_URL/" 2>/dev/null; do
    echo "s3-init: waiting for $S3_URL"
    sleep 1
done

# CreateBucket. A repeat answers 409 (the bucket is already ours), which is
# this step's "already done" -- the same tolerance `mc mb --ignore-existing`
# gave the MinIO-era seeding.
for bucket in macscp-seed macscp-second; do
    status=$(sign_status -X PUT "$S3_URL/$bucket")
    case "$status" in
        200 | 409) echo "s3-init: bucket $bucket ($status)" ;;
        *)
            echo "s3-init: creating bucket $bucket failed with $status" >&2
            exit 1
            ;;
    esac
done

# PutObject overwrites in place, so a rerun is a no-op in effect. The two
# objects in `macscp-seed` are what a root listing asserts: a file, and one
# under a `sub/` prefix so a CommonPrefixes entry appears beside it.
put_object() {
    printf '%s' "$2" | sign -X PUT --data-binary @- "$S3_URL/$1" -o /dev/null
    echo "s3-init: object $1"
}
put_object macscp-seed/a.txt 'hello a
'
put_object macscp-seed/sub/b.txt 'hello b
'
put_object macscp-second/second.txt 'hello second
'

# The second identity: a key scoped to `macscp-seed` alone. RustFS serves
# MinIO's admin API, so the policy document is the same IAM JSON the
# MinIO-era rig used, mounted unchanged at /policies. AddUser,
# AddCannedPolicy and SetPolicyForUser all overwrite in place, so all three
# are idempotent -- unlike MinIO's `policy attach`, which refused a repeat
# and needed the seeding to check first.
sign -X PUT -o /dev/null \
    --data-binary "{\"secretKey\":\"$SCOPED_SECRET\",\"status\":\"enabled\"}" \
    "$S3_URL/rustfs/admin/v3/add-user?accessKey=$SCOPED_KEY"
sign -X PUT -o /dev/null \
    --data-binary @/policies/scoped-seed-policy.json \
    "$S3_URL/rustfs/admin/v3/add-canned-policy?name=scoped-seed"
sign -X PUT -o /dev/null \
    "$S3_URL/rustfs/admin/v3/set-user-or-group-policy?policyName=scoped-seed&userOrGroup=$SCOPED_KEY&isGroup=false"
echo "s3-init: identity $SCOPED_KEY scoped to macscp-seed"

echo "s3-init: done"
