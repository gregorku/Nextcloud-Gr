#!/usr/bin/env bash

###############################################################################
#
# Nextcloud-Gr
#
# File:
#   scripts/lib/deploy/check-env.sh
#
# Description:
#   Validate the deployed environment configuration.
#
###############################################################################

###############################################################################
# Validate deployed environment
###############################################################################

deploy_check_env()
{
    print_section "Environment"

    [[ -f "${ENV_EXAMPLE_FILE}" ]] \
        || fail ".env.example not found."

    [[ -f "${ENV_FILE}" ]] \
        || fail ".env not found. Run ./scripts/update-env.sh"

    env_validate

    ok "Deployment environment OK."
}