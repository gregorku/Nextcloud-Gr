#!/usr/bin/env bash

###############################################################################
#
# Authentik-netcup Project
#
# File:
#   scripts/install-dockge.sh
#
# Description:
#   Refuse to install or replace Dockge.
#
# Usage:
#   ./scripts/install-dockge.sh
#
#   The Authentik Incus container already runs Dockge against
#   /docker-data/stacks. Installing it again would remove the running
#   container. That is not part of this project.
#
#   deploy.sh only checks that the existing container is running.
#   The Authentik stack appears in Dockge when
#   /docker-data/stacks/authentik-netcup/compose.yml is present.
#
###############################################################################

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=scripts/config.sh
source "${SCRIPT_DIR}/config.sh"

# shellcheck source=scripts/lib/logging.sh
source "${SCRIPT_DIR}/lib/logging.sh"

fail "Refusing to install Dockge. The container ${DOCKGE_CONTAINER} is managed outside this project and uses ${STACKS_DIR}."
