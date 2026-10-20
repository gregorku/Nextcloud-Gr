#!/usr/bin/env bash

###############################################################################
#
# Nextcloud-Gr Project
#
# File:
#   scripts/backup.sh
#
# Description:
#   Create one consistent restore point for PostgreSQL and Nextcloud.
#
# Usage:
#   ./scripts/backup.sh
#   ./scripts/backup.sh --hold
#   ./scripts/backup.sh --help
#
# The age archive contains the PostgreSQL custom dump, config,
# custom_apps, themes, the runtime .env and a manifest. The Nextcloud
# data directory is not packed into that archive. restic stores it and
# the manifest records the snapshot id taken while cron is stopped and
# maintenance mode is on.
#
# --hold leaves maintenance mode on and cron stopped after success.
# upgrade.sh uses that. A failed run still resumes both.
#
###############################################################################

set -Eeuo pipefail

umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${SCRIPT_DIR}/config.sh"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/logging.sh"
source "${SCRIPT_DIR}/lib/filesystem.sh"
source "${SCRIPT_DIR}/lib/docker.sh"
source "${SCRIPT_DIR}/lib/mount.sh"
source "${SCRIPT_DIR}/lib/checks/load.sh"
source "${SCRIPT_DIR}/lib/env/load.sh"
source "${SCRIPT_DIR}/lib/nextcloud/occ.sh"
source "${SCRIPT_DIR}/lib/backup/private.sh"
source "${SCRIPT_DIR}/lib/backup/archive.sh"
source "${SCRIPT_DIR}/lib/backup/crypto.sh"
source "${SCRIPT_DIR}/lib/backup/postgres.sh"
source "${SCRIPT_DIR}/lib/backup/restic.sh"
source "${SCRIPT_DIR}/lib/backup/restore-plan.sh"
source "${SCRIPT_DIR}/lib/backup/runtime.sh"

show_help()
{
cat <<EOF
Nextcloud-Gr Project

Usage:

    ./scripts/backup.sh
    ./scripts/backup.sh --hold
    ./scripts/backup.sh --help

Description:

    Enable maintenance mode, stop cron, dump PostgreSQL, copy
    config, custom_apps and themes, and take a restic snapshot of
    the directory in NEXTCLOUD_DATA_HOST_DIR.

    The age archive is written to:

        ${BACKUP_LOCAL_DIR}

    It does not contain the data directory. The manifest names the
    restic snapshot taken in the same window. A local restic
    repository on the same filesystem is not protection against
    loss of that disk. backup.sh says so when that is the case.

    BACKUP_AGE_RECIPIENT is the public age recipient. Without it,
    or without age or restic, no archive is kept.

    --hold is for upgrade.sh. After success, maintenance mode stays
    on and cron stays stopped.

EOF
}

hold="no"

case "${1:-}" in
    "")
        ;;
    --hold)
        hold="yes"
        ;;
    -h|--help)
        show_help
        exit 0
        ;;
    *)
        fail "Unknown option: ${1}"
        ;;
esac

backup_on_exit()
{
    local status=$?

    trap - EXIT INT TERM HUP

    if [[ -n "${encrypt_dir}" ]]; then
        backup_destroy_tree "${encrypt_dir}" || status=1
    fi

    if [[ "${archive_ready}" != "yes" && -n "${archive}" ]]; then
        backup_destroy_file "${archive}" || status=1
        backup_destroy_file "${archive}.sha256" || status=1
    fi

    if [[ -n "${stage}" ]]; then
        backup_destroy_tree "${stage}" || status=1
    fi

    if ! backup_finish_writers; then
        warn "Maintenance mode or cron was not restored."
        if [[ "${status}" -eq 0 ]]; then
            status=1
        fi
    fi

    exit "${status}"
}

print_header "Nextcloud-Gr backup"

check_environment
check_docker_environment

[[ -f "${ENV_FILE}" ]] \
    || fail ".env not found. Run ./scripts/update-env.sh"

env_validate

require_directory "${NEXTCLOUD_HTML_DIR}/config"
require_directory "${NEXTCLOUD_HTML_DIR}/custom_apps"
require_directory "${NEXTCLOUD_HTML_DIR}/themes"
require_directory "$(env_get NEXTCLOUD_DATA_HOST_DIR)"

backup_require_postgresql
backup_require_encryption "$(env_get BACKUP_AGE_RECIPIENT)"

stage=""
encrypt_dir=""
archive=""
archive_ready="no"
BACKUP_HOLD_QUIESCE="${hold}"
BACKUP_QUIESCE_HOLD_READY="no"

trap 'backup_on_exit' EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
trap 'exit 129' HUP

backup_quiesce_writers

created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
stamp="$(date -u +%Y%m%d-%H%M%S)"
stage="$(mktemp -d)"

backup_create_private_dir "${stage}/postgresql"
backup_create_private_dir "${stage}/nextcloud"

