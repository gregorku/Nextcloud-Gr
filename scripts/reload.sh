#!/usr/bin/env bash

###############################################################################
#
# Nextcloud-Gr
#
# File:
#   scripts/reload.sh
#
# Description:
#   Reload Nextcloud-Gr containers.
#
# Usage:
#   ./scripts/reload.sh
#   ./scripts/reload.sh --pull
#   ./scripts/reload.sh --help
#
# What it runs:
#   1. ./scripts/deploy.sh
#      deploy.sh already pulls images once and starts the stack.
#   2. docker compose up -d --force-recreate --remove-orphans
#      --force-recreate replaces the running containers even when the
#      Compose config did not change.
#      --remove-orphans removes services that are no longer in the
#      Compose project. It does not remove DATA_DIR or named volumes
#      outside this project.
#   3. ./scripts/post-deploy.sh
#   4. ./scripts/test.sh
#
# --pull is accepted so existing automation does not fail. It does not
# pull a second time. Image download happens inside deploy.sh.
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
source "${SCRIPT_DIR}/lib/docker-compose.sh"

###############################################################################
# Help
###############################################################################

show_help()
{
cat <<EOF
Nextcloud-Gr

Usage:

    ./scripts/reload.sh
    ./scripts/reload.sh --pull
    ./scripts/reload.sh --help

Options:

    --pull
        Accepted for compatibility. Images are pulled once by deploy.sh.
        This option does not pull them again.

    -h, --help
        Show this help.

Description:

    Run deploy.sh, then recreate the Compose containers:

        docker compose up -d --force-recreate --remove-orphans

    --force-recreate builds new containers from the current config.
    --remove-orphans deletes services that left the Compose file.
    Persistent data in ${DATA_DIR} is not removed.

    deploy.sh refuses a NEXTCLOUD_TAG that differs from the installed
    version. A version change belongs to ./scripts/upgrade.sh. An
    existing config.php without state/installed-version is not started
    here either.
    Afterwards post-deploy.sh and test.sh run.

EOF
}

###############################################################################
# Main
###############################################################################

case "${1:-}" in

    "")
        ;;

    --pull)
        info "--pull is accepted. deploy.sh pulls images once."
        ;;

    -h|--help)
        show_help
        exit 0
        ;;

    *)
        fail "Unknown option: ${1}"
        ;;

esac

print_header "Nextcloud-Gr reload"

###############################################################################
# Deploy
###############################################################################

"${SCRIPT_DIR}/deploy.sh"

###############################################################################
# Reload containers
###############################################################################

print_section "Reload containers"

info "Recreating containers with --force-recreate --remove-orphans."

compose_reload

ok "Containers recreated."

###############################################################################
# Post deployment
###############################################################################

"${SCRIPT_DIR}/post-deploy.sh"

###############################################################################
# Tests
###############################################################################

"${SCRIPT_DIR}/test.sh"

print_footer "Reload finished."
