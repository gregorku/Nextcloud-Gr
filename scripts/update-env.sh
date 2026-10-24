#!/usr/bin/env bash

###############################################################################
#
# Nextcloud-Gr
#
# File:
#   scripts/update-env.sh
#
# Description:
#   Create or synchronize the project .env file.
#
# Usage:
#   ./scripts/update-env.sh
#   ./scripts/update-env.sh --help
#
# Workflow:
#   - Check environment.
#   - Require the runtime stack copy of .env.example (init.sh).
#   - If .env does not exist, create it from .env.example.
#   - Synchronize it with .env.example:
#       * framework values come from .env.example
#       * user values are kept when they are non-empty
#       * generated secrets are kept when they are not placeholders
#       * a missing or placeholder secret is generated once
#       * variables removed from .env.example are dropped
#   - Write .env through a temporary file after a timestamped backup.
#
# Side effects:
#   - Creates ${STACK_DIR}/.env.bak-YYYYMMDD-HHMMSS
#   - Mode of .env and the backup is 600
#   - Does not print generated secrets
#
# Next step:
#   Replace remaining set_* placeholders, then ./scripts/check-env.sh
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
# Environment library
###############################################################################

source "${SCRIPT_DIR}/lib/env/load.sh"

###############################################################################
# Help
###############################################################################

show_help()
{
cat <<EOF
Nextcloud-Gr

Usage:

    ./scripts/update-env.sh
    ./scripts/update-env.sh --help

Description:

    Synchronize ${ENV_FILE} with ${ENV_EXAMPLE_FILE}.

    framework values are taken from the example.
    user values already set are kept.
    generated secrets are created only when missing or still set_*.
    An existing PG_PASS, REDIS_PASSWORD, NEXTCLOUD_ADMIN_PASSWORD or
    RESTIC_PASSWORD is not rotated. Changing NEXTCLOUD_TAG in the
    example does not upgrade Nextcloud. deploy.sh refuses a tag that
    differs from state/installed-version and points to upgrade.sh.

    Run ./scripts/init.sh first so the example exists in the stack
    directory. Then edit the remaining placeholders and run
    ./scripts/check-env.sh.

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

print_header "Updating .env"

check_environment

env_sync

print_footer ".env ready."
