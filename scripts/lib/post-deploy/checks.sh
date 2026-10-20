#!/usr/bin/env bash

###############################################################################
#
# Authentik-netcup Project
#
# File:
#   scripts/lib/post-deploy/checks.sh
#
# Description:
#   Checks that are meaningful only after the stack is running.
#
#   A check that was not executed is not reported as success.
#
###############################################################################

post_deploy_checks()
{
    print_section "Runtime"

    require_directory "${POSTGRESQL_DIR}"
    require_directory "${AUTHENTIK_DATA_DIR}"
    require_directory "${AUTHENTIK_TEMPLATES_DIR}"
    require_directory "${AUTHENTIK_CERTS_DIR}"

    require_container_running "${POSTGRESQL_CONTAINER}"
    require_container_running "${AUTHENTIK_SERVER_CONTAINER}"
    require_container_running "${AUTHENTIK_WORKER_CONTAINER}"

    local status

    status="$(
        docker inspect \
            --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
            "${POSTGRESQL_CONTAINER}"
    )"

    [[ "${status}" == "healthy" ]] \
        || fail "PostgreSQL health status is '${status}'."

    ok "PostgreSQL healthcheck is healthy."

    docker exec "${AUTHENTIK_SERVER_CONTAINER}" ak healthcheck \
        || fail "Authentik server healthcheck failed."

    ok "Authentik server healthcheck passed."

    docker exec "${AUTHENTIK_WORKER_CONTAINER}" ak healthcheck \
        || fail "Authentik worker healthcheck failed."

    ok "Authentik worker healthcheck passed."

    local host
    local port

    host="$(env_get AUTHENTIK_HOST_IP)"
    port="$(env_get AUTHENTIK_HTTP_PORT)"

    docker ps --format '{{.Ports}}' \
        | grep -Eq "(^|, )${host}:${port}->" \
        || fail "Port ${port} is not bound to ${host}."

    ok "HTTP backend is bound to ${host}:${port}."

    if docker ps --format '{{.Ports}}' | grep -Eq '5432->|9443->'; then
        fail "PostgreSQL or HTTPS 9443 is published on the host."
    fi

    ok "PostgreSQL and port 9443 are not published."
}
