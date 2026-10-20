#!/usr/bin/env bash

###############################################################################
#
# Authentik-netcup Project
#
# File:
#   scripts/lib/tests/dockge.sh
#
# Description:
#   Dockge validation tests.
#
###############################################################################

test_dockge()
{
    print_section "Dockge"

    docker_container_running "${DOCKGE_CONTAINER}" \
        || fail "Dockge container is not running."

    local dockge_path

    dockge_path="$(
        docker_exec \
            "${DOCKGE_CONTAINER}" \
            printenv DOCKGE_STACKS_DIR
    )"

    [[ "${dockge_path}" == "${STACKS_DIR}" ]] \
        || fail "Dockge stack path is '${dockge_path}', expected '${STACKS_DIR}'."

    ok "Dockge stack path OK."
}