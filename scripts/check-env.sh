#!/usr/bin/env bash

###############################################################################
#
# Authentik-netcup Project
#
# File:
#   scripts/check-env.sh
#
# Description:
#   Validate the runtime environment configuration.
#
# Usage:
#   ./scripts/check-env.sh
#   ./scripts/check-env.sh --help
#
#   Rejects a missing variable, an unknown variable, a set_* placeholder,
#   a PostgreSQL password longer than 99 characters, a short
#   AUTHENTIK_SECRET_KEY, conflicting SMTP TLS flags and a backup path
#   that points at Git, the stack or persistent data.
#
#   Does not start containers and does not modify .env.
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
Authentik-netcup Project

Usage:

    ./scripts/check-env.sh
    ./scripts/check-env.sh --help

Description:

    Validate ${ENV_FILE}. Placeholders that start with set_ are
    rejected. An empty BACKUP_EXTERNAL_DIR is valid and means no host
    copy. The project value is /backups, which backup.sh accepts only
    as a mounted mountpoint. An empty BACKUP_AGE_RECIPIENT is valid
    and means backup.sh keeps no archive. The value is a public
    recipient, not an age identity.

    Run this after ./scripts/update-env.sh and before ./scripts/deploy.sh.

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

print_header "Authentik-netcup Environment Check"

check_environment

print_section "Checking .env"

env_validate

print_footer "Environment configuration OK."
