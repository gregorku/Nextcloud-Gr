#!/usr/bin/env bash

###############################################################################
#
# Authentik-netcup Project
#
# File:
#   scripts/lib/env/constants.sh
#
# Description:
#   Environment library constants.
#
###############################################################################

###############################################################################
# Temporary files
###############################################################################

readonly ENV_TMP_FILE="${STACK_DIR}/.env.tmp"
readonly ENV_BACKUP_PREFIX="${STACK_DIR}/.env.bak"