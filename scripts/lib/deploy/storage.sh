#!/usr/bin/env bash

###############################################################################
#
# Nextcloud-Gr Project
#
# File:
#   scripts/lib/deploy/storage.sh
#
# Description:
#   Prepare HTML, PostgreSQL and the new Nextcloud data directory.
#   Missing mounts are an error. Existing trees are not chowned
#   recursively.
#
###############################################################################

storage_prepare_html()
{
    storage_require_mountpoint "${DOCKER_DATA_DIR}"

    mkdir -p "${DATA_DIR}" "${NEXTCLOUD_HTML_DIR}" "${NEXTCLOUD_STATE_DIR}" "${BACKUP_LOCAL_DIR}"
    chmod 700 "${BACKUP_LOCAL_DIR}" "${NEXTCLOUD_STATE_DIR}"

    if [[ -z "$(ls -A "${NEXTCLOUD_HTML_DIR}")" ]]; then
        chown "${NEXTCLOUD_UID_GID}" "${NEXTCLOUD_HTML_DIR}"
    fi
}

storage_prepare_bound_directory()
{
    local path="$1"
    local purpose="$2"
    local owner="$3"
    local uid

    storage_require_ready_directory "${path}" "${purpose}"

    if [[ -n "$(ls -A "${path}")" ]]; then
        uid="$(stat -c '%u' "${path}")"
        [[ "${uid}" == "${owner%%:*}" || "${uid}" == "0" ]] \
            || fail "${purpose} directory ${path} is owned by uid ${uid}. Refusing chown -R."
        return 0
    fi

    chown "${owner}" "${path}"
}

deploy_prepare_storage()
{
    print_section "Persistent storage"

    storage_prepare_html
    storage_prepare_bound_directory \
        "$(env_get POSTGRESQL_HOST_DIR)" \
        "PostgreSQL" \
        "${POSTGRESQL_UID_GID}"
    storage_prepare_bound_directory \
        "$(env_get NEXTCLOUD_DATA_HOST_DIR)" \
        "Nextcloud data" \
        "${NEXTCLOUD_UID_GID}"

    ok "Persistent directories are on mounted filesystems."
}

###############################################################################
# Create the bridge recorded in .env. An existing network with a
# different subnet is left in place and reported as an error.
###############################################################################

deploy_ensure_network()
{
    print_section "Docker network"

    local subnet
    local gateway
    local existing

    subnet="$(env_get DOCKER_NETWORK_SUBNET)"
    gateway="$(env_get DOCKER_NETWORK_GATEWAY)"

    if docker network inspect "${NETWORK_INTERNAL}" >/dev/null 2>&1; then
        existing="$(
            docker network inspect \
                --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' \
                "${NETWORK_INTERNAL}"
        )"

        [[ "${existing}" == "${subnet}" ]] \
            || fail "Docker network ${NETWORK_INTERNAL} already uses ${existing}, not ${subnet}."

        ok "Docker network ${NETWORK_INTERNAL} already uses ${subnet}."
        return 0
    fi

    docker network create \
        --driver bridge \
        --subnet "${subnet}" \
        --gateway "${gateway}" \
        "${NETWORK_INTERNAL}" \
        >/dev/null

    ok "Docker network ${NETWORK_INTERNAL} created."
}
