#!/usr/bin/env bash

###############################################################################
#
# Authentik-netcup Project
#
# File:
#   scripts/lib/backup/archive.sh
#
# Description:
#   Build and verify a backup directory.
#
#   The manifest lists sha256 checksums of every file except itself.
#   backup.sh also writes a sidecar checksum of the tar archive.
#   These functions do not talk to Docker and do not read DATA_DIR,
#   so the static tests can run them on a temporary directory.
#
###############################################################################

###############################################################################
# Write manifest.txt into a prepared stage directory
#
# Arguments:
#   $1 - Stage directory
#   $2 - UTC timestamp
#   $3 - Nextcloud image
#   $4 - Nextcloud tag
#   $5 - PostgreSQL image
#   $6 - PostgreSQL major
#   $7 - Restic snapshot id
#
###############################################################################

backup_write_manifest()
{
    local stage="$1"
    local created_at="$2"
    local nextcloud_image="$3"
    local nextcloud_tag="$4"
    local postgres_image="$5"
    local postgres_major="${6:-${POSTGRES_MAJOR}}"
    local restic_snapshot_id="${7:-}"
    local manifest="${stage}/manifest.txt"
    local path
    local hash
    local relative

    [[ -d "${stage}" ]] \
        || fail "Backup stage is not a directory: ${stage}"

    backup_create_private_file "${manifest}"

    {
        printf 'project=%s\n' "${PROJECT_NAME}"
        printf 'created_at=%s\n' "${created_at}"
        printf 'nextcloud_image=%s\n' "${nextcloud_image}"
        printf 'nextcloud_tag=%s\n' "${nextcloud_tag}"
        printf 'postgres_image=%s\n' "${postgres_image}"
        printf 'postgres_major=%s\n' "${postgres_major}"
        printf 'database_format=custom\n'
        printf 'database_engine=postgresql\n'
        printf 'database_file=postgresql/nextcloud.dump\n'
        printf 'restic_snapshot_id=%s\n' "${restic_snapshot_id}"
        printf 'data_backup=restic\n'
    } > "${manifest}"

    while IFS= read -r -d '' path
    do
        [[ "${path}" == "${manifest}" ]] && continue

        hash="$(sha256sum "${path}" | awk '{print $1}')"
        relative="${path#"${stage}/"}"

        printf 'file %s %s\n' "${hash}" "${relative}" >> "${manifest}"

    done < <(find "${stage}" -type f -print0)

    ok "Manifest written."
}

###############################################################################
# Verify checksums recorded in a stage directory
#
# Arguments:
#   $1 - Stage directory
#
###############################################################################

