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

backup_restic_run_at()
{
    local repo="$1"
    shift
    local password
    local passfile
    local status

    command -v restic >/dev/null 2>&1 \
        || fail "restic is not installed. No user-data backup was kept."

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

backup_restic_run()
{
    backup_restic_run_at "$(env_get RESTIC_REPOSITORY)" "$@"
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

backup_restic_verify_snapshot_at()
{
    local repo="$1"
    local snapshot="$2"

    backup_restic_snapshot_id_is_valid "${snapshot}" || return 1
    backup_restic_run_at "${repo}" cat config >/dev/null || return 1
    backup_restic_run_at "${repo}" snapshots --json "${snapshot}" \
        | grep -q "\"short_id\":\"${snapshot:0:8}\"" || return 1
    backup_restic_run_at "${repo}" ls "${snapshot}" >/dev/null
}

backup_restic_verify_snapshot()
{
    backup_restic_verify_snapshot_at "$(env_get RESTIC_REPOSITORY)" "$1"
}

###############################################################################
# Print yes or no. An empty id is no and does not contact restic.
#
# Arguments:
#   $1 - Repository
#   $2 - Snapshot id
#
###############################################################################

backup_snapshot_present_in_repository()
{
    local repo="$1"
    local snapshot="$2"

    if [[ -z "${snapshot}" ]]; then
        printf 'no\n'
        return 0
    fi

    if backup_restic_verify_snapshot_at "${repo}" "${snapshot}"; then
        printf 'yes\n'
    else
        printf 'no\n'
    fi
}

backup_restic_snapshot_exists()
{
    local snapshot="$1"

    backup_restic_verify_snapshot "${snapshot}"
}

###############################################################################
# Copy one snapshot into another repository that uses the same password.
#
# Arguments:
#   $1 - Snapshot id
#   $2 - Destination repository
#
###############################################################################

backup_restic_copy_snapshot()
{
    local snapshot="$1"
    local destination="$2"
    local source
    local passfile
    local status

    backup_restic_snapshot_id_is_valid "${snapshot}" || return 1
    source="$(env_get RESTIC_REPOSITORY)"
    [[ -n "${source}" && "${source}" != "${destination}" ]] || return 1

    if ! backup_restic_run_at "${destination}" snapshots >/dev/null 2>&1; then
        backup_restic_run_at "${destination}" init || return 1
    fi

    command -v restic >/dev/null 2>&1 || return 1
    passfile="$(mktemp)"
    chmod 600 "${passfile}"
    printf '%s\n' "$(env_get RESTIC_PASSWORD)" > "${passfile}"

    set +e
    RESTIC_PASSWORD_FILE="${passfile}" \
        RESTIC_FROM_PASSWORD_FILE="${passfile}" \
        restic -r "${destination}" copy --from-repo "${source}" "${snapshot}"
    status=$?
    set -e

    shred -u "${passfile}" 2>/dev/null || rm -f "${passfile}"
    return "${status}"
}

###############################################################################
# Read one JSON string field. The field "id" does not match "short_id".
#
# Arguments:
#   $1 - JSON file
#   $2 - Field name
#
###############################################################################

backup_restic_json_string_field()
{
    local file="$1"
    local field="$2"

    awk -v field="${field}" '
        {
            pattern = "\"" field "\"[[:space:]]*:[[:space:]]*\"([^\"]*)\""
            if (match($0, pattern, found)) {
                print found[1]
                exit
            }
        }
    ' "${file}"
}

###############################################################################
# Find the snapshot id in a snapshots --json document whose tree, time
# and hostname match. restic copy may store that object under a new id.
#
# Arguments:
#   $1 - Destination snapshots JSON
#   $2 - Tree id
#   $3 - Snapshot time
#   $4 - Hostname
#
###############################################################################

backup_restic_match_snapshot_id()
{
    local file="$1"
    local want_tree="$2"
    local want_time="$3"
    local want_host="$4"
    local matched
    local status=0

    [[ -n "${want_tree}" && -n "${want_time}" && -n "${want_host}" ]] || return 1

    matched="$(
        awk \
            -v want_tree="${want_tree}" \
            -v want_time="${want_time}" \
            -v want_host="${want_host}" '
            function take(name, value) {
                if (name == "tree") {
                    tree = value
                } else if (name == "time") {
                    time = value
                } else if (name == "hostname") {
                    host = value
                } else if (name == "id") {
                    id = value
                }
            }
            function flush() {
                if (tree == want_tree && time == want_time && host == want_host && id ~ /^[0-9a-f]{8,64}$/) {
                    count++
                    if (count == 1) {
                        matched = id
                    } else {
                        matched = ""
                    }
                }
                tree = ""
                time = ""
                host = ""
                id = ""
            }
            BEGIN {
                count = 0
                matched = ""
            }
            {
                while (match($0, /"(tree|time|hostname|id)"[[:space:]]*:[[:space:]]*"([^"]*)"/, found)) {
                    take(found[1], found[2])
                    $0 = substr($0, RSTART + RLENGTH)
                }
                if ($0 ~ /^[[:space:]]*\}/) {
                    flush()
                }
            }
            END {
                if (id != "" || tree != "") {
                    flush()
                }
                if (count == 1) {
                    print matched
                    exit 0
                }
                if (count > 1) {
                    print "ambiguous"
                    exit 1
                }
                print "missing"
                exit 1
            }
        ' "${file}"
    )" || status=$?

    if [[ "${status}" -ne 0 ]]; then
        printf '%s\n' "${matched:-missing}"
        return 1
    fi

    backup_restic_snapshot_id_is_valid "${matched}" || {
        printf 'missing\n'
        return 1
    }
    printf '%s\n' "${matched}"
}

