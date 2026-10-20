#!/usr/bin/env bash

###############################################################################
#
# Nextcloud-Gr Project
#
# File:
#   scripts/init.sh
#
# Description:
#   Prepare the runtime stack inside the existing Incus container.
#   This does not create the container, write .env, create the Docker
#   bridge, or start Compose. The bridge subnet is not known until
#   check-env.sh accepts it. deploy.sh creates the bridge.
#
###############################################################################

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${SCRIPT_DIR}/config.sh"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/logging.sh"
source "${SCRIPT_DIR}/lib/filesystem.sh"
source "${SCRIPT_DIR}/lib/docker.sh"
source "${SCRIPT_DIR}/lib/git.sh"
source "${SCRIPT_DIR}/lib/mount.sh"
source "${SCRIPT_DIR}/lib/checks/load.sh"
source "${SCRIPT_DIR}/lib/deploy/stack.sh"
source "${SCRIPT_DIR}/lib/init/directories.sh"
source "${SCRIPT_DIR}/lib/init/stack.sh"
source "${SCRIPT_DIR}/lib/init/summary.sh"

show_help()
{
cat <<EOF
Nextcloud-Gr Project

Usage:

    ./scripts/init.sh
    ./scripts/init.sh --help

Description:

    Copy DEPLOY_ITEMS into ${STACK_DIR} and prepare directories on
    the /docker-data mount. PostgreSQL and the Nextcloud data
    directory are created later by deploy.sh, after their mount paths
    are set in .env.

    Run this as root inside the Incus container. The next command is
    ./scripts/update-env.sh. Dockge is not installed.

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

print_header "Nextcloud-Gr initialization"

check_environment
require_docker
require_docker_daemon

init_directories
init_stack
init_summary
