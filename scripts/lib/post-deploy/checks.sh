#!/usr/bin/env bash

###############################################################################
#
# Nextcloud-Gr Project
#
# Checks that are meaningful only after the stack is running.
# State files are replaced only after every check below has passed.
#
###############################################################################

post_deploy_container_image()
{
    docker inspect --format '{{.Config.Image}}' "$1"
}

post_deploy_health_status()
{
    docker inspect \
        --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
        "$1"
}

post_deploy_sleep()
{
    sleep "$1"
}

post_deploy_status_body()
{
    curl -fsS "$1"
}

post_deploy_published_ports()
{
    docker ps --format '{{.Ports}}'
}

post_deploy_postgres_major()
{
    local text

    text="$(docker exec "${POSTGRESQL_CONTAINER}" postgres -V)" || return 1
    [[ "${text}" =~ PostgreSQL\)[[:space:]]+([0-9]+) ]] || return 1
    printf '%s\n' "${BASH_REMATCH[1]}"
}

###############################################################################
# The Nextcloud healthcheck stays "starting" while the image entrypoint
# initializes PostgreSQL, Redis and the first installation. Poll until
# the start period can finish. POST_DEPLOY_HEALTH_ATTEMPTS and
# POST_DEPLOY_HEALTH_DELAY override the wait in tests.
#
###############################################################################

post_deploy_wait_healthy()
{
    local attempts="${POST_DEPLOY_HEALTH_ATTEMPTS:-24}"
    local delay="${POST_DEPLOY_HEALTH_DELAY:-15}"
    local try=0
    local container
    local status
    local unhealthy=""

    while [[ "${try}" -lt "${attempts}" ]]
    do
        try=$((try + 1))
        unhealthy=""

        for container in \
            "${POSTGRESQL_CONTAINER}" \
            "${REDIS_CONTAINER}" \
            "${NEXTCLOUD_APP_CONTAINER}" \
            "${NGINX_CONTAINER}" \
            "${NEXTCLOUD_CRON_CONTAINER}"
        do
            status="$(post_deploy_health_status "${container}")" \
                || fail "Health status for ${container} could not be read. State files were not written."

            if [[ "${status}" != "healthy" ]]; then
                unhealthy="${container} ${status}"
                break
            fi
        done

        if [[ -z "${unhealthy}" ]]; then
            ok "Service healthchecks are healthy."
            return 0
        fi

        if [[ "${try}" -lt "${attempts}" ]]; then
            info "Waiting for healthchecks (${try}/${attempts}): ${unhealthy}."
            post_deploy_sleep "${delay}"
        fi
    done

    fail "${unhealthy%% *} health status is '${unhealthy#* }'. State files were not written."
}

post_deploy_require_images()
{
    local actual
    local expected

    actual="$(post_deploy_container_image "${NEXTCLOUD_APP_CONTAINER}")" \
        || fail "The Nextcloud image could not be read. State files were not written."
    expected="$(env_get NEXTCLOUD_IMAGE):$(env_get NEXTCLOUD_TAG)"
    image_reference_matches "${actual}" "${expected}" \
        || fail "Running Nextcloud image is ${actual}. Expected ${expected}. State files were not written."

    actual="$(post_deploy_container_image "${POSTGRESQL_CONTAINER}")" \
        || fail "The PostgreSQL image could not be read. State files were not written."
    expected="$(env_get POSTGRES_IMAGE)"
    image_reference_matches "${actual}" "${expected}" \
        || fail "Running PostgreSQL image is ${actual}. Expected ${expected}. State files were not written."

    ok "Running images match the pins."
}

