#!/usr/bin/env bash

###############################################################################
#
# Authentik-netcup Project
#
# File:
#   scripts/lib/backup/crypto.sh
#
# Description:
#   Encrypt a backup with age and decrypt it for restore.
#
#   BACKUP_AGE_RECIPIENT is a public recipient. The private identity
#   is not stored in Git, in the archive, or in the stack. age reads
#   the identity from a file descriptor so the key material is not a
#   process argument.
#
#   The published checksum belongs to the encrypted file. tar writes
#   to stdout and age reads that stream. No plaintext tar file is
#   created. The private identity is not used here, so the .age file
#   cannot be decrypted to repeat the stage check.
#
###############################################################################

###############################################################################
# Public recipient, not an age identity
#
# Arguments:
#   $1 - Recipient
#
###############################################################################

backup_recipient_is_public()
{
    local recipient="$1"

    [[ -n "${recipient}" ]] || return 1

    [[ "${recipient}" != *$'\n'* ]] || return 1

    [[ "${recipient}" != AGE-SECRET-KEY-* ]] || return 1

    if [[ "${recipient}" == age1* ]]; then
        [[ "${recipient}" =~ ^age1[a-z0-9]+$ ]]
        return
    fi

    [[ "${recipient}" =~ ^ssh-(ed25519|rsa)[[:space:]]+[A-Za-z0-9+/=]+([[:space:]]+[^[:space:]]+)?$ ]]
}

###############################################################################
# Refuse to keep an archive when encryption is not available
#
# Arguments:
#   $1 - BACKUP_AGE_RECIPIENT
#
# Failure means no durable archive was written. The run is not a safe
# external backup.
#
###############################################################################

backup_require_encryption()
{
    local recipient="$1"

    if [[ -z "${recipient}" ]]; then
        fail "BACKUP_AGE_RECIPIENT is empty. No archive was kept. This run is not a safe external backup."
    fi

    if ! backup_recipient_is_public "${recipient}"; then
        fail "BACKUP_AGE_RECIPIENT is not a public age recipient. No archive was kept. This run is not a safe external backup."
    fi

    if ! command -v age >/dev/null 2>&1; then
        fail "age is not installed. No archive was kept. This run is not a safe external backup."
    fi
}

###############################################################################
# Encrypt a plaintext archive
#
# Arguments:
#   $1 - Plaintext archive
#   $2 - Destination .age path
#   $3 - Public recipient
#
# The destination is created mode 600 before age writes it. The
# recipient is public. It is not written to the log.
#
###############################################################################

backup_encrypt_file()
{
    local plain="$1"
    local encrypted="$2"
    local recipient="$3"

    [[ -f "${plain}" ]] || return 1

    backup_recipient_is_public "${recipient}" || return 1

    command -v age >/dev/null 2>&1 || return 1

    backup_create_private_file "${encrypted}" || return 1

    age -r "${recipient}" -o "${encrypted}" "${plain}" >/dev/null
}

###############################################################################
# Encrypt a stage directory without writing a plaintext tar
#
# Arguments:
#   $1 - Stage directory
#   $2 - Destination .age path
#   $3 - Public recipient
#
# tar and age run in one pipeline. pipefail is enabled so a tar
# failure is not hidden when age exits 0. The destination is created
# mode 600 before age writes it. On failure that file is removed.
# The private identity is not an argument.
#
###############################################################################

backup_encrypt_stage()
{
    local stage="$1"
    local encrypted="$2"
    local recipient="$3"

    [[ -d "${stage}" ]] || return 1

    backup_recipient_is_public "${recipient}" || return 1

    command -v age >/dev/null 2>&1 || return 1
    command -v tar >/dev/null 2>&1 || return 1

    backup_create_private_file "${encrypted}" || return 1

    #
    # pipefail is a shell option, not a local one. Leaving it on keeps
    # a later pipeline from hiding a producer failure.
    #

    set -o pipefail

    if ! tar -C "${stage}" -czf - . \
        | age -r "${recipient}" -o "${encrypted}" >/dev/null
    then
        backup_destroy_file "${encrypted}" || true
        return 1
    fi

    if [[ ! -s "${encrypted}" ]]; then
        backup_destroy_file "${encrypted}" || true
        return 1
    fi
}

