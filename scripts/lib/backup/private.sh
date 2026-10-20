#!/usr/bin/env bash

###############################################################################
#
# Authentik-netcup Project
#
# File:
#   scripts/lib/backup/private.sh
#
# Description:
#   Create and remove backup files without a world-readable window.
#
#   install -m sets the mode at creation. A later chmod is not the
#   only protection. Callers still set umask 077 before they write
#   secrets.
#
#   Removal is best effort. shred overwrites a file once and unlinks
#   it when shred is installed. That does not make the bytes
#   unrecoverable on an SSD, on a copy-on-write filesystem, or in a
#   snapshot. A crash or SIGKILL skips the cleanup and can leave the
#   plaintext directory behind. Without shred the file is only
#   unlinked.
#
###############################################################################

###############################################################################
# Create an empty file that is readable only by its owner
#
# Arguments:
#   $1 - Path
#
###############################################################################

backup_create_private_file()
{
    local path="$1"

    install -m 600 /dev/null "${path}"
}

###############################################################################
# Create a directory that is not traversable by group or others
#
# Arguments:
#   $1 - Path
#
###############################################################################

backup_create_private_dir()
{
    local path="$1"
    local rest="${path#/}"
    local built=""
    local part

    #
    # mkdir -p -m applies the mode only to the last component.
    # Create each missing component with mkdir -m 700 so a parent
    # does not follow the current umask.
    #

    if [[ "${path}" == /* ]]; then
        built="/"
    fi

    while [[ -n "${rest}" ]]
    do
        part="${rest%%/*}"

        if [[ "${rest}" == */* ]]; then
            rest="${rest#*/}"
        else
            rest=""
        fi

        [[ -n "${part}" ]] || continue

        if [[ "${built}" == "/" ]]; then
            built="/${part}"
        elif [[ -z "${built}" ]]; then
            built="${part}"
        else
            built="${built}/${part}"
        fi

        if [[ -L "${built}" ]]; then
            return 1
        fi

        if [[ -d "${built}" ]]; then
            continue
        fi

        mkdir -m 700 "${built}" || return 1
    done

    [[ -d "${path}" ]]
}

###############################################################################
# Copy one tree as owner-only files
#
# Arguments:
#   $1 - Source directory
#   $2 - Destination directory
#
# The destination is created as mode 700. Files are installed as mode
# 600. This is used for the rollback snapshot and for restored trees.
#
###############################################################################

backup_copy_private_tree()
{
    local source="$1"
    local dest="$2"
    local path
    local relative
    local parent

    [[ -d "${source}" ]] || return 1

    backup_create_private_dir "${dest}" || return 1

    while IFS= read -r -d '' path
    do
        relative="${path#"${source}/"}"
        parent="$(dirname "${relative}")"

        if [[ "${parent}" != "." ]]; then
            backup_create_private_dir "${dest}/${parent}" || return 1
        fi

        backup_create_private_file "${dest}/${relative}" || return 1
        cp "${path}" "${dest}/${relative}" || return 1

    done < <(find "${source}" -type f -print0)

    while IFS= read -r -d '' path
    do
        relative="${path#"${source}/"}"

        [[ -n "${relative}" ]] || continue

        backup_create_private_dir "${dest}/${relative}" || return 1

    done < <(find "${source}" -type d -print0)
}

###############################################################################
# Refuse a file that is not mode 600
#
# Arguments:
#   $1 - Path
#
# This does not change the mode.
#
###############################################################################

backup_require_private_file()
{
    local path="$1"
    local mode

    [[ -f "${path}" && ! -L "${path}" ]] || return 1

    mode="$(stat -c '%a' "${path}")" || return 1
    [[ "${mode}" == "600" ]]
}

###############################################################################
# Refuse a tree that is not owner-only
#
# Arguments:
#   $1 - Directory
#
# The directory and every directory under it must be mode 700. Every
# regular file must be mode 600. A symlink is refused. This does not
# change modes.
#
###############################################################################

backup_require_private_tree()
{
    local root="$1"
    local path
    local mode

    [[ -d "${root}" && ! -L "${root}" ]] || return 1

    mode="$(stat -c '%a' "${root}")" || return 1
    [[ "${mode}" == "700" ]] || return 1

    while IFS= read -r -d '' path
    do
        if [[ -L "${path}" ]]; then
            return 1
        fi

        mode="$(stat -c '%a' "${path}")" || return 1

        if [[ -d "${path}" ]]; then
            [[ "${mode}" == "700" ]] || return 1
        elif [[ -f "${path}" ]]; then
            [[ "${mode}" == "600" ]] || return 1
        else
            return 1
        fi

    done < <(find "${root}" -mindepth 1 -print0)
}

###############################################################################
# Remove one file
#
# Arguments:
#   $1 - Path
#
# Best effort only. shred -u -n 1 overwrites and unlinks when shred
# is installed. It does not guarantee erasure on an SSD, on a
# copy-on-write filesystem, or in snapshots. Without shred the file
# is only unlinked. A crash or SIGKILL does not run this function.
#
###############################################################################

backup_destroy_file()
{
    local path="$1"

    [[ -e "${path}" ]] || return 0

    if command -v shred >/dev/null 2>&1; then
        shred -u -n 1 -- "${path}" || return 1
        return 0
    fi

    rm -f -- "${path}"
}

###############################################################################
# Remove files under a directory and remove the directory
#
# Arguments:
#   $1 - Directory
#
# A missing path is success. A failed removal is failure so the caller
# does not report a completed backup or restore. The file removal is
# the same best effort as backup_destroy_file.
#
###############################################################################

backup_destroy_tree()
{
    local root="$1"
    local path

    [[ -n "${root}" ]] || return 0
    [[ -e "${root}" ]] || return 0

    while IFS= read -r -d '' path
    do
        backup_destroy_file "${path}" || return 1

    done < <(find "${root}" -type f -print0)

    rm -rf -- "${root}"
}

###############################################################################
# Remove a plaintext tree or refuse to call the run complete
#
# Arguments:
#   $1 - Directory
#
###############################################################################

backup_discard_plaintext()
{
    local path="$1"

    if backup_destroy_tree "${path}"; then
        return 0
    fi

    warn "Plaintext archive could not be removed: ${path}. This run is not a completed backup."
    return 1
}