backup_dump_postgresql "${stage}/postgresql/nextcloud.dump"

backup_dump_is_postgres_custom "${stage}/postgresql/nextcloud.dump" \
    || fail "pg_dump did not write a PostgreSQL custom-format archive."

server_version="$(
    docker exec -u postgres "${POSTGRESQL_CONTAINER}" \
        psql -d "$(env_get PG_DB)" -tAc 'SHOW server_version' \
        | tr -d '[:space:]'
)"
postgres_major="${server_version%%.*}"
[[ "${postgres_major}" == "${POSTGRES_MAJOR}" ]] \
    || fail "PostgreSQL server major is ${postgres_major}, expected ${POSTGRES_MAJOR}."

backup_copy_private_tree "${NEXTCLOUD_HTML_DIR}/config" "${stage}/nextcloud/config"
backup_copy_private_tree "${NEXTCLOUD_HTML_DIR}/custom_apps" "${stage}/nextcloud/custom_apps"
backup_copy_private_tree "${NEXTCLOUD_HTML_DIR}/themes" "${stage}/nextcloud/themes"

if nextcloud_occ app:list > "${stage}/nextcloud/app-list.txt"; then
    chmod 600 "${stage}/nextcloud/app-list.txt"
else
    printf 'occ app:list failed\n' > "${stage}/nextcloud/app-list.txt"
    chmod 600 "${stage}/nextcloud/app-list.txt"
    warn "occ app:list failed. The archive still records that failure."
fi

install -m 600 "${ENV_FILE}" "${stage}/stack.env"

snapshot_id="$(
    backup_restic_snapshot_dir \
        "$(env_get NEXTCLOUD_DATA_HOST_DIR)" \
        "backup-${stamp}"
)" || fail "restic did not produce a snapshot. No archive was kept."

nextcloud_image="$(env_get NEXTCLOUD_IMAGE)"
nextcloud_tag="$(env_get NEXTCLOUD_TAG)"
postgres_image="$(env_get POSTGRES_IMAGE)"

backup_write_manifest \
    "${stage}" \
    "${created_at}" \
    "${nextcloud_image}" \
    "${nextcloud_tag}" \
    "${postgres_image}" \
    "${postgres_major}" \
    "${snapshot_id}"

if ! backup_require_private_tree "${stage}"; then
    fail "Backup stage is not mode 700 with mode 600 files. No archive was kept."
fi

restore_validate_stage "${stage}"

ensure_directory "${BACKUP_LOCAL_DIR}"
chmod 700 "${BACKUP_LOCAL_DIR}"

encrypt_dir="$(mktemp -d)"
archive="${BACKUP_LOCAL_DIR}/nextcloud-gr-${stamp}.tar.gz.age"
store_status=0

backup_store_encrypted_stage \
    "${stage}" \
    "${archive}" \
    "$(env_get BACKUP_AGE_RECIPIENT)" \
    "${encrypt_dir}" \
    || store_status=$?

if [[ "${store_status}" -eq 1 ]]; then
    fail "Encryption failed. No archive was kept. This run is not a safe external backup."
fi

if [[ "${store_status}" -ne 0 ]]; then
    archive_ready="yes"
    warn "Encrypted archive ${archive} passed its checksum, but temporary ciphertext could not be removed: ${encrypt_dir}."
    exit 1
fi

archive_ready="yes"
encrypt_dir=""

if ! backup_restic_run forget \
    --tag nextcloud-gr \
    --keep-daily "$(env_get RESTIC_KEEP_DAILY)" \
    --keep-weekly "$(env_get RESTIC_KEEP_WEEKLY)" \
    --keep-monthly "$(env_get RESTIC_KEEP_MONTHLY)" \
    --keep-yearly "$(env_get RESTIC_KEEP_YEARLY)" \
    --keep-tag "backup-${stamp}"
then
    warn "restic forget failed. The new snapshot ${snapshot_id} was kept, but retention was not applied."
fi

external="$(env_get BACKUP_EXTERNAL_DIR)"
separate=0
backup_warn_if_repository_not_separate || separate=$?

if [[ -z "${external}" ]]; then
    warn "BACKUP_EXTERNAL_DIR is empty."
    warn "The encrypted archive stays only on this Incus container:"
    info "${archive}"
    warn "An archive on the same machine is not a backup against loss of this disk."
else
    backup_publish_encrypted "${archive}" "${external}" "${BACKUP_LOCAL_DIR}"
fi

if [[ "${hold}" == "yes" ]]; then
    BACKUP_QUIESCE_HOLD_READY="yes"
fi

if ! backup_finish_writers; then
    warn "Archive ${archive} passed its checksum, but maintenance mode or cron was not restored."
    exit 1
fi

if [[ "${separate}" -eq 2 || -z "${external}" ]]; then
    print_footer "Backup completed. It is not yet a copy on another disk."
else
    print_footer "Backup completed. Verify the remote restic repository and the age copy independently."
fi