###############################################################################
# Remove a failed ciphertext and any final path already copied
#
# Arguments:
#   $1 - Final .age path
#   $2 - Temporary directory
#
###############################################################################

backup_drop_encrypted_attempt()
{
    local final="$1"
    local pending_dir="$2"

    backup_destroy_file "${final}" || true
    backup_destroy_file "${final}.sha256" || true
    backup_destroy_tree "${pending_dir}" || true
}

###############################################################################
# Publish one encrypted archive after its checksum matches
#
# Arguments:
#   $1 - Stage directory
#   $2 - Final .age path
#   $3 - Public recipient
#   $4 - Private directory for the temporary ciphertext
#
# The final path is written only after the pipeline and the checksum
# of that ciphertext both succeed. A failure deletes the final path
# and the temporary ciphertext. Return 2 means the final file passed
# its checksum and the temporary directory could not be removed.
#
###############################################################################

backup_store_encrypted_stage()
{
    local stage="$1"
    local final="$2"
    local recipient="$3"
    local pending_dir="$4"
    local pending="${pending_dir}/stream.tar.gz.age"
    local pending_hash
    local final_hash

    [[ -d "${pending_dir}" ]] || return 1

    if ! backup_encrypt_stage "${stage}" "${pending}" "${recipient}"; then
        backup_drop_encrypted_attempt "${final}" "${pending_dir}"
        return 1
    fi

    if ! backup_write_checksum "${pending}"; then
        backup_drop_encrypted_attempt "${final}" "${pending_dir}"
        return 1
    fi

    if ! backup_verify_sidecar "${pending}"; then
        backup_drop_encrypted_attempt "${final}" "${pending_dir}"
        return 1
    fi

    if ! install -m 600 "${pending}" "${final}"; then
        backup_drop_encrypted_attempt "${final}" "${pending_dir}"
        return 1
    fi

    #
    # The sidecar names the file beside it. Copying the temporary
    # sidecar would still name stream.tar.gz.age. Recompute it for
    # the published name and require the same digest.
    #

    pending_hash="$(awk '{print $1; exit}' "${pending}.sha256")" || {
        backup_drop_encrypted_attempt "${final}" "${pending_dir}"
        return 1
    }
    final_hash="$(sha256sum "${final}" | awk '{print $1}')" || {
        backup_drop_encrypted_attempt "${final}" "${pending_dir}"
        return 1
    }

    if [[ -z "${pending_hash}" || "${pending_hash}" != "${final_hash}" ]]; then
        backup_drop_encrypted_attempt "${final}" "${pending_dir}"
        return 1
    fi

    if ! backup_write_checksum "${final}"; then
        backup_drop_encrypted_attempt "${final}" "${pending_dir}"
        return 1
    fi

    if ! backup_verify_sidecar "${final}"; then
        backup_drop_encrypted_attempt "${final}" "${pending_dir}"
        return 1
    fi

    if ! backup_destroy_tree "${pending_dir}"; then
        return 2
    fi
}

###############################################################################
# Decrypt an archive with an identity file
#
# Arguments:
#   $1 - Encrypted archive
#   $2 - Plaintext destination
#   $3 - Identity file
#
# The identity contents stay in the file. age reads them through
# /dev/fd so they are not placed on the command line.
#
###############################################################################

