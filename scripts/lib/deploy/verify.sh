#!/usr/bin/env bash

###############################################################################
#
# Authentik-netcup Project
#
# File:
#   scripts/lib/deploy/verify.sh
#
# Description:
#   Verify Authentik-netcup project before deployment.
#
###############################################################################

###############################################################################
# Verify project structure
###############################################################################

deploy_verify_project()
{
    print_section "Verifying project"

    local item

    for item in "${DEPLOY_ITEMS[@]}"; do
        require_file_or_directory "${GIT_DIR}/${item}"
    done

    ok "Project structure OK."
}