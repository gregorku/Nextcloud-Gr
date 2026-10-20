#!/usr/bin/env bash

###############################################################################
#
# Authentik-netcup Project
#
# File:
#   scripts/lib/filesystem.sh
#
# Description:
#   Filesystem helper functions.
#
###############################################################################

###############################################################################
# Create directory
#
# Usage:
#   ensure_directory /path/to/directory
#
###############################################################################

ensure_directory() {

    local directory="$1"

    mkdir -p "${directory}"

    ok "Directory ready: ${directory}"
}

###############################################################################
# Create directory with a specific owner
#
# Usage:
#   ensure_directory_owner /path/to/directory 65534:65534
#
# Notes:
#   Needed for containers that run as a non-root user and
#   would otherwise get "permission denied" writing to a
#   bind-mounted directory owned by root.
#
###############################################################################

ensure_directory_owner() {

    local directory="$1"
    local owner="$2"

    ensure_directory "${directory}"

    chown -R "${owner}" "${directory}"

    ok "Owner ${owner}: ${directory}"
}

###############################################################################
# Create file
#
# Usage:
#   ensure_file /path/to/file
#
###############################################################################

ensure_file() {

    local file="$1"

    if [[ ! -f "${file}" ]]; then
        touch "${file}"
    fi

    ok "File ready: ${file}"
}

###############################################################################
# Create file with permissions
#
# Usage:
#   ensure_file_mode /path/to/file 600
#
###############################################################################

ensure_file_mode() {

    local file="$1"
    local mode="$2"

    ensure_file "${file}"

    chmod "${mode}" "${file}"

    ok "Permissions ${mode}: ${file}"
}

###############################################################################
# Remove file
#
# Usage:
#   remove_file /path/to/file
#
###############################################################################

remove_file() {

    local file="$1"

    if [[ -f "${file}" ]]; then
        rm -f "${file}"
        ok "Removed file: ${file}"
    fi
}

###############################################################################
# Remove directory
#
# Usage:
#   remove_directory /path/to/directory
#
###############################################################################

remove_directory() {

    local directory="$1"

    if [[ -d "${directory}" ]]; then
        rm -rf "${directory}"
        ok "Removed directory: ${directory}"
    fi
}

###############################################################################
# Backup file
#
# Arguments:
#   $1 - Source file
#   $2 - Backup prefix
#
# Example:
#   backup_file "/etc/test.conf" "/etc/test.conf.bak"
#
###############################################################################

backup_file()
{
    local source="$1"
    local prefix="$2"

    [[ -f "${source}" ]] || return

    local backup

    backup="${prefix}-$(date +%Y%m%d-%H%M%S)"

    cp "${source}" "${backup}"

    ok "Backup created: $(basename "${backup}")"
}
