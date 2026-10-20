#!/usr/bin/env bash

###############################################################################
#
# Authentik-netcup Project
#
# File:
#   scripts/post-deploy.sh
#
# Description:
#   Check the running Authentik stack after deploy or reload.
#
# Usage:
#   ./scripts/post-deploy.sh
#   ./scripts/post-deploy.sh --help
#
#   Requires the three containers to be running. Health checks that
#   cannot be executed fail the script. This does not configure Traefik.
#
# Next step:
#   ./scripts/test.sh
#
###############################################################################

set -Eeuo pipefail

###############################################################################
# Directories
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

###############################################################################
# Configuration
###############################################################################

source "${SCRIPT_DIR}/config.sh"

###############################################################################
# Core libraries
###############################################################################

source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/logging.sh"
source "${SCRIPT_DIR}/lib/filesystem.sh"
source "${SCRIPT_DIR}/lib/docker.sh"
source "${SCRIPT_DIR}/lib/git.sh"

###############################################################################
# Checks
###############################################################################

source "${SCRIPT_DIR}/lib/checks/load.sh"

###############################################################################
# Environment library
###############################################################################

source "${SCRIPT_DIR}/lib/env/load.sh"

###############################################################################
# Post-deployment modules
###############################################################################

source "${SCRIPT_DIR}/lib/post-deploy/checks.sh"

###############################################################################
# Help
###############################################################################

show_help()
{
cat <<EOF
Authentik-netcup Project

Usage:

    ./scripts/post-deploy.sh
    ./scripts/post-deploy.sh --help

Description:

    After the stack is up, check data directories, container health
    and the HTTP bind ${AUTHENTIK_HOST_IP}:${AUTHENTIK_HTTP_PORT}.

    PostgreSQL must report healthy. The server and the worker must
    pass "ak healthcheck". A skipped check is not treated as success.

EOF
}

###############################################################################
# Main
###############################################################################

case "${1:-}" in

    "")
        ;;

    -h|--help)
        show_help
        exit 0
        ;;

    *)
        fail "Unknown option: ${1}"
        ;;

esac

print_header "Authentik-netcup post deployment"

check_environment

check_docker_environment

post_deploy_checks

print_footer "Post deployment completed."

echo

info "Next step:"
info "  ./scripts/test.sh"

echo
