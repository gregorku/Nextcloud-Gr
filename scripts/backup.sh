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

    It contains the PostgreSQL dump, config, custom apps, themes and
    the restic snapshot id. It does not contain the data directory.
    An age file without that snapshot in a reachable restic repository
    is not a complete backup.

    A remote RESTIC_REPOSITORY (sftp, rest, s3, rclone, azure, gs, b2
    or swift) is the external copy of user data. A local repository
    is not. When BACKUP_EXTERNAL_DIR is a real mount on another
    device, backup.sh also copies the snapshot there with restic copy
    and then copies the age archive. Copying only the age archive is
    not reported as a complete external backup.

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

if ! backup_restic_verify_snapshot "${snapshot_id}"; then
    fail "Restic snapshot ${snapshot_id} is not readable in RESTIC_REPOSITORY. No archive was kept."
fi

repo_scope="local"
if backup_restic_repository_is_remote "$(env_get RESTIC_REPOSITORY)"; then
    repo_scope="remote"
fi

external="$(env_get BACKUP_EXTERNAL_DIR)"
external_snapshot_id=""
snapshot_on_separate="no"
data_dir="$(env_get NEXTCLOUD_DATA_HOST_DIR)"
publish_age_external="no"

if [[ "${repo_scope}" == "remote" ]]; then
    snapshot_on_separate="yes"
    if [[ -n "${external}" ]]; then
        publish_age_external="yes"
    else
        warn "RESTIC_REPOSITORY is remote, but the age archive stays in the local backup directory."
        warn "Keep that archive, the age identity and RESTIC_PASSWORD off this machine. The remote repository does not contain the database dump."
    fi
elif [[ -n "${external}" ]]; then
    destination_kind="$(backup_classify_destination "${external}" "${BACKUP_LOCAL_DIR}")"
    [[ "${destination_kind}" == "host-mount" ]] \
        || fail "BACKUP_EXTERNAL_DIR is not a mounted mountpoint. Refusing to call an age-only copy a complete backup."

    external_root="$(realpath -e "${external}")"
    if [[ "$(stat -c '%d' "${external_root}")" == "$(stat -c '%d' "${data_dir}")" ]]; then
        warn "BACKUP_EXTERNAL_DIR is on the same device as the Nextcloud data."
        warn "The age archive was not treated as a complete external backup."
    else
        external_repo="${external_root}/restic"
        mkdir -p "${external_repo}"
        chmod 700 "${external_repo}"
        external_snapshot_id="$(backup_restic_copy_and_resolve "${snapshot_id}" "${external_repo}")" \
            || fail "The external repository did not yield a verified snapshot id. The age archive was not kept."
        snapshot_on_separate="yes"
        publish_age_external="yes"
        if [[ "${external_snapshot_id}" == "${snapshot_id}" ]]; then
            ok "External snapshot id matches the source snapshot ${snapshot_id}."
        else
            ok "External snapshot id is ${external_snapshot_id}, distinct from source ${snapshot_id}."
        fi
    fi
elif [[ "${repo_scope}" == "local" ]]; then
    warn "BACKUP_EXTERNAL_DIR is empty and RESTIC_REPOSITORY is a local path."
    warn "The age archive does not contain the user files."
fi

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
    "${snapshot_id}" \
    "${repo_scope}" \
    "${external_snapshot_id}"

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

if [[ "${publish_age_external}" == "yes" ]]; then
    backup_publish_encrypted "${archive}" "${external}" "${BACKUP_LOCAL_DIR}"
    if [[ "${repo_scope}" == "remote" ]]; then
        warn "The age archive on the external mount does not contain user files."
        warn "The restic snapshot ${snapshot_id} is in the remote RESTIC_REPOSITORY."
    elif ! backup_external_pair_complete yes "${external_snapshot_id}" yes; then
        fail "The external mount does not have both the age archive and a verified restic snapshot."
    fi
fi

if [[ "${repo_scope}" == "local" ]]; then
    backup_warn_if_repository_not_separate || true
fi

if [[ "${repo_scope}" == "remote" ]]; then
    completeness="$(backup_completeness yes yes no yes)"
else
    completeness="$(backup_completeness no yes "${snapshot_on_separate}" yes)" || true
fi

if [[ "${hold}" == "yes" ]]; then
    BACKUP_QUIESCE_HOLD_READY="yes"
fi

if ! backup_finish_writers; then
    warn "Archive ${archive} passed its checksum, but maintenance mode or cron was not restored."
    exit 1
fi

if [[ "${repo_scope}" == "local" && "${snapshot_on_separate}" == "yes" ]]; then
    if ! backup_external_pair_complete yes "${external_snapshot_id}" yes; then
        fail "Backup is not complete. The encrypted archive and the external snapshot were not both verified."
    fi
fi

case "${completeness}" in
    external)
        print_footer "Complete external backup: age archive ${archive} and restic snapshot ${external_snapshot_id:-${snapshot_id}}."
        ;;
    local-only)
        warn "This is a local restore point only. The age archive does not contain user files, and the restic snapshot is not on separate storage."
        print_footer "Backup completed. It is not a complete external backup."
        ;;
    *)
        fail "Backup is incomplete. The age archive was not accepted without a readable restic snapshot."
        ;;
esac
