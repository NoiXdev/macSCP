#!/bin/sh
# One-shot seeding for the `sftpgo` service (2026-09-02).
#
# SFTPGo has no "declare a user in the config file" path: users live in the
# data provider (sqlite here) and are created through the REST API, so this
# container waits for the admin API, takes a token, and creates `testuser`
# if it is not already there.
#
# Idempotency: this container reruns on every `docker compose up -d` against
# a data provider that already holds last run's user. A repeated
# `POST /api/v2/users` is a 500 ("username already in use"), so the create
# only runs when `GET /api/v2/users/testuser` says the user is absent —
# the same "check, then act" shape `minio-init` uses for its policy attach.
#
# The user's PUBLIC KEYS are deliberately NOT set here: the gated tests
# generate a key per run and PUT it onto this user themselves (see
# `makeSFTPGoInstalledKey` in Tests/macSCPCoreTests/Support/InstalledKey.swift),
# exactly as they append to sshd's `authorized_keys` via `docker exec`.
set -eu

API="http://sftpgo:8080/api/v2"
ADMIN_USER="macscpadmin"
ADMIN_PASSWORD="macscpsecretkey"

# The admin API answers only after the data provider is initialized and the
# default admin exists, so this loop is the readiness gate for both.
until curl -sf -u "$ADMIN_USER:$ADMIN_PASSWORD" "$API/token" >/tmp/token.json; do
    echo "waiting for the sftpgo admin API..."
    sleep 1
done

TOKEN=$(sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p' /tmp/token.json)
if [ -z "$TOKEN" ]; then
    echo "could not parse an access token out of the /api/v2/token response" >&2
    exit 1
fi

if curl -sf -o /dev/null -H "Authorization: Bearer $TOKEN" "$API/users/testuser"; then
    echo "sftpgo user 'testuser' already present — nothing to do"
    exit 0
fi

curl -sS -f -X POST \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    --data-binary @/seed/testuser.json \
    "$API/users"
echo "sftpgo user 'testuser' created"
