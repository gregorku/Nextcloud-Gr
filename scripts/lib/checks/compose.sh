#!/usr/bin/env bash

###############################################################################
#
# Authentik-netcup Project
#
# File:
#   scripts/lib/checks/compose.sh
#
# Description:
#   Docker Compose validation functions.
#
###############################################################################

###############################################################################
# Validate Docker Compose configuration
###############################################################################

check_compose_configuration()
{
    docker compose \
        --env-file "${ENV_FILE}" \
        -f "${COMPOSE_FILE}" \
        config >/dev/null \
        || fail "Compose configuration is invalid."

    ok "Compose configuration is valid."
}