#!/usr/bin/env bash

###############################################################################
#
# Nextcloud-Gr
#
# File:
#   scripts/lib/deploy/dockge.sh
#
# Description:
#   Confirm that the existing Dockge container can see this stack.
#
#   Dockge is already running in the Incus container and uses
#   /docker-data/stacks. This function does not stop, remove or
#   reinstall it.
#
#   After init.sh or deploy.sh has created
#   /docker-data/stacks/nextcloud-gr/compose.yml, Dockge lists the
#   stack because that directory is inside DOCKGE_STACKS_DIR.
#
###############################################################################

deploy_dockge()
{
    print_section "Dockge"

    if ! docker_container_running "${DOCKGE_CONTAINER}"; then
        fail "Dockge is not running. This project does not install or replace Dockge."
    fi

    local dockge_path

    dockge_path="$(
        docker_exec \
            "${DOCKGE_CONTAINER}" \
            printenv DOCKGE_STACKS_DIR
    )"

    [[ "${dockge_path}" == "${STACKS_DIR}" ]] \
        || fail "Dockge stack path is '${dockge_path}', expected '${STACKS_DIR}'."

    ok "Dockge is using ${STACKS_DIR}."

    info "Stack directory: ${STACK_DIR}"
    info "Dockge shows nextcloud-gr after compose.yml exists in that directory."
}
