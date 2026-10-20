#!/usr/bin/env bash

###############################################################################
#
# Nextcloud-Gr Project
#
# File:
#   scripts/lib/mount.sh
#
# Description:
#   Refuse to create application data on the container root filesystem.
#   A missing Incus disk must stop deployment.
#
###############################################################################

storage_require_findmnt()
{
    command -v findmnt >/dev/null 2>&1 \
        || fail "findmnt is required to verify mounts."
}

###############################################################################
# Mountpoint that covers a path
#
# Arguments:
#   $1 - Existing path
#
###############################################################################

storage_mount_target()
{
    local path="$1"

    storage_require_findmnt
    findmnt -T "${path}" -n -o TARGET
}

###############################################################################
# /docker-data must be the Incus disk, not a directory on /
#
# Arguments:
#   $1 - Path that must itself be a mountpoint
#
###############################################################################

storage_require_mountpoint()
{
    local path="$1"
    local mount

    [[ -d "${path}" ]] \
        || fail "${path} does not exist. Refusing to create it on the root filesystem."

    mount="$(storage_mount_target "${path}")" \
        || fail "Cannot determine the filesystem of ${path}."

    [[ "${mount}" == "${path}" ]] \
        || fail "${path} is not a mountpoint. Attach the Incus disk before using it."
}

###############################################################################
# Create only the leaf directory when its parent is already on a
# non-root mount and the leaf is not the mountpoint itself.
#
# Arguments:
#   $1 - Directory
#   $2 - Purpose, used in errors
#
###############################################################################

storage_require_ready_directory()
{
    local path="$1"
    local purpose="$2"
    local parent
    local mount

    [[ "${path}" == /* && "${path}" != "/" ]] \
        || fail "${purpose} path is not usable."

    parent="$(dirname "${path}")"

    [[ -d "${parent}" ]] \
        || fail "${purpose} parent ${parent} does not exist. Refusing to create parent directories."

    mount="$(storage_mount_target "${parent}")" \
        || fail "Cannot determine the filesystem of ${parent}."

    [[ -n "${mount}" && "${mount}" != "/" ]] \
        || fail "${purpose} parent ${parent} is on the root filesystem. Mount an Incus disk first."

    [[ "${path}" != "${mount}" ]] \
        || fail "${purpose} ${path} is the mountpoint itself. Use a directory inside that filesystem."

    if [[ ! -d "${path}" ]]; then
        mkdir "${path}" \
            || fail "Could not create ${path}."
    fi
}
