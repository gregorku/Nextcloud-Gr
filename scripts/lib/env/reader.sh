#!/usr/bin/env bash

###############################################################################
#
# Nextcloud-Gr
#
# File:
#   scripts/lib/env/reader.sh
#
# Description:
#   Read environment configuration files.
#
# Responsibilities:
#   - Read .env.example
#   - Read .env
#   - Read arbitrary environment file
#
###############################################################################

###############################################################################
# Read environment file
#
# Arguments:
#   $1 - Environment file
#   $2 - Name of associative array
#
###############################################################################

env_read_file()
{
    local file="$1"
    local array_name="$2"

    env_parse_file "${file}" "${array_name}"
}

###############################################################################
# Read .env.example
#
# Arguments:
#   $1 - Name of associative array
#
###############################################################################

env_read_example()
{
    local array_name="$1"

    env_read_file \
        "${STACK_DIR}/.env.example" \
        "${array_name}"
}

###############################################################################
# Read .env
#
# Arguments:
#   $1 - Name of associative array
#
###############################################################################

env_read_current()
{
    local array_name="$1"

    env_read_file \
        "${STACK_DIR}/.env" \
        "${array_name}"
}

###############################################################################
# Load environment
#
# Description:
#   Load variables from .env into the current shell.
#
###############################################################################

env_load()
{
    [[ -f "${ENV_FILE}" ]] \
        || fail ".env not found."

    set -a

    # shellcheck disable=SC1090
    source "${ENV_FILE}"

    set +a
}

###############################################################################
# Get environment variable
#
# Arguments:
#   $1 - Variable name
#
# Returns:
#   Variable value from .env
#
###############################################################################

env_get()
{
    local key="$1"

    [[ -f "${ENV_FILE}" ]] \
        || fail ".env not found."

    awk -F= -v key="${key}" '
        $1 == key {
            print substr($0, index($0, "=") + 1)
            exit
        }
    ' "${ENV_FILE}"
}