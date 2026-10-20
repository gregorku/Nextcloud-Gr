#!/usr/bin/env bash

###############################################################################
#
# Nextcloud-Gr
#
# File:
#   scripts/lib/backup/postgres.sh
#
# Description:
#   Consistent PostgreSQL dump and restore through the local socket
#   inside the PostgreSQL container.
#
#   pg_dump / pg_restore run as the postgres OS user. No host port is
#   used. The password is not placed on the command line.
#
###############################################################################

###############################################################################
# Require a healthy PostgreSQL container
###############################################################################

backup_require_postgresql()
{
    local status

    docker_container_running "${POSTGRESQL_CONTAINER}" \
        || fail "PostgreSQL container is not running: ${POSTGRESQL_CONTAINER}"

    status="$(
        docker inspect \
            --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
            "${POSTGRESQL_CONTAINER}"
    )"

    [[ "${status}" == "healthy" ]] \
        || fail "PostgreSQL health status is '${status}', expected 'healthy'."

    ok "PostgreSQL is healthy."
}

###############################################################################
# Write a custom-format dump
#
# Arguments:
#   $1 - Output file on the host
#
###############################################################################

backup_dump_postgresql()
{
    local output="$1"
    local db_user
    local db_name

    db_user="$(env_get PG_USER)"
    db_name="$(env_get PG_DB)"

    [[ -n "${db_user}" && -n "${db_name}" ]] \
        || fail "PG_USER or PG_DB is empty."

    backup_create_private_dir "$(dirname "${output}")"
    backup_create_private_file "${output}"

    if ! docker exec -u postgres "${POSTGRESQL_CONTAINER}" \
        pg_dump \
            -U "${db_user}" \
            -d "${db_name}" \
            -Fc \
            --no-owner \
            --no-acl \
        > "${output}"
    then
        fail "PostgreSQL dump failed."
    fi

    [[ -s "${output}" ]] \
        || fail "PostgreSQL dump is empty: ${output}"

    ok "PostgreSQL dump written."
}

###############################################################################
# Restore a custom-format dump
#
# Server and worker must already be stopped. PostgreSQL must be running.
# --clean --if-exists drops objects that are in the dump before creating
# them again. This overwrites the application database.
#
# Arguments:
#   $1 - Dump file on the host
#
###############################################################################

backup_restore_postgresql()
{
    local input="$1"
    local db_user
    local db_name

    [[ -s "${input}" ]] \
        || fail "PostgreSQL dump is missing: ${input}"

    db_user="$(env_get PG_USER)"
    db_name="$(env_get PG_DB)"

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
        fail "PostgreSQL restore failed."
    fi

    ok "PostgreSQL dump restored."
}
