#!/usr/bin/env bash

###############################################################################
#
# Nextcloud-Gr
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
# Compare the manifest tag with the runtime Nextcloud tag
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
# Read NEXTCLOUD_ADMIN_PASSWORD without sourcing the file
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
            $1 == "NEXTCLOUD_ADMIN_PASSWORD" {
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

    [[ "${#key}" -ge 16 ]]
}

###############################################################################
# Custom-format PostgreSQL dump, not a MariaDB or MySQL text dump
#
# Arguments:
#   $1 - Dump file
#
###############################################################################

backup_dump_is_postgres_custom()
{
    local file="$1"
    local signature

    [[ -s "${file}" ]] || return 1

    signature="$(head -c 5 "${file}" || true)"
    [[ "${signature}" == "PGDMP" ]] || return 1

    if grep -a -q -E 'MariaDB dump|MySQL dump|ENGINE=InnoDB' "${file}"; then
        return 1
    fi

    return 0
}

###############################################################################
# PostgreSQL major recorded in the manifest
#
# Arguments:
#   $1 - Manifest major
#   $2 - Expected major
#   $3 - Kept for callers. A Nextcloud version mismatch flag must not
#        accept a different PostgreSQL major.
#
###############################################################################

restore_postgres_major_ok()
{
    local manifest_major="$1"
    local expected_major="$2"

    [[ "${manifest_major}" =~ ^[0-9]+$ ]] || return 1
    [[ "${manifest_major}" == "${expected_major}" ]]
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

    [[ -d "${stage}/nextcloud/config" ]] \
        || fail "Archive is missing nextcloud/config."

    [[ -d "${stage}/nextcloud/custom_apps" ]] \
        || fail "Archive is missing nextcloud/custom_apps."

    [[ -d "${stage}/nextcloud/themes" ]] \
        || fail "Archive is missing nextcloud/themes."

    [[ -s "${stage}/postgresql/nextcloud.dump" ]] \
        || fail "PostgreSQL dump is missing or empty."

    if ! backup_dump_is_postgres_custom "${stage}/postgresql/nextcloud.dump"; then
        fail "Database dump is not a PostgreSQL custom-format archive. A MariaDB dump cannot be restored into PostgreSQL."
    fi

    [[ -f "${stage}/stack.env" ]] \
        || fail "Archive is missing stack.env."

    if ! key="$(restore_read_secret_key "${stage}/stack.env")"; then
        fail "The archive has no NEXTCLOUD_ADMIN_PASSWORD."
    fi

    if ! restore_secret_is_usable "${key}"; then
        fail "NEXTCLOUD_ADMIN_PASSWORD in the archive is empty, a placeholder, or shorter than 16 characters."
    fi

    unset key

    backup_verify_tree "${stage}"

    local manifest_engine
    local snapshot

    manifest_engine="$(backup_manifest_field "${stage}/manifest.txt" database_engine)"
    [[ "${manifest_engine}" == "postgresql" ]] \
        || fail "Manifest database_engine is not postgresql."

    snapshot="$(backup_manifest_field "${stage}/manifest.txt" restic_snapshot_id)"
    backup_restic_snapshot_id_is_valid "${snapshot}" \
        || fail "Manifest restic snapshot id is missing or not a restic id."

    #
    # Older manifests omit this field. An empty or missing value stays
    # valid. It does not by itself identify a copied snapshot.
    #

    if grep -q '^restic_external_snapshot_id=.' "${stage}/manifest.txt"; then
        local external_snapshot
        external_snapshot="$(backup_manifest_field "${stage}/manifest.txt" restic_external_snapshot_id)"
        backup_restic_snapshot_id_is_valid "${external_snapshot}" \
            || fail "Manifest restic external snapshot id is not a restic id."
    fi
}
