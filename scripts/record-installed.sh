#!/usr/bin/env bash

###############################################################################
#
# Nextcloud-Gr Project
#
# File:
#   scripts/record-installed.sh
#
# Description:
#   Record installed-version and postgres-major for an existing
#   installation that already has config.php. deploy.sh does not do
#   this. The command verifies the deployed image, the application
#   version and the PostgreSQL major without reading the missing state
#   file. It starts Compose only when version.php and PG_VERSION
#   already match the pins.
#
# Usage:
#   ./scripts/record-installed.sh --confirm nextcloud-gr
#
###############################################################################

set -Eeuo pipefail

umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${SCRIPT_DIR}/config.sh"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/logging.sh"
source "${SCRIPT_DIR}/lib/filesystem.sh"
source "${SCRIPT_DIR}/lib/docker.sh"
source "${SCRIPT_DIR}/lib/docker-compose.sh"
source "${SCRIPT_DIR}/lib/checks/load.sh"
source "${SCRIPT_DIR}/lib/env/load.sh"
source "${SCRIPT_DIR}/lib/nextcloud/occ.sh"
source "${SCRIPT_DIR}/lib/upgrade/version.sh"
source "${SCRIPT_DIR}/lib/deploy/state-file.sh"
source "${SCRIPT_DIR}/lib/post-deploy/checks.sh"
source "${SCRIPT_DIR}/lib/deploy/record-state.sh"

show_help()
{
cat <<EOF
Nextcloud-Gr Project

Usage:

    ./scripts/record-installed.sh --confirm ${STACK_NAME}
    ./scripts/record-installed.sh --help

Description:

    Use this when config.php exists and state/installed-version does
    not. deploy.sh will not start that installation and will not invent
    the state files.

    The command reads version.php and PG_VERSION without the missing
    state file. When the containers are already running, it compares
    their images, occ status and the PostgreSQL major with the pins.
    When they are not running, it starts the pinned images only if the
    code and the data directory already use those versions. A different
    Nextcloud tag or PostgreSQL major is not started.

    State files are written by the post-deploy checks, only after the
    running installation matches. A failed check leaves the previous
    evidence unchanged. A first installation has no config.php: run
    deploy.sh, finish the installation, then post-deploy.sh.

    --confirm must be exactly ${STACK_NAME}.

EOF
}

confirm=""

while [[ $# -gt 0 ]]
do
    case "$1" in
        --confirm)
            [[ $# -ge 2 ]] || fail "--confirm requires the stack name."
            confirm="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            fail "Unknown option: $1"
            ;;
    esac
done

[[ -n "${confirm}" ]] || fail "--confirm is required."

print_header "Nextcloud-Gr record installed version"

check_environment
check_docker_environment
require_command curl

[[ -f "${ENV_FILE}" ]] || fail ".env not found."
env_validate

record_installed_run "${confirm}"

print_footer "Installed version recorded."
