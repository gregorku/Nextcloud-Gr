#!/usr/bin/env bash

###############################################################################
#
# Nextcloud-Gr Project
#
# File:
#   scripts/lib/deploy/state-file.sh
#
# Description:
#   Replace state files by writing a temporary file in the same
#   directory and renaming it. Callers must run every check before
#   this. installed-version is renamed last: deploy.sh treats a missing
#   installed-version as "do not start" when config.php exists, so a
#   crash between the two renames cannot advertise a finished deploy.
#
###############################################################################

state_write_file()
{
    local dest="$1"
    local value="$2"
    local directory
    local tmp

    [[ "${value}" =~ ^[A-Za-z0-9._:-]+$ ]] || return 1

    directory="$(dirname "${dest}")"
    mkdir -p "${directory}"
    chmod 700 "${directory}"

    tmp="$(mktemp "${directory}/.state.XXXXXX")" || return 1
    chmod 600 "${tmp}"

    if ! printf '%s\n' "${value}" > "${tmp}"; then
        rm -f "${tmp}"
        return 1
    fi

    if ! mv -f "${tmp}" "${dest}"; then
        rm -f "${tmp}"
        return 1
    fi

    chmod 600 "${dest}"
}

###############################################################################
# Arguments:
#   $1 - Nextcloud tag
#   $2 - PostgreSQL major
#   $3 - installed-version path, default INSTALLED_VERSION_FILE
#   $4 - postgres-major path, default POSTGRES_MAJOR_FILE
#
# The PostgreSQL file is replaced first. The version file is the gate
# deploy.sh reads before it will start an existing installation. If the
# version rename fails, the previous PostgreSQL file is restored, and a
# file created by this call is removed.
#
###############################################################################

state_write_installed()
{
    local tag="$1"
    local major="$2"
    local version_file="${3:-${INSTALLED_VERSION_FILE}}"
    local major_file="${4:-${POSTGRES_MAJOR_FILE}}"
    local directory
    local previous=""
    local had_previous=0

    if [[ -f "${major_file}" ]]; then
        had_previous=1
        directory="$(dirname "${major_file}")"
        previous="$(mktemp "${directory}/.state.XXXXXX")" || return 1
        if ! chmod 600 "${previous}"; then
            rm -f "${previous}"
            return 1
        fi
        if ! cat "${major_file}" > "${previous}"; then
            rm -f "${previous}"
            return 1
        fi
    fi

    if ! state_write_file "${major_file}" "${major}"; then
        rm -f "${previous}"
        return 1
    fi

    if ! state_write_file "${version_file}" "${tag}"; then
        if [[ "${had_previous}" -eq 1 ]]; then
            if ! mv -f "${previous}" "${major_file}"; then
                rm -f "${previous}"
                return 1
            fi
            chmod 600 "${major_file}" || return 1
        else
            rm -f "${major_file}" "${previous}"
        fi
        return 1
    fi

    rm -f "${previous}"
}
