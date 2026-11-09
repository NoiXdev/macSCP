# The FTP rig's image (FTP plan Task 11, 2026-11-09): ProFTPD, built here
# because no published image offers MLSD plus AUTH TLS on arm64 (spec §9;
# `stilliard/docker-pure-ftpd` has no arm64 build, `garethflowers/docker-ftp-server`
# has no TLS, `chonjay21/docker-ftps` is stale). `sshd/Dockerfile` beside it is
# the precedent for the rig building one image of its own.
#
# ProFTPD, because one binary and one configuration file give the rig all four
# things it needs, each a measured fact of the running container (README.md,
# "The FTP rig", "Proof"):
#   - `MLSD` (mod_facts, compiled in; `FactsAdvertise off` takes it out of FEAT);
#   - explicit FTPS (`AUTH TLS`, mod_tls);
#   - implicit FTPS on its own port (`TLSOptions UseImplicitSSL` in a
#     <VirtualHost>);
#   - arm64 packages in Alpine's own repository.
# Other daemons were not tried; this is the first that worked, not a ranking.
#
# Installed at BUILD time, like `sshd/Dockerfile`, so a cold `up -d` without
# network still starts. The Alpine tag is the pin and `proftpd` is whatever
# that release carries (1.3.9b on 2026-11-09). Bump the tag, not the package,
# and review it with the debt the README records ("The pin is a debt with a
# review date", under "The FTP rig").
FROM alpine:3.22

RUN apk add --no-cache proftpd proftpd-mod_tls openssl \
    && mkdir -p /srv/ftp /run/ftpd

COPY proftpd.conf /etc/proftpd/proftpd.conf
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
