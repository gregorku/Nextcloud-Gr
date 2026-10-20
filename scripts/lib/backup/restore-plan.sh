#!/usr/bin/env bash

###############################################################################
#
# Authentik-netcup Project
#
# File:
#   scripts/lib/backup/restore-plan.sh
#
# Description:
#   Decisions made before a restore writes anything.
#
#   The static tests call these functions. They do not copy files into
#   DATA_DIR and they do not call pg_restore.
#
###############################################################################

###############################################################################
# Confirmation must be the stack name, typed explicitly
#
# Arguments:
#   $1 - Value passed to --confirm
#
###############################################################################

restore_confirmation_matches()
{
    local confirm="$1"

    [[ "${confirm}" == "${STACK_NAME}" ]]
}

###############################################################################
# Compare the manifest tag with the runtime Authentik tag
#
# Arguments:
#   $1 - Tag recorded in the manifest
#   $2 - Tag in the current .env
#   $3 - "yes" to allow a mismatch
#
###############################################################################

restore_versions_match()
{
    local manifest_tag="$1"
    local runtime_tag="$2"
    local allow_mismatch="$3"

    if [[ "${manifest_tag}" == "${runtime_tag}" ]]; then
        return 0
    fi

    [[ "${allow_mismatch}" == "yes" ]]
}

###############################################################################
# Read AUTHENTIK_SECRET_KEY without sourcing the file
#
# Arguments:
#   $1 - Environment file
#
# The value is written to stdout. Callers must not log it.
#
###############################################################################

restore_read_secret_key()
{
    local file="$1"
    local value

    [[ -f "${file}" ]] || return 1

    value="$(
        awk -F= '
            $1 == "AUTHENTIK_SECRET_KEY" {
                print substr($0, index($0, "=") + 1)
                exit
            }
        ' "${file}"
    )"

    [[ -n "${value}" ]] || return 1

    printf '%s\n' "${value}"
}

###############################################################################
# Secret key is usable for a restore
#
# Arguments:
#   $1 - Key value
#
###############################################################################

restore_secret_is_usable()
{
    local key="$1"

    [[ -n "${key}" ]] || return 1

    [[ "${key}" != *$'\n'* ]] || return 1

    if env_is_placeholder "${key}"; then
        return 1
    fi

    [[ "${#key}" -ge 50 ]]
}

###############################################################################
# Reject an archive that restore cannot apply safely
#
# Arguments:
#   $1 - Extracted stage directory
#
# This function only reads the stage. It does not change live data.
#
###############################################################################

restore_validate_stage()
{
    local stage="$1"
    local key

    [[ -d "${stage}/authentik/data" ]] \
        || fail "Archive is missing authentik/data."

    [[ -d "${stage}/authentik/templates" ]] \
        || fail "Archive is missing authentik/templates."

    [[ -d "${stage}/authentik/certs" ]] \
        || fail "Archive is missing authentik/certs."

    [[ -s "${stage}/postgresql/authentik.dump" ]] \
        || fail "PostgreSQL dump is missing or empty."

    [[ -f "${stage}/stack.env" ]] \
        || fail "Archive is missing stack.env."

    if ! key="$(restore_read_secret_key "${stage}/stack.env")"; then
        fail "The archive has no AUTHENTIK_SECRET_KEY."
    fi

    if ! restore_secret_is_usable "${key}"; then
        fail "AUTHENTIK_SECRET_KEY in the archive is empty, a placeholder, or shorter than 50 characters."
    fi

    unset key

    backup_verify_tree "${stage}"
}
