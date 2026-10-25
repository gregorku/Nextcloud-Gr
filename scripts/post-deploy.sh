#!/usr/bin/env bash

###############################################################################
#
# Nextcloud-Gr
#
# File:
#   scripts/post-deploy.sh
#
# Description:
#   Check the running Nextcloud stack after deploy or reload.
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
source "${SCRIPT_DIR}/lib/nextcloud/occ.sh"
source "${SCRIPT_DIR}/lib/upgrade/version.sh"
source "${SCRIPT_DIR}/lib/deploy/state-file.sh"

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
Nextcloud-Gr Project

Usage:

    ./scripts/post-deploy.sh
    ./scripts/post-deploy.sh --help

Description:

    Wait until PostgreSQL, Redis, PHP-FPM, Nginx and cron are healthy.
    Confirm the running images, occ status, APCu, /status.php and that
    database ports are not published. An unfinished first installation
    does not get state files. Record the installed Nextcloud tag and
    the PostgreSQL major only after every check passes. The files are
    replaced atomically. A failed check leaves the previous evidence
    unchanged.

    This requires the containers to be running. When config.php exists
    and the stack is stopped, run ./scripts/record-installed.sh
    --confirm ${STACK_NAME} instead of starting a different version
    with deploy.sh.

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

print_header "Nextcloud-Gr post deployment"

check_environment
check_docker_environment
require_command curl

post_deploy_checks

print_footer "Post deployment completed."

echo

info "Next step:"
info "  ./scripts/test.sh"

echo
