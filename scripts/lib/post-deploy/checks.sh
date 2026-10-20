#!/usr/bin/env bash

###############################################################################
#
# Nextcloud-Gr Project
#
# Checks that are meaningful only after the stack is running.
#
###############################################################################

post_deploy_checks()
{
    print_section "Runtime"

    require_directory "$(env_get POSTGRESQL_HOST_DIR)"
    require_directory "${NEXTCLOUD_HTML_DIR}"
    require_directory "$(env_get NEXTCLOUD_DATA_HOST_DIR)"

    require_container_running "${POSTGRESQL_CONTAINER}"
    require_container_running "${REDIS_CONTAINER}"
    require_container_running "${NEXTCLOUD_APP_CONTAINER}"
    require_container_running "${NGINX_CONTAINER}"
    require_container_running "${NEXTCLOUD_CRON_CONTAINER}"

    local container
    local status

    for container in \
        "${POSTGRESQL_CONTAINER}" \
        "${REDIS_CONTAINER}" \
        "${NEXTCLOUD_APP_CONTAINER}" \
        "${NGINX_CONTAINER}" \
        "${NEXTCLOUD_CRON_CONTAINER}"
    do
        status="$(
            docker inspect \
                --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
                "${container}"
        )"
        [[ "${status}" == "healthy" ]] \
            || fail "${container} health status is '${status}'."
    done

    ok "Service healthchecks are healthy."

    local versionstring
    local expected
    local maintenance

    versionstring="$(nextcloud_occ_status_value versionstring)"
    expected="$(upgrade_release_number "$(env_get NEXTCLOUD_TAG)")"
    [[ "${versionstring}" == "${expected}" ]] \
        || fail "occ versionstring is ${versionstring}, expected ${expected}."

    maintenance="$(nextcloud_occ_status_value maintenance)"
    [[ "${maintenance}" == "false" ]] \
        || fail "Nextcloud maintenance mode is ${maintenance}."

    local memcache
    memcache="$(nextcloud_occ config:system:get memcache.local || true)"
    [[ "${memcache}" == *APCu* ]] \
        || fail "memcache.local is not APCu."

    local bind
    local port
    local body

    bind="$(env_get NEXTCLOUD_BACKEND_BIND)"
    port="$(env_get NEXTCLOUD_BACKEND_PORT)"
    body="$(curl -fsS "http://${bind}:${port}/status.php")" \
        || fail "status.php is not reachable."

    [[ "${body}" == *'"installed":true'* ]] \
        || fail "status.php does not report installed:true."
    [[ "${body}" == *'"maintenance":false'* ]] \
        || fail "status.php reports maintenance mode."

    docker ps --format '{{.Ports}}' \
        | grep -Eq "(^|, )${bind}:${port}->" \
        || fail "Port ${port} is not bound to ${bind}."

    if docker ps --format '{{.Ports}}' | grep -Eq '5432->|6379->|9000->'; then
        fail "PostgreSQL, Redis or PHP-FPM is published on the host."
    fi

    mkdir -p "${NEXTCLOUD_STATE_DIR}"
    printf '%s\n' "$(env_get NEXTCLOUD_TAG)" > "${INSTALLED_VERSION_FILE}"
    printf '%s\n' "${POSTGRES_MAJOR}" > "${POSTGRES_MAJOR_FILE}"
    chmod 600 "${INSTALLED_VERSION_FILE}" "${POSTGRES_MAJOR_FILE}"

    ok "Installed version recorded as $(env_get NEXTCLOUD_TAG)."
}