backup_decrypt_file()
{
    local encrypted="$1"
    local plain="$2"
    local identity="$3"
    local identity_fd

    [[ -f "${encrypted}" ]] || return 1
    [[ -f "${identity}" ]] || return 1

    backup_create_private_file "${plain}" || return 1

    exec {identity_fd}<"${identity}" || return 1

    if ! age -d -i "/dev/fd/${identity_fd}" -o "${plain}" "${encrypted}" >/dev/null 2>&1; then
        exec {identity_fd}<&-
        backup_destroy_file "${plain}" || true
        return 1
    fi

    exec {identity_fd}<&-
}

###############################################################################
# Identity file is owner-only and outside the project trees
#
# Arguments:
#   $1 - Identity path
#
###############################################################################

backup_path_is_forbidden()
{
    local path="$1"
    local protected

    for protected in "${DATA_DIR}" "${STACK_DIR}" "${GIT_DIR}" "${BACKUP_LOCAL_DIR}"
    do
        [[ "${path}" == "${protected}" || "${path}" == "${protected}/"* ]] \
            && return 0
    done

    return 1
}

backup_require_identity()
{
    local identity="$1"
    local resolved
    local mode

    [[ -n "${identity}" ]] \
        || fail "Restore requires --identity PATH. The age identity is not read from Git, the stack, or the archive."

    [[ -f "${identity}" ]] \
        || fail "Age identity was not found."

    resolved="$(realpath -e "${identity}")" \
        || fail "Age identity path could not be resolved."

    if backup_path_is_forbidden "${resolved}"; then
        fail "Age identity must not be stored in Git, the stack, DATA_DIR, or the local backup directory."
    fi

    mode="$(stat -c '%a' "${resolved}")" \
        || fail "Age identity mode could not be read."

    [[ "${mode}" == "600" || "${mode}" == "400" ]] \
        || fail "Age identity must be mode 600 or 400."
}

###############################################################################
# Mount that contains a path, from the kernel mount table
#
# Arguments:
#   $1 - Existing path
#
# Prints the mountpoint. findmnt and /proc/self/mountinfo both have to
# agree. A shared device number is not used: the host directory
# /backups is an Incus bind mount on the same device as /docker-data.
# stat %m is not used either. On a bind mount it can report the parent.
#
###############################################################################

backup_mountpoint_from_table()
{
    local path="$1"

    BACKUP_MOUNT_QUERY="${path}" awk '
        function unescape(text, out, i, digits, value) {
            out = ""
            i = 1
            while (i <= length(text)) {
                if (substr(text, i, 1) == "\\" && i + 3 <= length(text)) {
                    digits = substr(text, i + 1, 3)
                    if (digits ~ /^[0-7][0-7][0-7]$/) {
                        value = substr(digits, 1, 1) * 64
                        value += substr(digits, 2, 1) * 8
                        value += substr(digits, 3, 1)
                        out = out sprintf("%c", value)
                        i += 4
                        continue
                    }
                }
                out = out substr(text, i, 1)
                i++
            }
            return out
        }
        BEGIN {
            target = ENVIRON["BACKUP_MOUNT_QUERY"]
            best = ""
        }
        {
            count = split($0, fields, " ")
            if (count < 5) {
                next
            }
            mountpoint = unescape(fields[5])
            if (mountpoint == "/") {
                if (best == "") {
                    best = mountpoint
                }
                next
            }
            if (target == mountpoint || index(target, mountpoint "/") == 1) {
                if (length(mountpoint) > length(best)) {
                    best = mountpoint
                }
            }
        }
        END {
            if (best != "") {
                print best
            }
        }
    ' /proc/self/mountinfo
}

backup_containing_mount()
{
    local path="$1"
    local from_table
    local from_findmnt
    local table_real
    local findmnt_real

    command -v findmnt >/dev/null 2>&1 || return 1
    command -v mountpoint >/dev/null 2>&1 || return 1

    from_table="$(backup_mountpoint_from_table "${path}")" || return 1
    [[ -n "${from_table}" ]] || return 1

    from_findmnt="$(findmnt -n -o TARGET -T "${path}")" || return 1
    [[ -n "${from_findmnt}" ]] || return 1

    table_real="$(realpath -m "${from_table}")" || return 1
    findmnt_real="$(realpath -m "${from_findmnt}")" || return 1

    [[ "${table_real}" == "${findmnt_real}" ]] || return 1

    printf '%s\n' "${findmnt_real}"
}

