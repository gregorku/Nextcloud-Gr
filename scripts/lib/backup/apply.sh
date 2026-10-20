#!/usr/bin/env bash

###############################################################################
#
# Authentik-netcup Project
#
# File:
#   scripts/lib/backup/apply.sh
#
# Description:
#   Apply a verified backup stage, or put the previous files, runtime
#   secret key and database dump back.
#
#   Nothing in this file deletes live data until a rollback snapshot
#   has been written and checked. A failed database load returns an
#   error. It does not exit, so the caller can roll back.
#
#   Static tests replace restore_snapshot_database,
#   restore_load_database and restore_database_is_ready. Those tests
#   pass temporary paths and do not call Docker.
#
###############################################################################

RESTORE_ERROR=""
RESTORE_MUTATION_STARTED=no
RESTORE_VERIFIED=no
RESTORE_ROLLBACK_DONE=no
RESTORE_ROLLBACK_ATTEMPTED=no
RESTORE_KEEP_ROLLBACK=no
RESTORE_LIVE_ROOT=""
RESTORE_ENV_FILE=""
RESTORE_ROLLBACK_DIR=""

###############################################################################
# Dump the live database into the rollback directory
#
# Arguments:
#   $1 - Output file
#
# Flags match backup_dump_postgresql. The status is returned so a
# failed snapshot does not skip the caller's cleanup.
#
###############################################################################

restore_snapshot_database()
{
    local output="$1"
    local db_user
    local db_name

    db_user="$(env_get PG_USER)" || return 1
    db_name="$(env_get PG_DB)" || return 1

    [[ -n "${db_user}" && -n "${db_name}" ]] || return 1

    backup_create_private_dir "$(dirname "${output}")" || return 1
    backup_create_private_file "${output}" || return 1

    if ! docker exec -u postgres "${POSTGRESQL_CONTAINER}" \
        pg_dump \
            -U "${db_user}" \
            -d "${db_name}" \
            -Fc \
            --no-owner \
            --no-acl \
        > "${output}"
    then
        rm -f "${output}"
        return 1
    fi

    [[ -s "${output}" ]]
}

###############################################################################
# Load a custom-format dump
#
# Arguments:
#   $1 - Dump file
#
# Flags match backup_restore_postgresql. Success here is only the
# pg_restore status. The caller still has to check files and the key.
#
###############################################################################

restore_load_database()
{
    local input="$1"
    local db_user
    local db_name

    [[ -s "${input}" ]] || return 1

    db_user="$(env_get PG_USER)" || return 1
    db_name="$(env_get PG_DB)" || return 1

    [[ -n "${db_user}" && -n "${db_name}" ]] || return 1

    if ! docker exec -i -u postgres "${POSTGRESQL_CONTAINER}" \
        pg_restore \
            -U "${db_user}" \
            -d "${db_name}" \
            --clean \
            --if-exists \
            --no-owner \
            --no-acl \
            --single-transaction \
        < "${input}"
    then
        return 1
    fi
}

###############################################################################
# PostgreSQL is still running after a restore attempt
###############################################################################

restore_database_is_ready()
{
    local status

    docker_container_running "${POSTGRESQL_CONTAINER}" || return 1

    status="$(
        docker inspect \
            --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
            "${POSTGRESQL_CONTAINER}"
    )" || return 1

    [[ "${status}" == "healthy" ]]
}

###############################################################################
# Compare two Authentik data trees by checksum
#
# Arguments:
#   $1 - Directory that contains data, templates and certs
#   $2 - Directory to compare against
#
###############################################################################

restore_tree_covers()
{
    local source="$1"
    local target="$2"
    local path
    local relative
    local source_hash
    local target_hash

    local name

    for name in data templates certs
    do
        [[ -d "${source}/${name}" ]] || return 1
        [[ -d "${target}/${name}" ]] || return 1
    done

    for name in data templates certs
    do
        while IFS= read -r -d '' path
        do
            relative="${path#"${source}/"}"

            [[ -f "${target}/${relative}" ]] || return 1

            source_hash="$(sha256sum "${path}" | awk '{print $1}')" || return 1
            target_hash="$(sha256sum "${target}/${relative}" | awk '{print $1}')" || return 1

            [[ "${source_hash}" == "${target_hash}" ]] || return 1

        done < <(find "${source}/${name}" -type f -print0)
    done

    return 0
}

