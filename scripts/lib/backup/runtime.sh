#!/usr/bin/env bash

###############################################################################
#
# Authentik-netcup Project
#
# File:
#   scripts/lib/backup/runtime.sh
#
# Description:
#   Stop Authentik server and worker for the duration of a backup, then
#   start only the containers this backup stopped.
#
#   PostgreSQL stays running. pg_dump and the file copy then see one
#   quiet moment. HTTP on AUTHENTIK_HOST_IP:AUTHENTIK_HTTP_PORT is down
#   while those steps run.
#
###############################################################################

BACKUP_STOPPED_SERVER=no
BACKUP_STOPPED_WORKER=no
BACKUP_RESUMED=no

###############################################################################
# Stop one container and return its status
#
# Arguments:
#   $1 - Container name
#
# The status is checked explicitly. Callers use this from a backup trap,
# where set -e does not stop the script on a failed command.
#
###############################################################################

backup_stop_container()
{
    local name="$1"

    if ! docker stop "${name}" >/dev/null; then
        return 1
    fi
}

###############################################################################
# Start one container and return its status
#
# Arguments:
#   $1 - Container name
#
###############################################################################

backup_start_container()
{
    local name="$1"

    if ! docker start "${name}" >/dev/null; then
        return 1
    fi
}

###############################################################################
# Stop server and worker when they are running
###############################################################################

backup_quiesce_writers()
{
    BACKUP_STOPPED_SERVER=no
    BACKUP_STOPPED_WORKER=no
    BACKUP_RESUMED=no

    if docker_container_running "${AUTHENTIK_SERVER_CONTAINER}"; then

        info "Stopping ${AUTHENTIK_SERVER_CONTAINER}. Authentik HTTP on ${AUTHENTIK_HOST_IP}:${AUTHENTIK_HTTP_PORT} is unavailable until this backup finishes."

        backup_stop_container "${AUTHENTIK_SERVER_CONTAINER}" \
            || fail "Could not stop ${AUTHENTIK_SERVER_CONTAINER}. Backup was not started."

        BACKUP_STOPPED_SERVER=yes

        ok "Stopped ${AUTHENTIK_SERVER_CONTAINER}."
    else
        info "${AUTHENTIK_SERVER_CONTAINER} is already stopped. This backup will not start it."
    fi

    if docker_container_running "${AUTHENTIK_WORKER_CONTAINER}"; then

        info "Stopping ${AUTHENTIK_WORKER_CONTAINER} so persistent files are copied while Authentik is not writing them."

        backup_stop_container "${AUTHENTIK_WORKER_CONTAINER}" \
            || fail "Could not stop ${AUTHENTIK_WORKER_CONTAINER}. Backup was not started."

        BACKUP_STOPPED_WORKER=yes

        ok "Stopped ${AUTHENTIK_WORKER_CONTAINER}."
    else
        info "${AUTHENTIK_WORKER_CONTAINER} is already stopped. This backup will not start it."
    fi
}

###############################################################################
# Start containers this backup stopped
###############################################################################

backup_resume_writers()
{
    local status=0

    if [[ "${BACKUP_STOPPED_SERVER}" == "yes" ]]; then

        if ! backup_start_container "${AUTHENTIK_SERVER_CONTAINER}"; then
            warn "Could not start ${AUTHENTIK_SERVER_CONTAINER}."
            status=1
        else
            ok "Started ${AUTHENTIK_SERVER_CONTAINER}."
        fi
    fi

    if [[ "${BACKUP_STOPPED_WORKER}" == "yes" ]]; then

        if ! backup_start_container "${AUTHENTIK_WORKER_CONTAINER}"; then
            warn "Could not start ${AUTHENTIK_WORKER_CONTAINER}."
            status=1
        else
            ok "Started ${AUTHENTIK_WORKER_CONTAINER}."
        fi
    fi

    return "${status}"
}

###############################################################################
# Resume once, including from the EXIT trap
###############################################################################

backup_finish_writers()
{
    local status=0

    if [[ "${BACKUP_RESUMED}" == "yes" ]]; then
        return 0
    fi

    BACKUP_RESUMED=yes

    if ! backup_resume_writers; then
        status=1
    fi

    return "${status}"
}