###############################################################################
# Resolve the destination snapshot from the two JSON documents.
#
# Arguments:
#   $1 - JSON from the source snapshot
#   $2 - JSON from the destination repository
#
###############################################################################

backup_restic_resolve_id_from_json()
{
    local source_json="$1"
    local destination_json="$2"
    local tree
    local snapshot_time
    local hostname

    tree="$(backup_restic_json_string_field "${source_json}" tree)"
    snapshot_time="$(backup_restic_json_string_field "${source_json}" time)"
    hostname="$(backup_restic_json_string_field "${source_json}" hostname)"

    backup_restic_match_snapshot_id "${destination_json}" "${tree}" "${snapshot_time}" "${hostname}"
}

###############################################################################
# Copy a snapshot and print the id verified in the destination.
#
# The text from restic copy is discarded. The id is read from the
# destination snapshots --json metadata and checked with cat, snapshots
# and ls.
#
# Arguments:
#   $1 - Source snapshot id
#   $2 - Destination repository
#
###############################################################################

backup_restic_copy_and_resolve()
{
    local source_id="$1"
    local destination="$2"
    local source_json
    local destination_json
    local resolved

    source_json="$(mktemp)"
    destination_json="$(mktemp)"

    if ! backup_restic_run snapshots --json "${source_id}" > "${source_json}"; then
        rm -f "${source_json}" "${destination_json}"
        return 1
    fi

    if ! backup_restic_copy_snapshot "${source_id}" "${destination}" >/dev/null; then
        rm -f "${source_json}" "${destination_json}"
        return 1
    fi

    if ! backup_restic_run_at "${destination}" snapshots --json > "${destination_json}"; then
        rm -f "${source_json}" "${destination_json}"
        return 1
    fi

    if ! resolved="$(backup_restic_resolve_id_from_json "${source_json}" "${destination_json}")"; then
        rm -f "${source_json}" "${destination_json}"
        return 1
    fi

    rm -f "${source_json}" "${destination_json}"

    backup_restic_verify_snapshot_at "${destination}" "${resolved}" || return 1
    printf '%s\n' "${resolved}"
}

###############################################################################
# Choose the snapshot verified in the repository restore will read.
# The source id and the external id may differ.
#
# Arguments:
#   $1 - Source snapshot id
#   $2 - External snapshot id, possibly empty
#   $3 - yes when $1 verified in the selected repository
#   $4 - yes when $2 verified in that same repository
#
###############################################################################