post_deploy_checks()
{
    print_section "Runtime"

    local lock_message
    local container
    local installed_flag
    local versionstring
    local expected
    local needs_db
    local maintenance
    local memcache
    local bind
    local port
    local body
    local live_major
    local image_major
    local disk_major
    local disk_status=0

    lock_message="$(deploy_upgrade_lock_decision "${UPGRADE_LOCK_FILE}")" \
        || fail "${lock_message}"

    require_directory "$(env_get POSTGRESQL_HOST_DIR)"
    require_directory "${NEXTCLOUD_HTML_DIR}"
    require_directory "$(env_get NEXTCLOUD_DATA_HOST_DIR)"

    for container in \
        "${POSTGRESQL_CONTAINER}" \
        "${REDIS_CONTAINER}" \
        "${NEXTCLOUD_APP_CONTAINER}" \
        "${NGINX_CONTAINER}" \
        "${NEXTCLOUD_CRON_CONTAINER}"
    do
        require_container_running "${container}"
    done

    post_deploy_wait_healthy
    post_deploy_require_images

    if ! installed_flag="$(nextcloud_occ_status_value installed)"; then
        fail "occ status failed. Nextcloud may still be starting. State files were not written. When the installation is finished, run ./scripts/post-deploy.sh."
    fi

    if [[ "${installed_flag}" != "true" ]]; then
        fail "Nextcloud is not installed yet. State files were not written. Finish the first installation, then run ./scripts/post-deploy.sh."
    fi

    if ! versionstring="$(nextcloud_occ_status_value versionstring)"; then
        fail "occ status did not report versionstring. State files were not written."
    fi

    expected="$(upgrade_release_number "$(env_get NEXTCLOUD_TAG)")" \
        || fail "NEXTCLOUD_TAG is not an exact X.Y.Z-fpm release. State files were not written."

    [[ "${versionstring}" == "${expected}" ]] \
        || fail "occ versionstring is ${versionstring}, expected ${expected}. State files were not written."

    if ! needs_db="$(nextcloud_occ_status_value needsDbUpgrade)"; then
        fail "occ status did not report needsDbUpgrade. State files were not written."
    fi

    [[ "${needs_db}" == "false" ]] \
        || fail "Nextcloud still needs a database upgrade. State files were not written."

    if ! maintenance="$(nextcloud_occ_status_value maintenance)"; then
        fail "occ status did not report maintenance. State files were not written."
    fi

    [[ "${maintenance}" == "false" ]] \
        || fail "Nextcloud maintenance mode is ${maintenance}. State files were not written."

    memcache="$(nextcloud_occ config:system:get memcache.local || true)"
    [[ "${memcache}" == *APCu* ]] \
        || fail "memcache.local is not APCu. State files were not written."

    bind="$(env_get NEXTCLOUD_BACKEND_BIND)"
    port="$(env_get NEXTCLOUD_BACKEND_PORT)"
    body="$(post_deploy_status_body "http://${bind}:${port}/status.php")" \
        || fail "status.php is not reachable. State files were not written."

    [[ "${body}" == *'"installed":true'* ]] \
        || fail "status.php does not report installed:true. State files were not written."
    [[ "${body}" == *'"maintenance":false'* ]] \
        || fail "status.php reports maintenance mode. State files were not written."
    [[ "${body}" != *'"needsDbUpgrade":true'* ]] \
        || fail "status.php reports needsDbUpgrade. State files were not written."

    post_deploy_published_ports \
        | grep -Eq "(^|, )${bind}:${port}->" \
        || fail "Port ${port} is not bound to ${bind}. State files were not written."

    if post_deploy_published_ports | grep -Eq '5432->|6379->|9000->'; then
        fail "PostgreSQL, Redis or PHP-FPM is published on the host. State files were not written."
    fi

    live_major="$(post_deploy_postgres_major)" \
        || fail "The running PostgreSQL major could not be read. State files were not written."

    image_major="$(postgres_image_major "$(env_get POSTGRES_IMAGE)")" \
        || fail "POSTGRES_IMAGE is not an exact major.minor tag. State files were not written."

    [[ "${live_major}" == "${image_major}" ]] \
        || fail "Running PostgreSQL is major ${live_major} and POSTGRES_IMAGE is major ${image_major}. State files were not written."

    disk_major="$(postgres_major_from_data_dir "$(env_get POSTGRESQL_HOST_DIR)")" \
        || disk_status=$?

    if [[ "${disk_status}" -eq 2 ]]; then
        fail "More than one PG_VERSION file is under $(env_get POSTGRESQL_HOST_DIR). State files were not written."
    fi

    if [[ "${disk_status}" -eq 3 ]]; then
        fail "PG_VERSION under $(env_get POSTGRESQL_HOST_DIR) is not a PostgreSQL major. State files were not written."
    fi

    if [[ "${disk_status}" -eq 4 ]]; then
        fail "PostgreSQL data under $(env_get POSTGRESQL_HOST_DIR) has no single readable major. State files were not written."
    fi

    if [[ "${disk_status}" -ne 0 ]]; then
        fail "PG_VERSION was not found under $(env_get POSTGRESQL_HOST_DIR). State files were not written."
    fi

    [[ "${disk_major}" == "${live_major}" ]] \
        || fail "PostgreSQL data directory is major ${disk_major} and the running server is major ${live_major}. State files were not written."

    state_write_installed "$(env_get NEXTCLOUD_TAG)" "${live_major}" \
        || fail "Could not record the installed version. The previous evidence was left in place."

    ok "Installed version recorded as $(env_get NEXTCLOUD_TAG)."
}
