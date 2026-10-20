#!/usr/bin/env bash

###############################################################################
#
# Nextcloud-Gr Project
#
# File:
#   scripts/restore.sh
#
# Description:
#   Restore a verified Nextcloud backup over this stack.
#
# Usage:
#   ./scripts/restore.sh --archive PATH --identity PATH --confirm nextcloud-gr
#   ./scripts/restore.sh --archive PATH --identity PATH --confirm nextcloud-gr --replace-data
#
# Without --replace-data the archive is verified and nothing is written.
# Exit status is then 2.
#
# Live files and the database are not replaced until the archive, the
# PostgreSQL dump, the manifest and the restic snapshot id have been
# checked and a rollback snapshot has been written.
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
source "${SCRIPT_DIR}/lib/backup/private.sh"
source "${SCRIPT_DIR}/lib/backup/archive.sh"
source "${SCRIPT_DIR}/lib/backup/crypto.sh"
source "${SCRIPT_DIR}/lib/backup/postgres.sh"
source "${SCRIPT_DIR}/lib/backup/restic.sh"
source "${SCRIPT_DIR}/lib/backup/restore-plan.sh"
source "${SCRIPT_DIR}/lib/backup/apply.sh"

show_help()
{
cat <<EOF
Nextcloud-Gr Project

Usage:

    ./scripts/restore.sh --archive PATH --identity PATH --confirm ${STACK_NAME}
    ./scripts/restore.sh --archive PATH --identity PATH --confirm ${STACK_NAME} --replace-data
    ./scripts/restore.sh --help

Options:

    --archive PATH
        Encrypted backup produced by backup.sh.

    --identity PATH
        age identity. Mode 600 or 400. It is not copied into the archive.

    --confirm ${STACK_NAME}
        Required.

    --replace-data
        Replace config, custom_apps, themes, NEXTCLOUD_ADMIN_PASSWORD,
        the PostgreSQL database and the restic data snapshot.
        PG_PASS, REDIS_PASSWORD and RESTIC_PASSWORD stay as they are.

    --allow-version-mismatch
        Allow a different Nextcloud tag. A different PostgreSQL major
        is still refused. A MariaDB dump is refused.

Required state before --replace-data:

    Stop ${NEXTCLOUD_APP_CONTAINER} and ${NEXTCLOUD_CRON_CONTAINER}.
    Leave ${POSTGRESQL_CONTAINER} running and healthy.
    Do not start the stack until the restore message says it finished.

EOF
}

archive=""
identity=""
confirm=""
replace_data="no"
allow_mismatch="no"

