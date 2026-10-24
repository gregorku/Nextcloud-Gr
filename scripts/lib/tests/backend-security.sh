#!/usr/bin/env bash

###############################################################################
#
# Nextcloud-Gr
#
# Verify that Nginx is bound only to the configured private address.
# PostgreSQL, Redis and PHP-FPM have no published host port.
#
# Public TLS for gregor.serveftp.org stays on Infrastructure-netcup
# Traefik.
#
###############################################################################

test_backend_security()
{
    print_section "Backend exposure"

    local host
    local port

    host="$(env_get NEXTCLOUD_BACKEND_BIND)"
    port="$(env_get NEXTCLOUD_BACKEND_PORT)"

    docker ps --format '{{.Ports}}' \
        | grep -Eq "(^|, )${host}:${port}->" \
        || fail "Port ${port} is not bound to ${host}."

    ok "Nginx HTTP is bound to ${host}:${port}."

    if docker ps --format '{{.Names}} {{.Ports}}' \
        | grep -E "${POSTGRESQL_CONTAINER}|${REDIS_CONTAINER}|${NEXTCLOUD_APP_CONTAINER}" \
        | grep -Eq '[0-9]+:(5432|6379|9000)->'; then

        fail "PostgreSQL, Redis or PHP-FPM publishes a host port."
    fi

    ok "PostgreSQL, Redis and PHP-FPM have no published host port."

    log_info "Public TLS and routing stay in Infrastructure-netcup Traefik."
}