backup_choose_snapshot_id()
{
    local source_id="$1"
    local external_id="$2"
    local source_present="$3"
    local external_present="$4"

    backup_restic_snapshot_id_is_valid "${source_id}" || {
        printf 'missing\n'
        return 1
    }

    if [[ -n "${external_id}" ]] && ! backup_restic_snapshot_id_is_valid "${external_id}"; then
        printf 'missing\n'
        return 1
    fi

    if [[ -n "${external_id}" && "${external_id}" != "${source_id}" \
        && "${source_present}" == "yes" && "${external_present}" == "yes" ]]; then
        printf 'ambiguous\n'
        return 1
    fi

    if [[ "${source_present}" == "yes" ]]; then
        printf '%s\n' "${source_id}"
        return 0
    fi

    if [[ "${external_present}" == "yes" && -n "${external_id}" ]]; then
        printf '%s\n' "${external_id}"
        return 0
    fi

    printf 'missing\n'
    return 1
}

###############################################################################
# Select the snapshot id for the repository restore will read.
#
# A manifest that only has restic_snapshot_id can be restored when that
# id verifies in the repository. It cannot identify a copied snapshot
# whose id changed. Locator metadata is accepted only when the caller
# already proved there is exactly one match. This function does not
# rank snapshots by time.
#
# Arguments:
#   $1 - Source snapshot id
#   $2 - External snapshot id, possibly empty
#   $3 - yes when $1 verified in the selected repository
#   $4 - yes when $2 verified in that same repository
#   $5 - absent, unique, ambiguous or missing. Omitted means absent.
#   $6 - Id from a unique locator match. Ignored unless $5 is unique.
#
###############################################################################

backup_select_restore_snapshot()
{
    local source_id="$1"
    local external_id="$2"
    local source_present="$3"
    local external_present="$4"
    local locator_status="${5:-absent}"
    local locator_id="${6:-}"

    if [[ -n "${external_id}" ]]; then
        backup_choose_snapshot_id \
            "${source_id}" \
            "${external_id}" \
            "${source_present}" \
            "${external_present}"
        return
    fi

    if ! backup_restic_snapshot_id_is_valid "${source_id}"; then
        printf 'missing\n'
        return 1
    fi

    if [[ "${source_present}" == "yes" ]]; then
        printf '%s\n' "${source_id}"
        return 0
    fi

    if [[ "${locator_status}" == "unique" ]] \
        && backup_restic_snapshot_id_is_valid "${locator_id}"
    then
        printf '%s\n' "${locator_id}"
        return 0
    fi

    if [[ "${locator_status}" == "ambiguous" ]]; then
        printf 'ambiguous\n'
        return 1
    fi

    if [[ "${locator_status}" == "absent" ]]; then
        printf 'legacy-unresolved\n'
        return 1
    fi

    printf 'missing\n'
    return 1
}

###############################################################################
# The external copy is complete only with the age archive and a verified
# snapshot id from that repository.
#
###############################################################################

backup_external_pair_complete()
{
    local age_stored="$1"
    local external_id="$2"
    local external_verified="$3"

    backup_restic_snapshot_id_is_valid "${external_id}" || return 1

    [[ "${age_stored}" == "yes" && "${external_verified}" == "yes" ]]
}

###############################################################################
# Classify whether the age archive and the restic snapshot together
# are an external restore point.
#
# Arguments:
#   $1 - primary repository is remote: yes or no
#   $2 - snapshot verified in the primary repository: yes or no
#   $3 - snapshot verified on separate storage: yes or no
#   $4 - age manifest names a snapshot id: yes or no
#
# Prints external, local-only or incomplete.
# Returns 0, 2 or 1 in that order.
#
###############################################################################

backup_completeness()
{
    local repo_remote="$1"
    local snapshot_in_primary="$2"
    local snapshot_on_separate="$3"
    local age_has_snapshot="$4"

    if [[ "${age_has_snapshot}" != "yes" || "${snapshot_in_primary}" != "yes" ]]; then
        printf 'incomplete\n'
        return 1
    fi

    if [[ "${repo_remote}" == "yes" || "${snapshot_on_separate}" == "yes" ]]; then
        printf 'external\n'
        return 0
    fi

    printf 'local-only\n'
    return 2
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