###############################################################################
# Both trees contain the same files
#
# Arguments:
#   $1 - First tree
#   $2 - Second tree
#
###############################################################################

restore_trees_match()
{
    local left="$1"
    local right="$2"

    restore_tree_covers "${left}" "${right}" || return 1
    restore_tree_covers "${right}" "${left}" || return 1
}

###############################################################################
# Copy one persistent directory
#
# Arguments:
#   $1 - Source directory
#   $2 - Destination directory
#
###############################################################################

restore_replace_tree()
{
    local source="$1"
    local dest="$2"

    rm -rf "${dest}" || return 1
    backup_copy_private_tree "${source}" "${dest}"
}

###############################################################################
# Replace data, templates and certs
#
# Arguments:
#   $1 - Directory that contains data, templates and certs
#   $2 - Live Authentik directory
#
###############################################################################

restore_replace_files()
{
    local source="$1"
    local root="$2"

    restore_replace_tree "${source}/data" "${root}/data" || return 1
    restore_replace_tree "${source}/templates" "${root}/templates" || return 1
    restore_replace_tree "${source}/certs" "${root}/certs" || return 1

    if [[ "$(id -u)" -eq 0 ]]; then
        chown -R "${AUTHENTIK_UID_GID}" \
            "${root}/data" \
            "${root}/templates" \
            "${root}/certs" \
            || return 1
    fi
}

###############################################################################
# Replace only AUTHENTIK_SECRET_KEY in a runtime env file
#
# Arguments:
#   $1 - Runtime .env
#   $2 - Key value
#
# Other lines stay. The previous file is copied beside it with mode 600.
# The replacement keeps the mode of the current file.
#
###############################################################################

restore_install_secret_key()
{
    local env_file="$1"
    local key="$2"
    local mode
    local tmp
    local backup

    [[ -f "${env_file}" ]] || return 1
    [[ -n "${key}" ]] || return 1

    if ! grep -q '^AUTHENTIK_SECRET_KEY=' "${env_file}"; then
        return 1
    fi

    mode="$(stat -c '%a' "${env_file}")" || return 1
    backup="${env_file}.bak-$(date +%Y%m%d-%H%M%S)"
    tmp="${env_file}.tmp"

    install -m 600 "${env_file}" "${backup}" || return 1
    backup_create_private_file "${tmp}" || return 1

    if ! AUTHENTIK_RESTORE_KEY="${key}" awk '
        BEGIN { found = 0 }
        /^AUTHENTIK_SECRET_KEY=/ {
            print "AUTHENTIK_SECRET_KEY=" ENVIRON["AUTHENTIK_RESTORE_KEY"]
            found = 1
            next
        }
        { print }
        END { if (found == 0) exit 1 }
    ' "${env_file}" > "${tmp}"; then
        rm -f "${tmp}"
        return 1
    fi

    chmod "${mode}" "${tmp}" || {
        rm -f "${tmp}"
        return 1
    }

    mv "${tmp}" "${env_file}" || {
        rm -f "${tmp}"
        return 1
    }
}

###############################################################################
# Write a rollback snapshot and check it before any live change
#
# Arguments:
#   $1 - Rollback directory
#   $2 - Live Authentik directory
#   $3 - Runtime .env
#
###############################################################################

