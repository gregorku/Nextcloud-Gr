#!/usr/bin/env bash

###############################################################################
#
# Nextcloud-Gr Project
#
# File:
#   scripts/lib/backup/runtime.sh
#
# Description:
#   Stop cron before maintenance mode, then keep PostgreSQL running
#   so pg_dump can read it. Only cron that this script stopped is
#   started again.
#
###############################################################################

BACKUP_STOPPED_CRON=no
BACKUP_MAINTENANCE_ON=no
BACKUP_RESUMED=no

backup_stop_container()
{
    local name="$1"

    if ! docker stop "${name}" >/dev/null; then
        return 1
    fi
}

backup_start_container()
{
    local name="$1"

    if ! docker start "${name}" >/dev/null; then
        return 1
    fi
}

backup_enter_maintenance()
{
    nextcloud_maintenance on
}

backup_leave_maintenance()
{
    nextcloud_maintenance off
}

backup_quiesce_writers()
{
    BACKUP_STOPPED_CRON=no
    BACKUP_MAINTENANCE_ON=no
    BACKUP_RESUMED=no

    if docker_container_running "${NEXTCLOUD_CRON_CONTAINER}"; then
        info "Stopping ${NEXTCLOUD_CRON_CONTAINER} before maintenance mode."

        backup_stop_container "${NEXTCLOUD_CRON_CONTAINER}" \
            || fail "Could not stop ${NEXTCLOUD_CRON_CONTAINER}. Backup was not started."

        BACKUP_STOPPED_CRON=yes
        ok "Stopped ${NEXTCLOUD_CRON_CONTAINER}."
    else
        info "${NEXTCLOUD_CRON_CONTAINER} is already stopped. This backup will not start it."
    fi

    backup_enter_maintenance \
        || fail "Could not enable maintenance mode. Backup was not started."

    BACKUP_MAINTENANCE_ON=yes
    ok "Nextcloud maintenance mode is on."
}

backup_resume_writers()
{
    local status=0

    if [[ "${BACKUP_STOPPED_CRON}" == "yes" ]]; then
        if ! backup_start_container "${NEXTCLOUD_CRON_CONTAINER}"; then
            warn "Could not start ${NEXTCLOUD_CRON_CONTAINER}."
            status=1
        else
            ok "Started ${NEXTCLOUD_CRON_CONTAINER}."
        fi
    fi

    if [[ "${BACKUP_MAINTENANCE_ON}" == "yes" ]]; then
        if ! backup_leave_maintenance; then
            warn "Could not leave maintenance mode."
            status=1
        else
            BACKUP_MAINTENANCE_ON=no
            ok "Maintenance mode is off."
        fi
    fi

    return "${status}"
}

backup_finish_writers()
{
    local status=0

    if [[ "${BACKUP_RESUMED}" == "yes" ]]; then
        return 0
    fi

    if [[ "${BACKUP_HOLD_QUIESCE:-no}" == "yes" && "${BACKUP_QUIESCE_HOLD_READY:-no}" == "yes" ]]; then
        BACKUP_RESUMED=yes
        info "Maintenance mode stays on and cron stays stopped for upgrade.sh."
        return 0
    fi

    BACKUP_RESUMED=yes

    if ! backup_resume_writers; then
        status=1
    fi

    return "${status}"
}