###############################################################################
# Resolved destination and how it may be described
#
# Arguments:
#   $1 - Requested directory
#   $2 - Local backup directory
#
# Prints one word to stdout:
#   host-mount
#   not-mounted
#
# host-mount means the resolved path is itself a mountpoint, mode 700,
# and that mountpoint is not "/" and not the mount that holds the
# local backup directory. It may use the same device number. It is the
# mounted host directory, not a second disk and not a remote transfer.
#
# not-mounted is an ordinary directory, including /backups when that
# path exists only on the container root filesystem. Nothing is copied.
#
###############################################################################

backup_classify_destination()
{
    local requested="$1"
    local local_dir="$2"
    local resolved
    local mode
    local dest_mount
    local local_mount

    [[ -d "${requested}" ]] \
        || fail "BACKUP_EXTERNAL_DIR is not a directory: ${requested}"

    resolved="$(realpath -e "${requested}")" \
        || fail "BACKUP_EXTERNAL_DIR could not be resolved: ${requested}"

    env_validate_backup_target "${resolved}"

    mode="$(stat -c '%a' "${resolved}")" \
        || fail "BACKUP_EXTERNAL_DIR mode could not be read."

    [[ "${mode}" == "700" ]] \
        || fail "BACKUP_EXTERNAL_DIR must be mode 700. Refusing to copy the archive to ${resolved}."

    [[ "$(stat -c '%u' "${resolved}")" == "$(id -u)" ]] \
        || fail "BACKUP_EXTERNAL_DIR must be owned by the user running backup.sh."

    dest_mount="$(backup_containing_mount "${resolved}")" \
        || fail "BACKUP_EXTERNAL_DIR mount information could not be read: ${resolved}"

    local_mount="$(backup_containing_mount "${local_dir}")" \
        || fail "Local backup directory mount information could not be read."

    if [[ "${resolved}" == "${dest_mount}" \
        && "${dest_mount}" != "/" \
        && "${dest_mount}" != "${local_mount}" ]] \
        && mountpoint -q -- "${resolved}"
    then
        printf '%s\n' "host-mount"
        return 0
    fi

    printf '%s\n' "not-mounted"
}

###############################################################################
# Copy an encrypted archive onto a mounted host directory
#
# Arguments:
#   $1 - Encrypted archive
#   $2 - Requested destination directory
#   $3 - Local backup directory
#
# The destination is not created. A path that is not itself a
# mountpoint is refused before any copy. The checksum is verified
# only after the archive and the sidecar are installed. Success here
# is a verified copy on that mount. It is not another disk and it is
# not a transfer to another server.
#
###############################################################################

backup_publish_encrypted()
{
    local archive="$1"
    local requested="$2"
    local local_dir="$3"
    local kind
    local resolved

    #
    # Classification runs in this command substitution, so a variable
    # set inside it does not survive. Resolve the path again here.
    #

    kind="$(backup_classify_destination "${requested}" "${local_dir}")"
    resolved="$(realpath -e "${requested}")"

    case "${kind}" in

        not-mounted)
            fail "BACKUP_EXTERNAL_DIR is not a mounted mountpoint: ${resolved}. Refusing to write. An ordinary directory on the container filesystem is not the host VPS directory."
            ;;

        host-mount)
            backup_copy_and_verify "${archive}" "${resolved}"
            warn "Verified encrypted copy on the mounted host directory: ${resolved}."
            warn "This is not a backup on another disk and it has not been transferred to another server."
            ;;

        *)
            fail "Unexpected backup destination class."
            ;;

    esac
}
