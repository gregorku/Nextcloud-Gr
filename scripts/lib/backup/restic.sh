#!/usr/bin/env bash

###############################################################################
#
# Nextcloud-Gr Project
#
# File:
#   scripts/lib/backup/restic.sh
#
# Description:
#   Incremental encrypted backup of the Nextcloud data directory.
#   The repository password is passed through a mode 600 file, not as
#   a process argument, and that file is removed afterwards.
#
###############################################################################

backup_restic_snapshot_id_is_valid()
{
    [[ "$1" =~ ^[0-9a-f]{8,64}$ ]]
}

backup_restic_repository_is_remote()
{
    [[ "$1" =~ ^(sftp|rest|s3|rclone|azure|gs|b2|swift): ]]
}

###############################################################################
# Run restic with the password file.
#
# The password is not printed. A failing restic still removes the file.
#
###############################################################################

backup_restic_run()
{
    local repo
    local password
    local passfile
    local status

    command -v restic >/dev/null 2>&1 \
        || fail "restic is not installed. No user-data backup was kept."

    repo="$(env_get RESTIC_REPOSITORY)"
    password="$(env_get RESTIC_PASSWORD)"

    [[ -n "${repo}" && -n "${password}" ]] || return 1

    passfile="$(mktemp)"
    chmod 600 "${passfile}"
    printf '%s\n' "${password}" > "${passfile}"

    set +e
    RESTIC_PASSWORD_FILE="${passfile}" \
        restic -r "${repo}" "$@"
    status=$?
    set -e

    shred -u "${passfile}" 2>/dev/null || rm -f "${passfile}"
    return "${status}"
}

backup_restic_ensure_repo()
{
    local repo

    repo="$(env_get RESTIC_REPOSITORY)"

    if backup_restic_repository_is_remote "${repo}"; then
        :
    else
        storage_require_ready_directory "${repo}" "Restic repository"
    fi

    if backup_restic_run snapshots >/dev/null 2>&1; then
        return 0
    fi

    backup_restic_run init
}

###############################################################################
# Backup one directory and print the new snapshot id.
#
# Arguments:
#   $1 - Directory
#   $2 - Tag
#
###############################################################################

backup_restic_snapshot_dir()
{
    local directory="$1"
    local tag="$2"
    local output
    local snapshot

    [[ -d "${directory}" ]] || return 1

    backup_restic_ensure_repo || return 1

    output="$(
        backup_restic_run backup "${directory}" \
            --host nextcloud-gr \
            --tag nextcloud-gr \
            --tag "${tag}" \
            --json
    )" || return 1

    snapshot="$(
        printf '%s\n' "${output}" \
            | grep -o '"snapshot_id":"[0-9a-f]*"' \
            | tail -n 1 \
            | sed 's/"snapshot_id":"//; s/"//'
    )"

    backup_restic_snapshot_id_is_valid "${snapshot}" || return 1
    printf '%s\n' "${snapshot}"
}

backup_restic_snapshot_exists()
{
    local snapshot="$1"

    backup_restic_snapshot_id_is_valid "${snapshot}" || return 1
    backup_restic_run cat config >/dev/null
    backup_restic_run snapshots --json "${snapshot}" \
        | grep -q "\"short_id\":\"${snapshot:0:8}\""
}

###############################################################################
# Restore a snapshot onto the data directory.
#
# A subdirectory of a mount is restored beside the live directory and
# then renamed. A path that is itself a mountpoint is restored in place
# because a mountpoint cannot be renamed.
#
# Arguments:
#   $1 - Snapshot id
#   $2 - Live data directory
#
###############################################################################

backup_restic_restore_dir()
{
    local snapshot="$1"
    local directory="$2"
    local mount
    local parent
    local incoming
    local restored

    backup_restic_snapshot_id_is_valid "${snapshot}" || return 1
    [[ -d "${directory}" ]] || return 1

    mount="$(storage_mount_target "${directory}")" || return 1

    if [[ "${mount}" == "${directory}" ]]; then
        warn "Data directory is the mountpoint. Restic restore is in place and cannot swap the directory."
        backup_restic_run restore "${snapshot}" --target /
        return
    fi

    parent="$(dirname "${directory}")"
    incoming="$(mktemp -d "${parent}/.restore.XXXXXX")"

    if ! backup_restic_run restore "${snapshot}" --target "${incoming}"; then
        rm -rf "${incoming}"
        return 1
    fi

    restored="${incoming}${directory}"

    if [[ ! -d "${restored}" ]]; then
        rm -rf "${incoming}"
        return 1
    fi

    local previous="${directory}.previous"

    if [[ -e "${previous}" ]]; then
        rm -rf "${incoming}"
        return 1
    fi

    if ! mv "${directory}" "${previous}"; then
        rm -rf "${incoming}"
        return 1
    fi

    if ! mv "${restored}" "${directory}"; then
        mv "${previous}" "${directory}" || true
        rm -rf "${incoming}"
        return 1
    fi

    rm -rf "${incoming}"
    printf '%s\n' "${previous}"
}

backup_warn_if_repository_not_separate()
{
    local repo
    local data_dir
    local repo_device
    local data_device

    repo="$(env_get RESTIC_REPOSITORY)"
    data_dir="$(env_get NEXTCLOUD_DATA_HOST_DIR)"

    if backup_restic_repository_is_remote "${repo}"; then
        ok "Restic repository is remote."
        return 0
    fi

    [[ -d "${repo}" && -d "${data_dir}" ]] || return 0

    repo_device="$(stat -c '%d' "${repo}")"
    data_device="$(stat -c '%d' "${data_dir}")"

    if [[ "${repo_device}" == "${data_device}" ]]; then
        warn "Restic repository and Nextcloud data are on the same filesystem."
        warn "This backup does not protect against loss of that disk."
        return 2
    fi

    ok "Restic repository is on a different filesystem from the data directory."
}
