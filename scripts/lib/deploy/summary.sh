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
    info "HTML       : ${NEXTCLOUD_HTML_DIR}"
    info "Backend    : http://$(env_get NEXTCLOUD_BACKEND_BIND):$(env_get NEXTCLOUD_BACKEND_PORT)"

    echo

    info "Next steps:"
    info "1. Open Dockge and confirm the nextcloud-gr stack is listed."
    info "2. Run ./scripts/post-deploy.sh"
    info "3. Run ./scripts/test.sh"
    info "4. Point Infrastructure-netcup Traefik at the backend URL above."

    ok "Deployment summary completed."
}
