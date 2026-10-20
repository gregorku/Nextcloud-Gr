#!/usr/bin/env bash

###############################################################################
#
# Authentik-netcup Project
#
# File:
#   scripts/restore.sh
#
# Description:
#   Restore an Authentik backup over the persistent data of this stack.
#
# Usage:
#   ./scripts/restore.sh --archive PATH --confirm authentik-netcup
#   ./scripts/restore.sh --archive PATH --confirm authentik-netcup --replace-data
#   ./scripts/restore.sh --help
#
# Without --replace-data the archive and manifest are verified and
# nothing is written. Exit status is then 2.
#
# With --replace-data the required runtime state is:
#   - authentik-server is stopped
#   - authentik-worker is stopped
#   - authentik-postgresql is running and healthy
#
# Before any live path is removed the script checks the archive,
# the dump, the three persistent directories and AUTHENTIK_SECRET_KEY.
# It then copies the current files, .env and a pg_dump into a rollback
# directory and checks that copy. Only after that does it replace
# files, the secret key and the database.
#
# stack.env is not copied over the runtime .env. Only
# AUTHENTIK_SECRET_KEY is replaced. SMTP, trusted proxy and the backup
# destination stay as they are.
#
# A failed phase does not print success. When rollback works, the
# previous state is put back and the script exits non-zero. When
# rollback fails, the snapshot path is kept and Authentik must stay
# stopped.
#
# The manifest tag must match AUTHENTIK_TAG unless
# --allow-version-mismatch is set. Restoring a database that was
# written by a different Authentik version can fail migrations or
# leave the schema incompatible.
#
# Side effects with --replace-data:
#   - Replaces the three Authentik data directories
#   - Replaces AUTHENTIK_SECRET_KEY in the runtime .env
#   - Drops and recreates objects in the Authentik database
#
# This script does not start Compose and does not change Traefik.
#
###############################################################################

set -Eeuo pipefail

#
# Owner-only files from the first redirect, before any secret exists.
#

umask 077

###############################################################################
# Directories
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

###############################################################################
# Configuration
###############################################################################

source "${SCRIPT_DIR}/config.sh"

###############################################################################
# Libraries
###############################################################################

source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/logging.sh"
source "${SCRIPT_DIR}/lib/filesystem.sh"
source "${SCRIPT_DIR}/lib/docker.sh"
source "${SCRIPT_DIR}/lib/checks/load.sh"
source "${SCRIPT_DIR}/lib/env/load.sh"
source "${SCRIPT_DIR}/lib/backup/private.sh"
source "${SCRIPT_DIR}/lib/backup/archive.sh"
source "${SCRIPT_DIR}/lib/backup/crypto.sh"
source "${SCRIPT_DIR}/lib/backup/postgres.sh"
source "${SCRIPT_DIR}/lib/backup/restore-plan.sh"
source "${SCRIPT_DIR}/lib/backup/apply.sh"

###############################################################################
# Help
###############################################################################

show_help()
{
cat <<EOF
Authentik-netcup Project

Usage:

    ./scripts/restore.sh --archive PATH --identity PATH --confirm ${STACK_NAME}
    ./scripts/restore.sh --archive PATH --identity PATH --confirm ${STACK_NAME} --replace-data
    ./scripts/restore.sh --help

Options:

    --archive PATH
        Encrypted backup produced by backup.sh (PATH ends in .tar.gz.age).
        The sidecar PATH.sha256 has to sit next to it. The checksum is
        of the encrypted file.

    --identity PATH
        age identity used only to decrypt. age must be installed in
        this Debian 13 container. The identity file must be mode 600
        or 400 and must be available outside Git, the stack, DATA_DIR
        and the local backup directory. It is not copied into the
        archive.

    --confirm ${STACK_NAME}
        Required. Any other value is refused.

    --replace-data
        Overwrite Authentik files, AUTHENTIK_SECRET_KEY and the
        PostgreSQL database. Other .env lines are left as they are.
        Without this option the archive is only verified.

    --allow-version-mismatch
        Restore even when the manifest tag differs from AUTHENTIK_TAG.
        The database and the running image can then be incompatible.

Required state before --replace-data:

    Stop ${AUTHENTIK_SERVER_CONTAINER} and ${AUTHENTIK_WORKER_CONTAINER}.
    Leave ${POSTGRESQL_CONTAINER} running and healthy.
    Keep AUTHENTIK_TAG equal to the manifest unless the mismatch
    flag is set.

    An incomplete archive is refused before any live directory is
    removed. On failure the previous files, key and database are
    restored, or the script says the restore was not completed and
    where the snapshot was left.

EOF
}

###############################################################################
# Arguments
###############################################################################

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

print_header "Authentik-netcup restore"

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

#
# Checksum the encrypted archive before any plaintext exists.
#

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
manifest_tag="$(backup_manifest_field "${manifest}" authentik_tag)"
runtime_tag="$(env_get AUTHENTIK_TAG)"

if ! restore_versions_match "${manifest_tag}" "${runtime_tag}" "${allow_mismatch}"; then
    fail "Manifest Authentik tag is ${manifest_tag}; .env has ${runtime_tag}. Database and image must match, or pass --allow-version-mismatch."
fi

if [[ "${replace_data}" != "yes" ]]; then
    warn "Archive verified. Persistent data was not changed."
    warn "Re-run with --replace-data to overwrite Authentik files, the secret key and PostgreSQL."
    exit 2
fi

check_docker_environment

if docker_container_running "${AUTHENTIK_SERVER_CONTAINER}"; then
    fail "Stop ${AUTHENTIK_SERVER_CONTAINER} before restore."
fi

if docker_container_running "${AUTHENTIK_WORKER_CONTAINER}"; then
    fail "Stop ${AUTHENTIK_WORKER_CONTAINER} before restore."
fi

backup_require_postgresql

ensure_directory "${BACKUP_LOCAL_DIR}"
chmod 700 "${BACKUP_LOCAL_DIR}"

rollback="$(mktemp -d "${BACKUP_LOCAL_DIR}/rollback.XXXXXX")"
RESTORE_ROLLBACK_DIR="${rollback}"
RESTORE_KEEP_ROLLBACK=yes

info "Rollback snapshot will be prepared before any live data is replaced."

if ! restore_perform "${stage}" "${AUTHENTIK_DIR}" "${ENV_FILE}" "${rollback}"; then

    if [[ "${RESTORE_ERROR}" == "rolled-back" ]]; then
        fail "Restore was not completed. Files, the database and AUTHENTIK_SECRET_KEY were returned to the previous state. Snapshot kept at ${rollback}. Do not start Authentik on this result."
    fi

    if [[ "${RESTORE_ERROR}" == "rollback-failed" ]]; then
        fail "Restore was not completed and automatic rollback failed. Do not start Authentik. The snapshot of the previous files, .env and database dump is in ${rollback}. Put those files and AUTHENTIK_SECRET_KEY back before loading that dump."
    fi

    fail "Restore was not completed. Live data was not changed. Snapshot kept at ${rollback}."
fi

if ! backup_destroy_tree "${rollback}"; then
    fail "Restore was verified, but the rollback snapshot could not be removed: ${rollback}."
fi

RESTORE_ROLLBACK_DIR=""
rollback=""

info "AUTHENTIK_SECRET_KEY was restored. Other runtime .env settings were left in place."
info "Start the stack only with Authentik tag ${manifest_tag}."

print_footer "Restore completed."
