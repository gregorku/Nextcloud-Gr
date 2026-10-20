#!/usr/bin/env bash

###############################################################################
#
# Authentik-netcup Project
#
# File:
#   scripts/lib/env/parser.sh
#
# Description:
#   Parse .env files into associative arrays.
#
# Responsibilities:
#   - Read KEY=VALUE pairs
#   - Ignore comments
#   - Ignore blank lines
#   - Preserve values exactly
#
###############################################################################

###############################################################################
# Parse environment file
#
# Arguments:
#   $1 - Environment file
#   $2 - Name of associative array
#
# Example:
#
#   declare -A ENV
#
#   env_parse_file ".env" ENV
#
###############################################################################

env_parse_file()
{
    local file="$1"
    local array_name="$2"

    [[ -f "${file}" ]] \
        || fail "Environment file not found: ${file}"

    #
    # Create associative array if it does not exist.
    #

    eval "declare -g -A ${array_name}=()"

    local line
    local key
    local value

    while IFS= read -r line || [[ -n "${line}" ]]
    do
        #
        # Ignore comments.
        #

        [[ "${line}" =~ ^[[:space:]]*# ]] && continue

        #
        # Ignore empty lines.
        #

        [[ -z "${line}" ]] && continue

        #
        # Ignore invalid entries.
        #

        [[ "${line}" != *=* ]] && continue

        key="${line%%=*}"
        value="${line#*=}"

        #
        # Trim whitespace around key.
        #

        key="${key#"${key%%[![:space:]]*}"}"
        key="${key%"${key##*[![:space:]]}"}"

        eval "${array_name}[\"\${key}\"]=\"\${value}\""

    done < "${file}"
}