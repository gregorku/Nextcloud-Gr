#!/usr/bin/env bash

###############################################################################
#
# Authentik-netcup Project
#
# File:
#   scripts/deploy.sh
#
# Description:
#   Deploy Authentik-netcup services inside the existing Incus container.
#
# Usage:
#   ./scripts/deploy.sh
#   ./scripts/deploy.sh --help
#
# Responsibilities:
#   - Verify the deployment environment
#   - Synchronize DEPLOY_ITEMS into the runtime stack
#   - Verify .env
#   - Verify the existing Dockge container
#   - Validate Docker Compose
#   - Pull images and start the stack
#
# Side effects:
#   - rsync --delete may remove files under STACK_DIR/compose and
#     STACK_DIR/configs that are no longer in Git
#   - Does not modify DATA_DIR, backup archives or the runtime .env
#   - Pulls images and runs docker compose up -d
#   - Does not reinstall Dockge
#
# Next step:
#   ./scripts/post-deploy.sh
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

###############################################################################
# Docker Compose library
###############################################################################

source "${SCRIPT_DIR}/lib/docker-compose.sh"

###############################################################################
# Checks
###############################################################################

source "${SCRIPT_DIR}/lib/checks/load.sh"

###############################################################################
# Environment
###############################################################################

source "${SCRIPT_DIR}/lib/env/load.sh"

###############################################################################
# Deployment modules
###############################################################################

source "${SCRIPT_DIR}/lib/deploy/stack.sh"
source "${SCRIPT_DIR}/lib/deploy/verify.sh"
source "${SCRIPT_DIR}/lib/deploy/check-env.sh"
source "${SCRIPT_DIR}/lib/deploy/dockge.sh"
source "${SCRIPT_DIR}/lib/deploy/wait.sh"
source "${SCRIPT_DIR}/lib/deploy/compose.sh"
source "${SCRIPT_DIR}/lib/deploy/summary.sh"
source "${SCRIPT_DIR}/lib/deploy/restart.sh"

###############################################################################
# Help
###############################################################################

show_help()
{
cat <<EOF
Authentik-netcup Project

Usage:

    ./scripts/deploy.sh
    ./scripts/deploy.sh --help

Description:

    Synchronize the Git checkout into ${STACK_DIR}, validate .env and
    Compose, pull the pinned images and start the stack.

    Directory items in DEPLOY_ITEMS are synchronized with
    rsync --delete. That removes files deleted from compose/ and
    configs/ in Git. It does not delete .env, ${DATA_DIR} or
    ${BACKUP_LOCAL_DIR}.

    Dockge is only checked. It is not installed or replaced.

    Run this inside the Incus container ${AUTHENTIK_HOST_IP}, as root,
    after ./scripts/update-env.sh and ./scripts/check-env.sh.

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

print_header "Authentik-netcup deployment"

#
# Verify environment.
#
check_environment

#
# Verify Docker environment.
#
check_docker_environment

#
# Sync project structure.
#
deploy_sync_stack

#
# Verify project structure.
#
deploy_verify_project

#
# Verify .env.
#
deploy_check_env

#
# Confirm existing Dockge. Do not reinstall it.
#
deploy_dockge

#
# Validate Docker Compose configuration.
#
deploy_validate_compose

#
# Pull images and start the stack.
#
deploy_compose

deploy_restart_services

#
# Wait until Dockge is ready.
#
deploy_wait_dockge

#
# Print deployment summary.
#
deploy_summary

print_footer "Deployment completed."