while [[ $# -gt 0 ]]
do
    case "$1" in
        --archive)
            [[ $# -ge 2 ]] || fail "--archive requires a path."
            archive="$2"
            shift 2
            ;;
        --identity)
            [[ $# -ge 2 ]] || fail "--identity requires a path."
            identity="$2"
            shift 2
            ;;
        --confirm)
            [[ $# -ge 2 ]] || fail "--confirm requires the stack name."
            confirm="$2"
            shift 2
            ;;
        --replace-data)
            replace_data="yes"
            shift
            ;;
        --allow-version-mismatch)
            allow_mismatch="yes"
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            fail "Unknown option: $1"
            ;;
    esac
done

[[ -n "${archive}" ]] \
    || fail "--archive is required."

restore_confirmation_matches "${confirm}" \
    || fail "Refusing restore. --confirm must be exactly '${STACK_NAME}'."

print_header "Nextcloud-Gr restore"

check_environment

[[ -f "${ENV_FILE}" ]] \
    || fail ".env not found. The restore target is not initialized."

backup_require_identity "${identity}"

stage=""
secret_tmp=""
rollback=""
trap 'restore_on_exit' EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
trap 'exit 129' HUP

backup_require_sidecar "${archive}" "archive"

secret_tmp="$(mktemp -d)"
plain="${secret_tmp}/plain.tar.gz"

if ! backup_decrypt_file "${archive}" "${plain}" "${identity}"; then
    fail "Could not decrypt the archive. Persistent data was not changed."
fi

if ! backup_require_private_tree "${secret_tmp}"; then
    fail "Decrypted archive is not mode 600 in a mode 700 directory. Persistent data was not changed."
fi

stage="$(mktemp -d)"
tar -C "${stage}" -xzf "${plain}"
backup_destroy_file "${plain}" || fail "Could not remove the decrypted archive. Persistent data was not changed."

if ! backup_require_private_tree "${stage}"; then
    fail "Decrypted stage is not mode 700 with mode 600 files. Persistent data was not changed."
fi

restore_validate_stage "${stage}"

manifest="${stage}/manifest.txt"
manifest_tag="$(backup_manifest_field "${manifest}" nextcloud_tag)"
runtime_tag="$(env_get NEXTCLOUD_TAG)"
manifest_major="$(backup_manifest_field "${manifest}" postgres_major)"

if ! restore_versions_match "${manifest_tag}" "${runtime_tag}" "${allow_mismatch}"; then
    fail "Manifest Nextcloud tag is ${manifest_tag}; .env has ${runtime_tag}. Pass --allow-version-mismatch only when that difference is intentional."
fi

if ! restore_postgres_major_ok "${manifest_major}" "${POSTGRES_MAJOR}" "no"; then
    fail "Manifest PostgreSQL major is ${manifest_major}; this stack expects ${POSTGRES_MAJOR}. Refusing to load the dump."
fi

snapshot="$(backup_manifest_field "${manifest}" restic_snapshot_id)"
if ! backup_restic_snapshot_exists "${snapshot}"; then
    fail "Restic snapshot ${snapshot} is not present. Persistent data was not changed."
fi

if [[ "${replace_data}" != "yes" ]]; then
    warn "Archive verified. Persistent data was not changed."
    warn "Re-run with --replace-data to overwrite Nextcloud files, the database and the data directory."
    exit 2
fi

check_docker_environment

if docker_container_running "${NEXTCLOUD_APP_CONTAINER}"; then
    fail "Stop ${NEXTCLOUD_APP_CONTAINER} before restore."
fi

if docker_container_running "${NEXTCLOUD_CRON_CONTAINER}"; then
    fail "Stop ${NEXTCLOUD_CRON_CONTAINER} before restore."
fi

backup_require_postgresql

ensure_directory "${BACKUP_LOCAL_DIR}"
chmod 700 "${BACKUP_LOCAL_DIR}"

rollback="$(mktemp -d "${BACKUP_LOCAL_DIR}/rollback.XXXXXX")"
RESTORE_ROLLBACK_DIR="${rollback}"
RESTORE_KEEP_ROLLBACK=yes

info "Rollback snapshot will be prepared before any live data is replaced."

if ! restore_perform "${stage}" "${NEXTCLOUD_HTML_DIR}" "${ENV_FILE}" "${rollback}"; then

    if [[ "${RESTORE_ERROR}" == "rolled-back" ]]; then
        fail "Restore was not completed. Files, the database and NEXTCLOUD_ADMIN_PASSWORD were returned to the previous state. Snapshot kept at ${rollback}. Do not start Nextcloud on this result."
    fi

    if [[ "${RESTORE_ERROR}" == "rollback-failed" ]]; then
        fail "Restore was not completed and automatic rollback failed. Do not start Nextcloud. The previous files, .env and database dump are in ${rollback}."
    fi

    fail "Restore was not completed. Live data was not changed. Snapshot kept at ${rollback}."
fi

if ! backup_destroy_tree "${rollback}"; then
    fail "Restore was verified, but the rollback snapshot could not be removed: ${rollback}."
fi

RESTORE_ROLLBACK_DIR=""
rollback=""

info "NEXTCLOUD_ADMIN_PASSWORD was restored. PG_PASS, REDIS_PASSWORD and RESTIC_PASSWORD were left in place."
info "Start the stack only with Nextcloud tag ${manifest_tag}."
info "Run occ files:scan for the restored data directory before trusting clients."

print_footer "Restore completed."
