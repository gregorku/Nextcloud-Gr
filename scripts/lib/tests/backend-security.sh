#!/usr/bin/env bash

###############################################################################
#
# Authentik-netcup Project
#
# Verify that the Authentik HTTP backend is bound only to the Incus
# container IP. PostgreSQL has no published host port.
#
# Authentication of the public name auth.serveftp.org is handled by
# Infrastructure-netcup Traefik, not by this project.
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

    ok "Authentik HTTP is bound to ${host}:${port}."

    if docker ps --format '{{.Names}} {{.Ports}}' \
        | grep -E "${POSTGRESQL_CONTAINER}" \
        | grep -Eq '[0-9]+:5432->'; then

        fail "PostgreSQL port 5432 is published."
    fi

    ok "PostgreSQL has no published host port."

    if docker ps --format '{{.Ports}}' | grep -Eq '9443->'; then
        fail "Authentik HTTPS port 9443 must not be published."
    fi

    ok "Port 9443 is not published."

    log_info "Public TLS and routing stay in Infrastructure-netcup Traefik."
}
