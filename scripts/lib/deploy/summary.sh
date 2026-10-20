#!/usr/bin/env bash

###############################################################################
#
# Authentik-netcup Project
#
# File:
#   scripts/lib/deploy/summary.sh
#
# Description:
#   Deployment summary.
#
###############################################################################

deploy_summary()
{
    print_section "Deployment completed"

    info "Repository : ${GIT_DIR}"
    info "Stack      : ${STACK_DIR}"
    info "Data       : ${DATA_DIR}"
    info "Backend    : http://${AUTHENTIK_HOST_IP}:${AUTHENTIK_HTTP_PORT}"

    echo

    info "Next steps:"
    info "1. Open Dockge and confirm the authentik-netcup stack is listed."
    info "2. Run ./scripts/post-deploy.sh"
    info "3. Run ./scripts/test.sh"
    info "4. Point Infrastructure-netcup Traefik at http://${AUTHENTIK_HOST_IP}:${AUTHENTIK_HTTP_PORT}"

    ok "Deployment summary completed."
}