restore_capture_rollback()
{
    local rollback="$1"
    local root="$2"
    local env_file="$3"

    backup_create_private_dir "${rollback}/authentik" || return 1
    backup_create_private_dir "${rollback}/postgresql" || return 1

    restore_replace_tree "${root}/data" "${rollback}/authentik/data" || return 1
    restore_replace_tree "${root}/templates" "${rollback}/authentik/templates" || return 1
    restore_replace_tree "${root}/certs" "${rollback}/authentik/certs" || return 1

    install -m 600 "${env_file}" "${rollback}/runtime.env" || return 1

    backup_create_private_file "${rollback}/env.mode" || return 1
    stat -c '%a' "${env_file}" > "${rollback}/env.mode" || return 1

    restore_snapshot_database "${rollback}/postgresql/authentik.dump" || return 1

    [[ -s "${rollback}/postgresql/authentik.dump" ]] || return 1
    [[ -s "${rollback}/env.mode" ]] || return 1

    restore_trees_match "${root}" "${rollback}/authentik" || return 1

    local snap_hash
    local live_hash

    snap_hash="$(sha256sum "${rollback}/runtime.env" | awk '{print $1}')" || return 1
    live_hash="$(sha256sum "${env_file}" | awk '{print $1}')" || return 1

    [[ "${snap_hash}" == "${live_hash}" ]]
}

###############################################################################
# Put the snapshot back
#
# Arguments:
#   $1 - Rollback directory
#   $2 - Live Authentik directory
#   $3 - Runtime .env
#
###############################################################################

restore_apply_rollback()
{
    local rollback="$1"
    local root="$2"
    local env_file="$3"
    local mode
    local tmp

    [[ -s "${rollback}/postgresql/authentik.dump" ]] || return 1
    [[ -f "${rollback}/runtime.env" ]] || return 1
    [[ -s "${rollback}/env.mode" ]] || return 1

    restore_replace_files "${rollback}/authentik" "${root}" || return 1

    mode="$(tr -d '[:space:]' < "${rollback}/env.mode")" || return 1
    tmp="${env_file}.tmp"

    backup_create_private_file "${tmp}" || return 1
    cp "${rollback}/runtime.env" "${tmp}" || return 1
    chmod "${mode}" "${tmp}" || {
        rm -f "${tmp}"
        return 1
    }
    mv "${tmp}" "${env_file}" || {
        rm -f "${tmp}"
        return 1
    }

    restore_load_database "${rollback}/postgresql/authentik.dump"
}

###############################################################################
# Copy the stage into the live directories and load its dump
#
# Arguments:
#   $1 - Stage directory
#   $2 - Live Authentik directory
#   $3 - Runtime .env
#
###############################################################################

restore_apply_stage()
{
    local stage="$1"
    local root="$2"
    local env_file="$3"
    local key

    restore_replace_files "${stage}/authentik" "${root}" || return 1

    key="$(restore_read_secret_key "${stage}/stack.env")" || return 1
    restore_secret_is_usable "${key}" || return 1
    restore_install_secret_key "${env_file}" "${key}" || return 1
    unset key

    restore_load_database "${stage}/postgresql/authentik.dump"
}

###############################################################################
# Files, key and database agree with the stage
#
# Arguments:
#   $1 - Stage directory
#   $2 - Live Authentik directory
#   $3 - Runtime .env
#
###############################################################################

restore_verify_applied()
{
    local stage="$1"
    local root="$2"
    local env_file="$3"
    local archive_key
    local live_key

    restore_trees_match "${stage}/authentik" "${root}" || return 1

    archive_key="$(restore_read_secret_key "${stage}/stack.env")" || return 1
    live_key="$(restore_read_secret_key "${env_file}")" || return 1

    if [[ "${archive_key}" != "${live_key}" ]]; then
        unset archive_key live_key
        return 1
    fi

    unset archive_key live_key

    restore_database_is_ready
}

###############################################################################
# Keep the rollback directory when the caller must not delete it
###############################################################################

restore_should_keep_rollback()
{
    [[ "${RESTORE_VERIFIED}" != "yes" ]]
}

###############################################################################
# Roll live data back once
#
# The snapshot is not removed. A second call does not try again.
#
###############################################################################

