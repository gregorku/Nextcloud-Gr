#!/usr/bin/env bash

###############################################################################
#
# Nextcloud-Gr Project
#
# Prepare directories that stay outside the Git checkout and outside
# the rsync --delete set. /docker-data must already be a mountpoint.
#
###############################################################################

init_directories()
{
    log_step "Project directories"

    storage_require_mountpoint "${DOCKER_DATA_DIR}"

    ensure_directory "${DATA_DIR}"
    ensure_directory "${NEXTCLOUD_STATE_DIR}"
    ensure_directory "${BACKUP_LOCAL_DIR}"

    chmod 700 "${BACKUP_LOCAL_DIR}" "${NEXTCLOUD_STATE_DIR}"

    ok "Permissions 700: ${BACKUP_LOCAL_DIR}"
    log_success "Project directories ready."
}
