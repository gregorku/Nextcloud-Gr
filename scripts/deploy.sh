#!/usr/bin/env bash

###############################################################################
#
# Nextcloud-Gr Project
#
# File:
#   scripts/deploy.sh
#
# Description:
#   Synchronize the runtime stack and start it when the intended
#   Nextcloud tag matches the installed tag.
#
###############################################################################

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${SCRIPT_DIR}/config.sh"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/logging.sh"
source "${SCRIPT_DIR}/lib/mount.sh"
source "${SCRIPT_DIR}/lib/docker-compose.sh"
source "${SCRIPT_DIR}/lib/checks/load.sh"
source "${SCRIPT_DIR}/lib/env/load.sh"
source "${SCRIPT_DIR}/lib/upgrade/version.sh"
source "${SCRIPT_DIR}/lib/deploy/stack.sh"
source "${SCRIPT_DIR}/lib/deploy/verify.sh"
source "${SCRIPT_DIR}/lib/deploy/check-env.sh"
source "${SCRIPT_DIR}/lib/deploy/dockge.sh"
source "${SCRIPT_DIR}/lib/deploy/wait.sh"
source "${SCRIPT_DIR}/lib/deploy/compose.sh"
source "${SCRIPT_DIR}/lib/deploy/summary.sh"
source "${SCRIPT_DIR}/lib/deploy/restart.sh"
source "${SCRIPT_DIR}/lib/deploy/version-guard.sh"
source "${SCRIPT_DIR}/lib/deploy/storage.sh"
source "${SCRIPT_DIR}/lib/deploy/render.sh"

show_help()
{
cat <<EOF
Nextcloud-Gr Project

Usage:

    ./scripts/deploy.sh
    ./scripts/deploy.sh --help

Description:

    Synchronize DEPLOY_ITEMS into ${STACK_DIR}, validate .env and
    refuse to continue when NEXTCLOUD_TAG differs from the recorded
    installed version. A first installation has neither
    ${INSTALLED_VERSION_FILE} nor config.php. An existing config.php
    without that state file is not a first installation: deploy.sh
    does not start it. Use ./scripts/record-installed.sh --confirm
    ${STACK_NAME} to verify the deployed version, or post-deploy.sh
    when the pinned images are already running.

    rsync --delete applies only to compose/ and configs/. It does not
    delete .env, ${DATA_DIR}, PostgreSQL, the Nextcloud data directory
    or ${BACKUP_LOCAL_DIR}.

    Dockge is only checked. It is not installed or replaced.

EOF
}

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

print_header "Nextcloud-Gr deployment"

check_environment
check_docker_environment
deploy_sync_stack
deploy_verify_project
deploy_check_env
deploy_assert_same_version
deploy_prepare_storage
deploy_ensure_network
deploy_render_runtime
deploy_dockge
deploy_validate_compose
deploy_compose
deploy_restart_services
deploy_wait_dockge
deploy_summary

print_footer "Deployment completed."
