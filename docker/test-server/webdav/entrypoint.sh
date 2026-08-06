#!/bin/sh
set -eu
# Generated per start, exactly like the SSH test keys: no key material in git.
if [ ! -f /usr/local/apache2/conf/server.pem ]; then
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -subj "/CN=localhost" \
        -addext "basicConstraints=critical,CA:FALSE" \
        -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" \
        -keyout /usr/local/apache2/conf/server.key \
        -out /usr/local/apache2/conf/server.pem
fi
mkdir -p /var/dav/basic /var/dav/digest /var/dav/tls
printf 'seed\n' > /var/dav/basic/a.txt
mkdir -p /var/dav/basic/sub && printf 'nested\n' > /var/dav/basic/sub/b.txt
chown -R www-data:www-data /var/dav
htpasswd -bc /usr/local/apache2/conf/basic.passwd testuser testpass
htdigest -c /usr/local/apache2/conf/digest.passwd macSCP testuser <<EOF2
testpass
testpass
EOF2

# mod_dav_fs needs a writable directory for its lock database; the base
# image never creates one.
mkdir -p /usr/local/apache2/var
chown www-data:www-data /usr/local/apache2/var

# The base httpd:2.4 image ships every `Include conf/extra/*.conf` line in
# httpd.conf commented out, so our mounted webdav.conf is never read unless
# something wires it in. Do that here rather than in the (read-only-mounted)
# httpd.conf itself. Guarded so a `docker compose restart` against the same
# container filesystem does not append the line twice.
if ! grep -q '^Include conf/extra/webdav.conf$' /usr/local/apache2/conf/httpd.conf; then
    echo 'Include conf/extra/webdav.conf' >> /usr/local/apache2/conf/httpd.conf
fi

exec httpd-foreground
