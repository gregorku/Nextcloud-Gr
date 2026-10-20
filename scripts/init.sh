#!/usr/bin/env bash

###############################################################################
#
# Authentik-netcup Project
#
# File:
#   scripts/init.sh
#
# Description:
#   Initialize the Authentik-netcup project inside the existing Incus
#   container 10.10.10.100.
#
# Usage:
#   ./scripts/init.sh
#   ./scripts/init.sh --help
#
# Responsibilities:
#   - Verify environment
#   - Prepare persistent data directories
#   - Prepare the runtime stack from DEPLOY_ITEMS
#   - Create the Docker network
#   - Prepare PostgreSQL and Authentik directory ownership
#
# Side effects:
#   - Creates /docker-data/authentik-netcup and
#     /docker-data/backups/authentik-netcup
#   - Replaces compose.yml, compose/, configs/ and .env.example in
#     /docker-data/stacks/authentik-netcup
#   - Creates the Docker network authentik-netcup when it is missing
#
# This script does not create the Incus container, does not write the
# runtime .env and does not start containers.
#
# Next step:
#   ./scripts/update-env.sh
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
# Stack path guards and the initial copy
###############################################################################

source "${SCRIPT_DIR}/lib/deploy/stack.sh"

###############################################################################
# Initialization modules
###############################################################################

source "${SCRIPT_DIR}/lib/init/directories.sh"
source "${SCRIPT_DIR}/lib/init/stack.sh"
source "${SCRIPT_DIR}/lib/init/networks.sh"
source "${SCRIPT_DIR}/lib/init/postgresql.sh"
source "${SCRIPT_DIR}/lib/init/authentik.sh"
source "${SCRIPT_DIR}/lib/init/summary.sh"

###############################################################################
# Help
###############################################################################

show_help()
{
cat <<EOF
Authentik-netcup Project

Usage:

    ./scripts/init.sh
    ./scripts/init.sh --help

Description:

    Prepare directories, copy DEPLOY_ITEMS into the runtime stack and
    create the Docker network ${NETWORK_INTERNAL}
    (${NETWORK_INTERNAL_SUBNET}).

    Run this inside the Incus container ${AUTHENTIK_HOST_IP}, as root.
    The next command is ./scripts/update-env.sh.

    init.sh does not start Docker Compose and does not install Dockge.

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

print_header "Authentik-netcup initialization"

#
# Verify environment.
#
check_environment

#
# Prepare persistent directories.
#
init_directories

#
# Prepare project stack.
#
init_stack

#
# Create Docker network.
#
init_networks

#
# Prepare PostgreSQL layout.
#
init_postgresql

#
# Prepare Authentik layout.
#
init_authentik

#
# Print summary.
#
init_summary
