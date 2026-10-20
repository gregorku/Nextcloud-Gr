#!/usr/bin/env bash

###############################################################################
#
# Authentik-netcup Project
#
# File:
#   scripts/backup.sh
#
# Description:
#   Create a consistent backup of Authentik and PostgreSQL.
#
# Usage:
#   ./scripts/backup.sh
#   ./scripts/backup.sh --help
#
# The encrypted archive contains:
#   - a custom-format pg_dump of the Authentik database
#   - Authentik file storage, custom templates and worker certs
#   - a copy of the runtime .env
#   - manifest.txt with the time, image pins and sha256 checksums
#
# The kept file is name.tar.gz.age. age encrypts it to
# BACKUP_AGE_RECIPIENT. The age command has to be installed in this
# Debian 13 container. The private identity is not in this script,
# in Git, in the stack, in DATA_DIR, or in the backup directory.
# The sidecar checksum is of the .age file.
#
# tar writes the stage to stdout and age encrypts that stream. No
# plaintext tar file is written. The stage, dump, stack.env and
# manifest are checked before that pipeline. The final .age file is
# installed only after the pipeline and its checksum succeed.
# shred of the stage is best effort: an SSD, a copy-on-write
# filesystem, a snapshot, a crash or SIGKILL can leave plaintext.
#
# The PostgreSQL data directory itself is not copied. A file copy of
# that directory would not be a consistent database backup.
#
# The archive is written to:
#   /docker-data/backups/authentik-netcup
#
# BACKUP_EXTERNAL_DIR is /backups, the Incus mount of the host VPS
# backup directory. The copy is made only when that path is itself a
# mountpoint and mode 700. The same device number as /docker-data is
# expected and does not make the copy another disk. An ordinary
# directory at that path is refused and nothing is written there.
# An empty value leaves only the local encrypted archive. Without age
# or a public recipient, no archive is kept. A later program transfers
# the encrypted files off the VPS. This script does not.
#
# Side effects:
#   - Stops authentik-server and authentik-worker when they are running,
#     then starts only those this script stopped
#   - HTTP on 10.10.10.100:9000 is down for the dump and the file copy
#   - Reads the running PostgreSQL container
#   - Writes a new archive under BACKUP_LOCAL_DIR
#   - Does not modify DATA_DIR
#
# Next step:
#   Keep the archive with the same AUTHENTIK_TAG. See
#   docs/backup-restore.md before restore.sh.
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
source "${SCRIPT_DIR}/lib/backup/runtime.sh"

###############################################################################
# Help
###############################################################################

show_help()
{
cat <<EOF
Authentik-netcup Project

Usage:

    ./scripts/backup.sh
    ./scripts/backup.sh --help

Description:

    Dump PostgreSQL, copy Authentik persistent files and write a
    checksummed archive to:

        ${BACKUP_LOCAL_DIR}

    rsync --delete never sees this directory. It is not a DEPLOY_ITEMS
    path and it is not inside the runtime stack.

    BACKUP_AGE_RECIPIENT is the public age recipient. The age command
    must be installed in this Debian 13 container. Without the
    recipient, or without age, no archive is written.

    The private identity is not read here. Keep it outside Git, the
    stack, DATA_DIR and the local backup directory, and present it
    only to restore.sh --identity.

    BACKUP_EXTERNAL_DIR is /backups. The encrypted archive is copied
    there only when realpath and the kernel mount table show that the
    path itself is a mountpoint, mode 700. A plain directory is not
    used. The copy is a verified file on the mounted host VPS
    directory. It is not a backup on another disk and it is not a
    completed transfer to another server.

    An empty BACKUP_EXTERNAL_DIR leaves the encrypted archive only
    on this container.

    Run this inside the Incus container, as root, while PostgreSQL
    is healthy. Server and worker are stopped first so the dump and
    the file copy describe the same moment. They are started again
    only if this script stopped them. HTTP is unavailable during
    that window.

EOF
}

###############################################################################
# Main
###############################################################################

case "${1:-}" in

    "")
        ;;

    -h|--help)
        show_help
        exit 0
        ;;

    *)
        fail "Unknown option: ${1}"
        ;;

esac

###############################################################################
# Remove the stage and start containers this backup stopped
###############################################################################

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
        warn "Authentik was not started again."

        if [[ "${status}" -eq 0 ]]; then
            status=1
        fi
    fi

    exit "${status}"
}

print_header "Authentik-netcup backup"

check_environment
check_docker_environment

[[ -f "${ENV_FILE}" ]] \
    || fail ".env not found. Run ./scripts/update-env.sh"

env_validate

require_directory "${AUTHENTIK_DATA_DIR}"
require_directory "${AUTHENTIK_TEMPLATES_DIR}"
require_directory "${AUTHENTIK_CERTS_DIR}"

backup_require_postgresql

backup_require_encryption "$(env_get BACKUP_AGE_RECIPIENT)"

stage=""
encrypt_dir=""
archive=""
archive_ready="no"
trap 'backup_on_exit' EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
trap 'exit 129' HUP

backup_quiesce_writers

created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
stamp="$(date -u +%Y%m%d-%H%M%S)"
stage="$(mktemp -d)"

backup_create_private_dir "${stage}/postgresql"
backup_create_private_dir "${stage}/authentik"

backup_dump_postgresql "${stage}/postgresql/authentik.dump"

backup_copy_private_tree "${AUTHENTIK_DATA_DIR}" "${stage}/authentik/data"
backup_copy_private_tree "${AUTHENTIK_TEMPLATES_DIR}" "${stage}/authentik/templates"
backup_copy_private_tree "${AUTHENTIK_CERTS_DIR}" "${stage}/authentik/certs"

install -m 600 "${ENV_FILE}" "${stage}/stack.env"

authentik_image="$(env_get AUTHENTIK_IMAGE)"
authentik_tag="$(env_get AUTHENTIK_TAG)"
postgres_image="$(env_get POSTGRES_IMAGE)"

backup_write_manifest \
    "${stage}" \
    "${created_at}" \
    "${authentik_image}" \
    "${authentik_tag}" \
    "${postgres_image}"

if ! backup_require_private_tree "${stage}"; then
    fail "Backup stage is not mode 700 with mode 600 files. No archive was kept."
fi

restore_validate_stage "${stage}"

ensure_directory "${BACKUP_LOCAL_DIR}"
chmod 700 "${BACKUP_LOCAL_DIR}"

encrypt_dir="$(mktemp -d)"
archive="${BACKUP_LOCAL_DIR}/authentik-netcup-${stamp}.tar.gz.age"
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

external="$(env_get BACKUP_EXTERNAL_DIR)"

if [[ -z "${external}" ]]; then

    warn "BACKUP_EXTERNAL_DIR is empty."
    warn "The encrypted archive stays only on this Incus container:"
    info "${archive}"
    warn "This is not a backup outside the container."

else

    backup_publish_encrypted "${archive}" "${external}" "${BACKUP_LOCAL_DIR}"

fi

if ! backup_finish_writers; then
    warn "Encrypted archive ${archive} passed its checksum check, but Authentik was not started."
    exit 1
fi

if [[ -z "${external}" ]]; then
    print_footer "Encrypted local archive completed. It is not a backup outside this container."
else
    print_footer "Verified encrypted copy on the mounted host directory. It is not on another disk and it has not been transferred to another server."
fi