backup_verify_tree()
{
    local stage="$1"
    local manifest="${stage}/manifest.txt"
    local record
    local hash
    local path
    local actual
    local project=""
    local files=0

    [[ -f "${manifest}" ]] \
        || fail "Manifest is missing: ${manifest}"

    while IFS= read -r line || [[ -n "${line}" ]]
    do
        [[ -z "${line}" || "${line}" == \#* ]] && continue

        if [[ "${line}" == project=* ]]; then
            project="${line#project=}"
            continue
        fi

        #
        # config.sh sets IFS to newline and tab, so read does not split
        # this line on spaces. Peel the hash and the path apart directly.
        #

        [[ "${line}" == file\ * ]] || continue

        record="${line#file }"
        hash="${record%% *}"
        path="${record#* }"

        [[ -n "${hash}" && -n "${path}" && "${hash}" != "${path}" ]] \
            || fail "Manifest entry is not a file record."

        [[ -f "${stage}/${path}" ]] \
            || fail "Manifest file is missing: ${path}"

        actual="$(sha256sum "${stage}/${path}" | awk '{print $1}')"

        [[ "${actual}" == "${hash}" ]] \
            || fail "Checksum mismatch: ${path}"

        files=$((files + 1))

    done < "${manifest}"

    [[ "${project}" == "${PROJECT_NAME}" ]] \
        || fail "Manifest project is '${project}', expected '${PROJECT_NAME}'."

    [[ "${files}" -gt 0 ]] \
        || fail "Manifest does not list any files."

    ok "Manifest checksums match (${files} files)."
}

###############################################################################
# Read one manifest field
#
# Arguments:
#   $1 - Manifest file
#   $2 - Field name
#
###############################################################################

backup_manifest_field()
{
    local manifest="$1"
    local field="$2"
    local line

    while IFS= read -r line || [[ -n "${line}" ]]
    do
        [[ "${line}" == "${field}="* ]] || continue
        printf '%s\n' "${line#"${field}="}"
        return 0
    done < "${manifest}"

    fail "Manifest field is missing: ${field}"
}

###############################################################################
# Pack a stage directory and write a sidecar checksum
#
# Arguments:
#   $1 - Stage directory
#   $2 - Archive path (.tar.gz)
#
###############################################################################

backup_pack_stage()
{
    local stage="$1"
    local archive="$2"

    [[ -d "${stage}" ]] \
        || fail "Backup stage is not a directory: ${stage}"

    backup_create_private_file "${archive}"

    tar -C "${stage}" -czf "${archive}" .

    backup_write_checksum "${archive}"

    ok "Archive written: ${archive}"
}

###############################################################################
# Sidecar checksum for one archive file
#
# Arguments:
#   $1 - Archive path
#
# The checksum file is created mode 600. Production backup uses this
# on the encrypted archive, not on a plaintext tar that is kept.
#
###############################################################################

backup_write_checksum()
{
    local archive="$1"
    local directory
    local base

    directory="$(dirname "${archive}")"
    base="$(basename "${archive}")"

    backup_create_private_file "${archive}.sha256"

    #
    # Store the basename. An absolute path in the sidecar would not
    # match after the archive is copied to another directory.
    #

    (
        cd "${directory}" || exit 1
        sha256sum "${base}" > "${base}.sha256"
    )
}

###############################################################################
# Verify an archive, its sidecar checksum and its manifest
#
# Arguments:
#   $1 - Archive path
#   $2 - Directory where the archive will be extracted
#
###############################################################################

backup_verify_archive()
{
    local archive="$1"
    local destination="$2"

    backup_require_sidecar "${archive}" "archive"

    mkdir -p "${destination}"

    tar -C "${destination}" -xzf "${archive}"

    backup_verify_tree "${destination}"
}

###############################################################################
# Check a sidecar checksum in the directory that holds the archive
#
# Arguments:
#   $1 - Archive path
#
###############################################################################

backup_verify_sidecar()
{
    local archive="$1"

    [[ -f "${archive}" ]] || return 1

    [[ -f "${archive}.sha256" ]] || return 1

    (
        cd "$(dirname "${archive}")" || exit 1
        sha256sum --check "$(basename "${archive}").sha256" >/dev/null
    )
}

###############################################################################
# Require a sidecar checksum
#
# Arguments:
#   $1 - Archive path
#   $2 - "archive" or "copy"
#
###############################################################################

backup_require_sidecar()
{
    local archive="$1"
    local kind="$2"

    if backup_verify_sidecar "${archive}"; then
        return 0
    fi

    if [[ "${kind}" == "copy" ]]; then
        fail "Checksum of the copy in $(dirname "${archive}") does not match. The copy is not a verified backup."
    fi

    fail "Archive checksum does not match ${archive}."
}

###############################################################################
# Copy an archive and verify the checksum on the destination
#
# Arguments:
#   $1 - Archive path
#   $2 - Destination directory
#
# Both files are installed first. The sidecar is checked only after
# that copy. A failed check does not describe the copy as verified.
#
###############################################################################

backup_copy_and_verify()
{
    local archive="$1"
    local dest_dir="$2"
    local base

    base="$(basename "${archive}")"

    [[ -d "${dest_dir}" ]] \
        || fail "Backup destination is not a directory: ${dest_dir}"

    [[ -f "${archive}.sha256" ]] \
        || fail "Archive checksum not found: ${archive}.sha256"

    install -m 600 "${archive}" "${dest_dir}/${base}"
    install -m 600 "${archive}.sha256" "${dest_dir}/${base}.sha256"

    backup_require_sidecar "${dest_dir}/${base}" "copy"

    ok "Verified archive copy: ${dest_dir}/${base}"
}
