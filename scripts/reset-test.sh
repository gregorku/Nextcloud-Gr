#!/usr/bin/env bash

###############################################################################
#
# Nextcloud-Gr Project
#
# File:
#   scripts/reset-test.sh
#
# Description:
#   Empty this test instance so the next deploy.sh can install it.
#   deploy.sh does not call this script.
#
# Usage:
#   ./scripts/reset-test.sh --confirm nextcloud-gr
#
###############################################################################

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${SCRIPT_DIR}/config.sh"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/logging.sh"
source "${SCRIPT_DIR}/lib/filesystem.sh"
source "${SCRIPT_DIR}/lib/docker.sh"
source "${SCRIPT_DIR}/lib/docker-compose.sh"
source "${SCRIPT_DIR}/lib/checks/load.sh"
source "${SCRIPT_DIR}/lib/env/load.sh"
source "${SCRIPT_DIR}/lib/mount.sh"
source "${SCRIPT_DIR}/lib/deploy/reset.sh"

show_help()
{
cat <<EOF
Nextcloud-Gr Project

Usage:

    ./scripts/reset-test.sh --confirm ${STACK_NAME}
    ./scripts/reset-test.sh --help

Description:

    Stop this stack and remove only the children of:

      \${NEXTCLOUD_HTML_HOST_DIR}   Nextcloud code and config.php
      ${NEXTCLOUD_STATE_DIR}        installed-version and upgrade lock
      \${NEXTCLOUD_DATA_HOST_DIR}   Nextcloud data, including a leftover
                                   admin home from a failed install
      \${POSTGRESQL_HOST_DIR}       PostgreSQL cluster for this instance

    Each path must already exist, must not be a mountpoint, and must
    match the container mount when that container exists. The parent
    mount is not removed.

    Kept: ${ENV_FILE}, ${BACKUP_LOCAL_DIR}, ${DOCKGE_DIR}, Docker
    network ${NETWORK_INTERNAL}, and Redis configuration under
    ${STACK_DIR}/runtime. Redis has no data volume.

    This does not install Nextcloud. The next command is
    ./scripts/deploy.sh.

EOF
}

case "${1:-}" in
    -h|--help)
        show_help
        exit 0
        ;;
    --confirm)
        [[ "${2:-}" == "${STACK_NAME}" ]] \
            || fail "Refusing reset without --confirm ${STACK_NAME}. Nothing was deleted."
        ;;
    *)
        fail "Refusing reset. Run ./scripts/reset-test.sh --confirm ${STACK_NAME}. Nothing was deleted."
        ;;
esac

print_header "Nextcloud-Gr test reset"

check_docker_environment
reset_test_instance

print_footer "Test reset completed."

echo
info "Next step:"
info "  ./scripts/deploy.sh"
echo
