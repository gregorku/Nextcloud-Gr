#!/usr/bin/env bash

###############################################################################
#
# Nextcloud-Gr
#
# File:
#   scripts/lib/checks/filesystem.sh
#
# Description:
#   Filesystem validation functions.
#
###############################################################################

###############################################################################
# Require directory
###############################################################################

require_directory()
{
    local directory="$1"

    [[ -d "${directory}" ]] \
        || fail "Directory not found: ${directory}"
}

###############################################################################
# Require file
###############################################################################

require_file()
{
    local file="$1"

    [[ -f "${file}" ]] \
        || fail "File not found: ${file}"
}

###############################################################################
# Require file or directory
###############################################################################

require_file_or_directory()
{
    local path="$1"

    [[ -e "${path}" ]] \
        || fail "Path not found: ${path}"
}

###############################################################################
# Verify file permissions
###############################################################################

permissions_are()
{
    local expected="$1"
    local file="$2"

    local current

    current="$(stat -c '%a' "${file}")"

    [[ "${current}" == "${expected}" ]] \
        || fail "Permissions ${current}, expected ${expected}: ${file}"

    ok "Permissions ${expected}: ${file}"
}