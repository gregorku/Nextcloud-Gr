#!/usr/bin/env bash

###############################################################################
#
# Nextcloud-Gr
#
# File:
#   scripts/lib/docker.sh
#
# Description:
#   Docker Engine helper functions.
#
###############################################################################

###############################################################################
# Docker daemon
#
# Usage:
#   require_docker_daemon
#
###############################################################################

require_docker_daemon() {

    require_docker

    docker info >/dev/null 2>&1 \
        || fail "Docker daemon is not running."
}

###############################################################################
# Container exists
#
# Usage:
#   docker_container_exists traefik
#
###############################################################################

docker_container_exists() {

    local container="$1"

    docker container inspect "${container}" >/dev/null 2>&1
}

###############################################################################
# Container running
#
# Usage:
#   docker_container_running traefik
#
###############################################################################

docker_container_running() {

    local container="$1"

    docker ps \
        --format '{{.Names}}' \
        | grep -Fxq "${container}"
}

###############################################################################
# Execute command
#
# Usage:
#   docker_exec traefik ls /
#
###############################################################################

docker_exec() {

    local container="$1"

    shift

    docker exec "${container}" "$@"
}

###############################################################################
# Logs
#
# Usage:
#   docker_logs traefik
#
###############################################################################

docker_logs() {

    docker logs "$@"
}

###############################################################################
# Restart container
#
# Usage:
#   docker_restart traefik
#
###############################################################################

docker_restart() {

    docker restart "$1" >/dev/null

    ok "Restarted $1."
}

###############################################################################
# Stop container
#
# Usage:
#   docker_stop traefik
#
###############################################################################

docker_stop() {

    docker stop "$1" >/dev/null

    ok "Stopped $1."
}

###############################################################################
# Start container
#
# Usage:
#   docker_start traefik
#
###############################################################################

docker_start() {

    docker start "$1" >/dev/null

    ok "Started $1."
}

###############################################################################
# Network exists
#
# Usage:
#   docker_network_exists monitoring-netcup
#
###############################################################################

docker_network_exists() {

    docker network inspect "$1" >/dev/null 2>&1
}

###############################################################################
# Volume exists
#
# Usage:
#   docker_volume_exists volume-name
#
###############################################################################

docker_volume_exists() {

    docker volume inspect "$1" >/dev/null 2>&1
}

###############################################################################
# Run a PostgreSQL client inside the database container.
#
# New clusters run initdb --username nc_bootstrap. The image does not
# create a database role named postgres. The OS account in the
# container is still named postgres, so a client that omits -U asks
# for a role that does not exist. Clients connect over 127.0.0.1 as
# the requested role. TCP to 127.0.0.1 uses the password from PG_PASS
# through a mode 600 env file. The password is not an argument of
# docker or psql. A failed connection returns the client status. It is
# not an empty query result.
#
# Arguments:
#   $1 - Database role.
#   $2 - Database to open. "postgres" here is the maintenance database
#        created by initdb, not a login role.
#   Remaining arguments are the client and its options. -h, -U and -d
#   are appended.
#
###############################################################################

postgres_container_exec()
{
    local role="$1"
    local database="$2"
    shift 2
    local db_pass
    local passfile
    local status=0

    [[ "$#" -gt 0 ]] || return 1

    db_pass="$(env_get PG_PASS)" || return 1

    [[ "${role}" =~ ^[A-Za-z_][A-Za-z0-9_]{0,62}$ ]] || return 1
    [[ "${database}" =~ ^[A-Za-z_][A-Za-z0-9_]{0,62}$ ]] || return 1
    [[ -n "${db_pass}" && "${db_pass}" != *$'\n'* ]] || return 1

    passfile="$(mktemp)" || return 1
    chmod 600 "${passfile}" || {
        rm -f "${passfile}"
        return 1
    }

    if ! printf 'PGPASSWORD=%s\n' "${db_pass}" > "${passfile}"; then
        rm -f "${passfile}"
        return 1
    fi

    docker exec \
        --env-file "${passfile}" \
        -u postgres \
        -i \
        "${POSTGRESQL_CONTAINER}" \
        "$@" \
        -h 127.0.0.1 \
        -U "${role}" \
        -d "${database}" \
        || status=$?

    rm -f "${passfile}"
    return "${status}"
}

postgres_container_client()
{
    local database="$1"
    shift
    local db_user

    db_user="$(env_get PG_USER)" || return 1
    postgres_container_exec "${db_user}" "${database}" "$@"
}

postgres_container_admin()
{
    local database="$1"
    shift

    postgres_container_exec "${POSTGRES_BOOTSTRAP_USER}" "${database}" "$@"
}
