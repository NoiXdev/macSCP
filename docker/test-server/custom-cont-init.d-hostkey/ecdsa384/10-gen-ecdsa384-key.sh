#!/usr/bin/with-contenv bash
# shellcheck shell=bash
#
# linuxserver/openssh-server's own init (init-openssh-server-config) only
# runs `ssh-keygen -A`, which generates rsa, ecdsa (P-256) and ed25519 host
# keys into /config/ssh_host_keys — never a P-384 ECDSA key. This
# custom-cont-init.d hook (mounted read-only at /custom-cont-init.d, run as
# root before sshd starts) fills that gap for the ecdsa384 host-key-types
# rig service.
#
# Runs after init-openssh-server-config has created /config/ssh_host_keys
# (custom-cont-init.d's own service, init-custom-files, depends
# transitively on init-openssh-server-config via init-config-end and
# init-mods-end), so the directory already exists.
set -euo pipefail

KEY_FILE=/config/ssh_host_keys/ssh_host_ecdsa384_key
REFERENCE_KEY=/config/ssh_host_keys/ssh_host_rsa_key

if [[ ! -f "${KEY_FILE}" ]]; then
    ssh-keygen -t ecdsa -b 384 -N "" -f "${KEY_FILE}"
    # This script runs as root, so the generated files are root:root by
    # default -- but svc-openssh-server's run script starts sshd as
    # ${USER_NAME} (s6-setuidgid), which then cannot read a private key it
    # does not own. Match the ownership the base image's own `ssh-keygen -A`
    # already gave the sibling rsa key, which is guaranteed to exist by the
    # time this hook runs (init-openssh-server-config creates it before
    # init-custom-files runs this script).
    chown --reference="${REFERENCE_KEY}" "${KEY_FILE}" "${KEY_FILE}.pub"
fi
