#!/usr/bin/env bash

###############################################################################
#
# Nextcloud-Gr
#
# File:
#   scripts/lib/docker-compose.sh
#
# Description:
#   Docker Compose helper functions.
#
###############################################################################

###############################################################################
# Verify Docker Compose
###############################################################################

require_compose() {

    docker compose version >/dev/null 2>&1 \
        || fail "Docker Compose plugin not found."
}

###############################################################################
# Execute Docker Compose command
#
# Usage:
#   compose_cmd ps
#   compose_cmd logs
#   compose_cmd logs prometheus
#
###############################################################################

compose_cmd() {

    require_compose

    (
        cd "${STACK_DIR}" || exit

        docker compose \
            --env-file .env \
            "$@"
    )
}

###############################################################################
# Validate compose.yml
###############################################################################

validate_compose() {

    compose_cmd config >/dev/null

    ok "Compose configuration is valid."
}

###############################################################################
# Pull images
#
# Usage:
#   compose_pull
#   compose_pull "${PROMETHEUS_SERVICE}"
#
###############################################################################

compose_pull() {

    compose_cmd pull "$@"

    ok "Images updated."
}

###############################################################################
# Start stack or service
#
# Usage:
#   compose_up
#   compose_up "${PROMETHEUS_SERVICE}"
#
###############################################################################

compose_up() {

    compose_cmd up -d "$@"

    ok "Started."
}

###############################################################################
# Stop stack or service
#
# Usage:
#   compose_down
#   compose_down "${PROMETHEUS_SERVICE}"
#
###############################################################################

compose_down() {

    if [[ $# -eq 0 ]]; then
        compose_cmd down
    else
        compose_cmd stop "$@"
    fi

    ok "Stopped."
}

###############################################################################
# Restart service
#
# Usage:
#   compose_restart "${PROMETHEUS_SERVICE}"
#
###############################################################################

compose_restart() {

    [[ $# -gt 0 ]] \
        || fail "compose_restart requires a service name."

    compose_cmd restart "$@"

    ok "Restarted: $*"
}

###############################################################################
# Running services
###############################################################################

compose_ps() {

    compose_cmd ps
}

###############################################################################
# Show logs
#
# Usage:
#   compose_logs
#   compose_logs "${PROMETHEUS_SERVICE}"
#
###############################################################################

compose_logs() {

    compose_cmd logs -f "$@"
}

###############################################################################
# Show compose configuration
###############################################################################

compose_config() {

    compose_cmd config
}

###############################################################################
# Reload containers
###############################################################################
compose_reload()
{
    compose_cmd up \
        -d \
        --force-recreate \
        --remove-orphans
}