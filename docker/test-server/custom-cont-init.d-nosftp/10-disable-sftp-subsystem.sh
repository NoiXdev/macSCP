#!/usr/bin/with-contenv bash
# shellcheck shell=bash
#
# `sshd-nosftp` (2026-09-17): an OpenSSH server with NO SFTP subsystem, so
# the gated suite can prove that a port forwarding connects without opening
# an SFTP channel (docs/BACKLOG.md, "A forwarding dial opens an SFTP channel
# it never uses").
#
# Why a script and not an `sshd_config.d` fragment: the image's
# init-openssh-server-config writes `Subsystem sftp internal-sftp` into
# /config/sshd/sshd_config itself, AFTER the `Include` line, and sshd keeps
# the FIRST value it reads for a keyword. So an included fragment can only
# REPLACE the subsystem's command (measured 2026-09-17 with `sshd.pam -T`
# against a copy of this image's config: a fragment carrying
# `Subsystem sftp /bin/false` came back as `subsystem sftp /bin/false`), and
# OpenSSH has no `Subsystem sftp none`. A replaced command would still
# ACCEPT the subsystem request and then die, which is not a server without
# SFTP. Commenting the line out is.
#
# Runs as root from /custom-cont-init.d after init-openssh-server-config has
# written the file (the image's documented custom-init hook; the same order
# argument as custom-cont-init.d-hostkey/ecdsa384). Idempotent: on a restart
# the line is already commented and the pattern no longer matches. The
# forwarding settings (`AllowTcpForwarding yes`) come from the shared
# sshd_config.d include, which this script does not touch.
set -euo pipefail

CONFIG=/config/sshd/sshd_config

sed -i -E 's/^([[:space:]]*Subsystem[[:space:]]+sftp[[:space:]].*)$/# disabled by macSCP rig (sshd-nosftp): \1/' "${CONFIG}"

if grep -Eq '^[[:space:]]*Subsystem[[:space:]]+sftp' "${CONFIG}"; then
    echo "sshd-nosftp: the sftp subsystem is still configured in ${CONFIG}" >&2
    exit 1
fi
echo "sshd-nosftp: sftp subsystem disabled"