restore_attempt_rollback()
{
    if [[ "${RESTORE_ROLLBACK_ATTEMPTED}" == "yes" ]]; then
        return 0
    fi

    RESTORE_ROLLBACK_ATTEMPTED=yes

    if [[ -z "${RESTORE_ROLLBACK_DIR}" || -z "${RESTORE_LIVE_ROOT}" || -z "${RESTORE_ENV_FILE}" ]]; then
        RESTORE_ERROR="rollback-failed"
        return 1
    fi

    if restore_apply_rollback "${RESTORE_ROLLBACK_DIR}" "${RESTORE_LIVE_ROOT}" "${RESTORE_ENV_FILE}"; then
        RESTORE_ROLLBACK_DONE=yes
        RESTORE_ERROR="rolled-back"
        return 0
    fi

    RESTORE_ERROR="rollback-failed"
    return 1
}

###############################################################################
# EXIT handler for restore.sh
#
# Plaintext extract is removed. The rollback snapshot is removed only
# after restore_mark_verified. A catchable signal gets one rollback
# attempt when live data may already have changed.
#
###############################################################################

restore_on_exit()
{
    local status=$?

    trap - EXIT INT TERM HUP

    if [[ -n "${stage:-}" ]]; then
        backup_destroy_tree "${stage}" || status=1
    fi

    if [[ -n "${secret_tmp:-}" ]]; then
        backup_destroy_tree "${secret_tmp}" || status=1
    fi

    if [[ "${RESTORE_VERIFIED}" != "yes" && "${RESTORE_MUTATION_STARTED}" == "yes" ]]; then
        if ! restore_attempt_rollback; then
            status=1
        fi
    fi

    if [[ "${RESTORE_VERIFIED}" == "yes" && -n "${RESTORE_ROLLBACK_DIR}" ]]; then
        if ! backup_destroy_tree "${RESTORE_ROLLBACK_DIR}"; then
            status=1
        fi
    fi

    exit "${status}"
}

###############################################################################
# Mark a restore that passed file, key and database checks
###############################################################################

restore_mark_verified()
{
    RESTORE_VERIFIED=yes
}

###############################################################################
# Validate, snapshot, apply and roll back on failure
#
# Arguments:
#   $1 - Stage directory
#   $2 - Live Authentik directory
#   $3 - Runtime .env
#   $4 - Empty rollback directory
#
# Returns 0 only when files, the secret key and the database check out.
# RESTORE_ERROR is empty on success, "rolled-back" when the previous
# state was restored, and "rollback-failed" when it was not.
#
###############################################################################

restore_perform()
{
    local stage="$1"
    local root="$2"
    local env_file="$3"
    local rollback="$4"

    RESTORE_ERROR=""
    RESTORE_VERIFIED=no
    RESTORE_MUTATION_STARTED=no
    RESTORE_ROLLBACK_DONE=no
    RESTORE_ROLLBACK_ATTEMPTED=no
    RESTORE_KEEP_ROLLBACK=no

    restore_validate_stage "${stage}"

    [[ -f "${env_file}" ]] \
        || fail "Runtime .env was not found. Live data was not changed."

    if ! grep -q '^AUTHENTIK_SECRET_KEY=' "${env_file}"; then
        fail "Runtime .env has no AUTHENTIK_SECRET_KEY line. Live data was not changed."
    fi

    RESTORE_LIVE_ROOT="${root}"
    RESTORE_ENV_FILE="${env_file}"
    RESTORE_ROLLBACK_DIR="${rollback}"
    RESTORE_KEEP_ROLLBACK=yes

    if ! restore_capture_rollback "${rollback}" "${root}" "${env_file}"; then
        RESTORE_ERROR="snapshot-failed"
        fail "Could not prepare a rollback snapshot. Live data was not changed. Snapshot kept at ${rollback}."
    fi

    #
    # From here a signal must not delete the snapshot. Live data is
    # about to change. SIGKILL cannot be caught; the snapshot stays
    # because this flag is already set and the EXIT trap is not run.
    #

    RESTORE_MUTATION_STARTED=yes

    if ! restore_apply_stage "${stage}" "${root}" "${env_file}"; then
        restore_attempt_rollback
        return 1
    fi

    if ! restore_verify_applied "${stage}" "${root}" "${env_file}"; then
        restore_attempt_rollback
        return 1
    fi

    RESTORE_VERIFIED=yes
    RESTORE_ERROR=""
    return 0
}
