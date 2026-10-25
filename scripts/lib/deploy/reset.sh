#!/usr/bin/env bash

###############################################################################
#
# Nextcloud-Gr Project
#
# File:
#   scripts/lib/deploy/reset.sh
#
# Description:
#   Empty one test instance. This is not used by deploy.sh.
#   A finished Nextcloud is not reset by a normal deploy.
#
###############################################################################

###############################################################################
# A directory may be emptied only when it is strictly inside a non-root
# mount and it is not a forbidden tree (and does not contain one).
#
# Arguments:
#   $1 - Directory
#   $2 - Mountpoint that covers it
#   $3... - Forbidden paths
#
# Returns 0 when its children may be removed.
###############################################################################

reset_directory_may_be_emptied()
{
    local path="$1"
    local mount="$2"
    local forbidden

    [[ "${path}" == /* && "${path}" != "/" ]] || return 1
    [[ "${path}" != *$'\n'* && "${mount}" != *$'\n'* ]] || return 1
    [[ "${mount}" == /* && "${mount}" != "/" ]] || return 1
    [[ "${path}" == "${mount}"/* ]] || return 1

    shift 2
    for forbidden in "$@"
    do
        [[ -n "${forbidden}" ]] || continue
        if [[ "${path}" == "${forbidden}" \
            || "${path}" == "${forbidden}"/* \
            || "${forbidden}" == "${path}"/* ]]
        then
            return 1
        fi
    done

    return 0
}

###############################################################################
# Remove children of one directory, including hidden names.
# The directory itself stays.
###############################################################################

reset_clear_children()
{
    local dir="$1"
    local child
    local -a children=()

    shopt -s nullglob dotglob
    children=("${dir}"/*)
    shopt -u nullglob dotglob

    if [[ "${#children[@]}" -eq 0 ]]; then
        info "${dir} is already empty."
        return 0
    fi

    for child in "${children[@]}"
    do
        info "Removing ${child}"
        rm -rf -- "${child}"
    done
}

###############################################################################
# When the container exists, its mount for this destination must be the
# configured directory. Prints "absent" when the container does not
# exist. Returns 1 when an existing mount disagrees.
###############################################################################

reset_container_mount_matches()
{
    local container="$1"
    local source="$2"
    local destination="$3"
    local line
    local source_path
    local dest_path
    local found=1

    if ! docker container inspect "${container}" >/dev/null 2>&1; then
        printf 'absent\n'
        return 0
    fi

    while IFS= read -r line
    do
        [[ -n "${line}" ]] || continue
        source_path="${line%% -> *}"
        dest_path="${line##* -> }"
        [[ "${dest_path}" == "${destination}" ]] || continue
        source_path="$(realpath "${source_path}" 2>/dev/null || true)"
        [[ -n "${source_path}" && "${source_path}" == "$(realpath "${source}")" ]] || return 1
        found=0
    done < <(
        docker inspect \
            --format '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{println}}{{end}}' \
            "${container}"
    )

    return "${found}"
}

reset_require_distinct_paths()
{
    local left="$1"
    local right="$2"
    local left_real
    local right_real

    left_real="$(realpath "${left}")"
    right_real="$(realpath "${right}")"
    [[ "${left_real}" != "${right_real}" ]] || return 1
    [[ "${left_real}" != "${right_real}"/* && "${right_real}" != "${left_real}"/* ]] || return 1
    return 0
}

reset_require_safe_directory()
{
    local path="$1"
    local purpose="$2"
    local mount
    local real

    [[ -d "${path}" ]] \
        || fail "${purpose} ${path} does not exist. Nothing was deleted."

    real="$(realpath "${path}")"
    [[ "${real}" == "${path}" ]] \
        || fail "${purpose} ${path} resolves to ${real}. Nothing was deleted."

    mount="$(storage_mount_target "${path}")" \
        || fail "Cannot determine the filesystem of ${path}. Nothing was deleted."

    reset_directory_may_be_emptied \
        "${real}" \
        "${mount}" \
        "${GIT_DIR}" \
        "${DOCKGE_DIR}" \
        "${BACKUP_LOCAL_DIR}" \
        "${STACK_DIR}" \
        "${ENV_FILE}" \
        || fail "${purpose} ${real} is not a directory inside mount ${mount}. Nothing was deleted."
}

reset_require_known_mount()
{
    local container="$1"
    local source="$2"
    local destination="$3"
    local result=""

    if ! result="$(reset_container_mount_matches "${container}" "${source}" "${destination}")"; then
        fail "Container ${container} does not mount ${source} at ${destination}. Nothing was deleted."
    fi

    if [[ "${result}" == "absent" ]]; then
        info "Container ${container} does not exist. Checked ${source} with findmnt only."
        return 0
    fi

    ok "Container ${container} mounts ${source} at ${destination}."
}

###############################################################################
# Stop this stack and empty only its HTML tree, state files, PostgreSQL
# data directory and Nextcloud data directory. .env, the Docker network,
# Dockge, Redis configuration and local backups stay.
###############################################################################

reset_test_instance()
{
    local html_dir
    local data_dir
    local postgres_dir

    print_section "Reset test instance"

    [[ -f "${ENV_FILE}" ]] \
        || fail ".env not found. Nothing was deleted."

    html_dir="$(env_get NEXTCLOUD_HTML_HOST_DIR)"
    data_dir="$(env_get NEXTCLOUD_DATA_HOST_DIR)"
    postgres_dir="$(env_get POSTGRESQL_HOST_DIR)"

    [[ "${html_dir}" == "${NEXTCLOUD_HTML_DIR}" ]] \
        || fail "NEXTCLOUD_HTML_HOST_DIR is ${html_dir}, not ${NEXTCLOUD_HTML_DIR}. Nothing was deleted."

    reset_require_safe_directory "${html_dir}" "Nextcloud HTML"
    reset_require_safe_directory "${NEXTCLOUD_STATE_DIR}" "Nextcloud state"
    reset_require_safe_directory "${data_dir}" "Nextcloud data"
    reset_require_safe_directory "${postgres_dir}" "PostgreSQL"

    reset_require_distinct_paths "${html_dir}" "${data_dir}" \
        || fail "HTML and Nextcloud data resolve to the same tree. Nothing was deleted."
    reset_require_distinct_paths "${html_dir}" "${postgres_dir}" \
        || fail "HTML and PostgreSQL resolve to the same tree. Nothing was deleted."
    reset_require_distinct_paths "${data_dir}" "${postgres_dir}" \
        || fail "Nextcloud data and PostgreSQL resolve to the same tree. Nothing was deleted."

    reset_require_known_mount \
        "${NEXTCLOUD_APP_CONTAINER}" "${html_dir}" "/var/www/html"
    reset_require_known_mount \
        "${NEXTCLOUD_APP_CONTAINER}" "${data_dir}" "/var/www/html/data"
    reset_require_known_mount \
        "${NEXTCLOUD_CRON_CONTAINER}" "${html_dir}" "/var/www/html"
    reset_require_known_mount \
        "${NEXTCLOUD_CRON_CONTAINER}" "${data_dir}" "/var/www/html/data"
    reset_require_known_mount \
        "${NGINX_CONTAINER}" "${html_dir}" "/var/www/html"
    reset_require_known_mount \
        "${NGINX_CONTAINER}" "${data_dir}" "/var/www/html/data"
    reset_require_known_mount \
        "${POSTGRESQL_CONTAINER}" "${postgres_dir}" "/var/lib/postgresql"

    info "Keeping ${ENV_FILE}, ${BACKUP_LOCAL_DIR}, ${DOCKGE_DIR} and Docker network ${NETWORK_INTERNAL}."
    info "Redis has no data volume. ${STACK_DIR}/runtime is kept."

    compose_cmd stop \
        "${NEXTCLOUD_SERVICE}" \
        "${CRON_SERVICE}" \
        "${NGINX_SERVICE}" \
        "${POSTGRESQL_SERVICE}" \
        "${REDIS_SERVICE}"

    reset_clear_children "${html_dir}"
    reset_clear_children "${NEXTCLOUD_STATE_DIR}"
    reset_clear_children "${data_dir}"
    reset_clear_children "${postgres_dir}"

    ok "Test instance data was emptied. .env was not changed."
}
