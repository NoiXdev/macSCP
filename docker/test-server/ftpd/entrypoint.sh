#!/bin/sh
# Starts the rig's FTP daemon. Idempotent: every step may run against the
# state a previous start left in the container's own filesystem.
#
#   FTPD_PORT           control port (explicit TLS upgrades on this one)
#   FTPD_IMPLICIT_PORT  implicit-FTPS port; empty = no implicit listener
#   FTPD_PASV_MIN/MAX   the passive range the compose file publishes
#   FTPD_MLSD           `on` (default) or `off`: whether FEAT advertises MLST
#                       and MLSD/MLST are accepted at all
set -eu

: "${FTPD_PORT:=2121}"
: "${FTPD_PASV_MIN:=30000}"
: "${FTPD_PASV_MAX:=30009}"
: "${FTPD_MLSD:=on}"
: "${FTPD_IMPLICIT_PORT:=}"

# Generated per start, exactly like the SSH test keys and the WebDAV
# certificate: no key material in git.
if [ ! -f /run/ftpd/cert.pem ]; then
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -subj "/CN=localhost" \
        -addext "basicConstraints=critical,CA:FALSE" \
        -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" \
        -keyout /run/ftpd/key.pem -out /run/ftpd/cert.pem
    chmod 600 /run/ftpd/key.pem
fi

# One virtual user, the rig's usual pair. Rewritten each start so a changed
# password here is the password in force.
hash=$(openssl passwd -6 testpass)
# Two users on the same home and the same password: `testuser` is the one the
# CLI matrix (CLIMatrixFTP) and the rig's documentation use, and `ftpitest` is
# FTPFileSystemIntegrationTests'. They are separate so a login journal line
# `USER testuser: Login successful` can only come from the matrix: the case that
# counts those lines to show a diagnosis sent no password would otherwise race
# every login the integration suite makes on the same daemon.
{
    printf 'testuser:%s:1000:1000::/srv/ftp:/bin/false\n' "$hash"
    printf 'ftpitest:%s:1000:1000::/srv/ftp:/bin/false\n' "$hash"
} > /etc/proftpd/ftpd.passwd
printf 'testgroup:x:1000:testuser,ftpitest\n' > /etc/proftpd/ftpd.group
chmod 600 /etc/proftpd/ftpd.passwd

# Seeding: the repository's own ./seed (mounted read-only) plus the entries a
# repository cannot carry. Existing files are never overwritten, so a rerun
# does not undo what a test left, and nothing here is destructive.
# (BusyBox `cp -R -n /seed/. /srv/ftp/` copies NOTHING, because the
# destination `.` already exists and `-n` then skips the whole tree -- measured
# 2026-11-09 -- so the top-level entries are walked by name.)
if [ -d /seed ]; then
    for entry in /seed/* /seed/.[!.]*; do
        [ -e "$entry" ] || continue
        [ -e "/srv/ftp/${entry##*/}" ] || cp -R "$entry" /srv/ftp/
    done
fi
# Symlinks live HERE and not in ./seed: the other rig services mount that
# directory too, and a symlink in it would change what their listings report.
[ -e /srv/ftp/link-to-hello ] || [ -L /srv/ftp/link-to-hello ] || ln -s hello.txt /srv/ftp/link-to-hello
[ -e /srv/ftp/link-to-sub ] || [ -L /srv/ftp/link-to-sub ] || ln -s sub /srv/ftp/link-to-sub
chown -R 1000:1000 /srv/ftp

conf=/run/ftpd/proftpd.conf
cp /etc/proftpd/proftpd.conf "$conf"
{
    echo "Port $FTPD_PORT"
    echo "PassivePorts $FTPD_PASV_MIN $FTPD_PASV_MAX"
    if [ "$FTPD_MLSD" = "off" ]; then
        # Not advertised AND refused, so a client that sent MLSD anyway would
        # fail instead of quietly succeeding past the fallback it should take.
        echo "FactsAdvertise off"
        echo "<Limit MLSD MLST>"
        echo "  DenyAll"
        echo "</Limit>"
    fi
    if [ -n "$FTPD_IMPLICIT_PORT" ]; then
        echo "<VirtualHost 0.0.0.0>"
        echo "  ServerName \"macSCP rig, implicit FTPS\""
        echo "  Port $FTPD_IMPLICIT_PORT"
        # A vhost does not inherit the main server's passive range, and a
        # data connection on a port the compose file does not publish is
        # unreachable: the first gated run measured EPSV answers of 1658 and
        # 2432 from this listener, and the dial died with "The connection to
        # the FTP server ended."
        echo "  PassivePorts $FTPD_PASV_MIN $FTPD_PASV_MAX"
        echo "  MasqueradeAddress 127.0.0.1"
        echo "  <IfModule mod_tls.c>"
        echo "    TLSEngine on"
        echo "    TLSRequired on"
        echo "    TLSOptions UseImplicitSSL"
        echo "  </IfModule>"
        echo "</VirtualHost>"
    fi
} >> "$conf"

touch /var/log/proftpd.log /var/log/proftpd-tls.log /var/log/proftpd-trace.log
tail -F /var/log/proftpd.log /var/log/proftpd-tls.log /var/log/proftpd-trace.log &
exec proftpd --nodaemon --config "$conf"
