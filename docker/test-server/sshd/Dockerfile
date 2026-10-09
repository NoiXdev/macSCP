# The `sshd` service's image: the pinned linuxserver/openssh-server plus the
# archive tools the remote half of the archive actions runs (2026-10-08).
#
# The base image ships BusyBox `tar`, which rejects `--null`, and no `zip`.
# The remote command lines the app writes use GNU `tar --null -T -` and
# `zip -@`, so a gated test of that half needs the real tools. `tar` here is
# Alpine's GNU tar package: once installed it replaces the BusyBox applet at
# /bin/tar -- there is no /usr/bin/tar -- which the README's proof section
# measures (`tar --version` names GNU tar). Corrected 2026-10-09; this comment
# first read: "once installed it takes the /usr/bin/tar path ahead of the
# BusyBox applet at /bin/tar", which the README it cites refutes.
#
# Installed at BUILD time rather than by a /custom-cont-init.d script or a
# DOCKER_MODS entry: both of those fetch packages on every container start,
# so a cold `up -d` without network would come up without the tools. Built
# once, the packages are in the image.
#
# The FROM line must name the same tag the other sshd-* services pin in
# compose.yml; bump them together.
FROM lscr.io/linuxserver/openssh-server:10.3_p1-r0-ls230

RUN apk add --no-cache zip tar
