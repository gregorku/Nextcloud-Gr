#!/usr/bin/env bash

###############################################################################
#
# Nextcloud-Gr Project
#
# File:
#   scripts/lib/deploy/version-guard.sh
#
# Description:
#   Stop deploy.sh before it pulls or starts a different Nextcloud or
#   PostgreSQL major than the one already installed. An existing
#   installation with no installed-version is not a first install.
#   Compose continues only when the on-disk code, the cluster major
#   and, if the stack is already running, occ all match the pins.
#
###############################################################################

deploy_assert_same_version()
{
    print_section "Version guard"

    local result
    local code_result
    local postgres_result
    local disk_major=""
    local disk_status=0
    local pg_dir
    local lock_message

    result="$(
        deploy_version_decision \
            "${INSTALLED_VERSION_FILE}" \
            "${NEXTCLOUD_HTML_DIR}/config/config.php" \
            "$(env_get NEXTCLOUD_TAG)"
    )" || fail "${result}"

    case "${result}" in
        unchanged)
            ok "Installed Nextcloud tag matches NEXTCLOUD_TAG."
            ;;
        first-install)
            info "No installed version and no config.php. This is a first installation."
            ;;
        unfinished)
            info "config.php has no installed flag. Deploy installs Nextcloud once and does not delete data directories."
            ;;
        recover)
            info "config.php is installed and installed-version is missing. This is not a first install. Evidence is written only after the running code, occ and PostgreSQL match."
            ;;
        *)
            fail "Unexpected version decision: ${result}"
            ;;
    esac

    code_result="$(
        deploy_on_disk_code_decision \
            "${NEXTCLOUD_HTML_DIR}/version.php" \
            "$(env_get NEXTCLOUD_TAG)"
    )" || fail "${code_result}"

    pg_dir="$(env_get POSTGRESQL_HOST_DIR)"
    if [[ -n "${pg_dir}" ]]; then
        disk_major="$(postgres_major_from_data_dir "${pg_dir}")" || disk_status=$?
        if [[ "${disk_status}" -eq 2 ]]; then
            fail "More than one PG_VERSION file is under ${pg_dir}. Refusing to guess the PostgreSQL major."
        fi
        if [[ "${disk_status}" -eq 3 ]]; then
            fail "PG_VERSION under ${pg_dir} is not a PostgreSQL major. Refusing to guess."
        fi
        if [[ "${disk_status}" -eq 4 ]]; then
            fail "PostgreSQL data under ${pg_dir} has no single readable major. Refusing to start a database image over it."
        fi
        if [[ "${disk_status}" -ne 0 ]]; then
            disk_major=""
        fi
    fi

    postgres_result="$(
        deploy_postgres_major_decision \
            "${POSTGRES_MAJOR_FILE}" \
            "$(env_get POSTGRES_IMAGE)" \
            "${disk_major}"
    )" || fail "${postgres_result}"

    case "${postgres_result}" in
        unchanged)
            ok "PostgreSQL major matches the pinned image."
            ;;
        first)
            ok "No PostgreSQL data directory yet. The pinned major is recorded after the installation is verified."
            ;;
        unrecorded)
            ok "PostgreSQL data matches the pinned major. postgres-major is recorded after the installation is verified."
            ;;
        *)
            fail "Unexpected PostgreSQL decision: ${postgres_result}"
            ;;
    esac

    if [[ "${result}" == "recover" ]]; then
        if [[ "${code_result}" != "match" ]]; then
            fail "config.php is installed but version.php does not match NEXTCLOUD_TAG. This is not a first install. State files were not written."
        fi
        if [[ -z "${disk_major}" ]]; then
            fail "config.php is installed but PG_VERSION was not found under ${pg_dir:-the PostgreSQL data directory}. PostgreSQL data is not under /docker-data/nextcloud-gr. The cluster file is <major>/docker/PG_VERSION. State files were not written."
        fi
        case "${postgres_result}" in
            unchanged|unrecorded)
                ;;
            *)
                fail "Unexpected PostgreSQL decision during recovery: ${postgres_result}"
                ;;
        esac
        deploy_assert_recover_allowed "${disk_major}"
    fi

    lock_message="$(deploy_upgrade_lock_decision "${UPGRADE_LOCK_FILE}")" \
        || fail "${lock_message}"
}

###############################################################################
# running when all five containers are up, partial when only some are,
# stopped when containers exist but none are up, absent otherwise.
###############################################################################

deploy_stack_presence()
{
    local running=0
    local present=0
    local container

    for container in \
        "${POSTGRESQL_CONTAINER}" \
        "${REDIS_CONTAINER}" \
        "${NEXTCLOUD_APP_CONTAINER}" \
        "${NGINX_CONTAINER}" \
        "${NEXTCLOUD_CRON_CONTAINER}"
    do
        if docker_container_running "${container}"; then
            running=$((running + 1))
            present=$((present + 1))
        elif docker_container_exists "${container}"; then
            present=$((present + 1))
        fi
    done

    if [[ "${running}" -eq 5 ]]; then
        printf 'running\n'
    elif [[ "${running}" -gt 0 ]]; then
        printf 'partial\n'
    elif [[ "${present}" -gt 0 ]]; then
        printf 'stopped\n'
    else
        printf 'absent\n'
    fi
}

deploy_container_image()
{
    local container="$1"
    local image

    if ! docker_container_exists "${container}"; then
        printf '\n'
        return 0
    fi

    image="$(docker inspect --format '{{.Config.Image}}' "${container}")" \
        || return 1
    printf '%s\n' "${image}"
}

###############################################################################
# Arguments:
#   $1 - major already read from PG_VERSION
#
# Cron may be unhealthy. That must not block the Compose refresh which
# replaces the healthcheck. State is still not written here.
###############################################################################

deploy_installed_code_version()
{
    local version_file="${NEXTCLOUD_HTML_DIR}/version.php"
    local value=""

    if [[ -f "${version_file}" ]]; then
        value="$(nextcloud_version_string_from_php "${version_file}")" || value=""
    fi
    printf '%s\n' "${value}"
}

deploy_assert_recover_allowed()
{
    local pg_disk="$1"
    local containers
    local version_php=""
    local nextcloud_image=""
    local postgres_image=""
    local occ_installed=""
    local occ_version=""
    local occ_maintenance=""
    local occ_needs_db=""
    local live_pg=""
    local decision

    containers="$(deploy_stack_presence)"
    version_php="$(deploy_installed_code_version)"

    if [[ "${containers}" != "absent" ]]; then
        nextcloud_image="$(deploy_container_image "${NEXTCLOUD_APP_CONTAINER}")" \
            || fail "The Nextcloud container image could not be read. State files were not written."
        postgres_image="$(deploy_container_image "${POSTGRESQL_CONTAINER}")" \
            || fail "The PostgreSQL container image could not be read. State files were not written."
    fi

    if [[ "${containers}" == "running" ]]; then
        occ_installed="$(nextcloud_occ_status_value installed 2>/dev/null || true)"
        occ_version="$(nextcloud_occ_status_value versionstring 2>/dev/null || true)"
        occ_maintenance="$(nextcloud_occ_status_value maintenance 2>/dev/null || true)"
        occ_needs_db="$(nextcloud_occ_status_value needsDbUpgrade 2>/dev/null || true)"
        live_pg="$(post_deploy_postgres_major 2>/dev/null || true)"
    fi

    decision="$(
        deploy_missing_evidence_decision \
            "${version_php}" \
            "${pg_disk}" \
            "$(env_get NEXTCLOUD_TAG)" \
            "$(env_get POSTGRES_IMAGE)" \
            "${containers}" \
            "${nextcloud_image}" \
            "${postgres_image}" \
            "${occ_installed}" \
            "${occ_version}" \
            "${occ_maintenance}" \
            "${occ_needs_db}" \
            "${live_pg}" \
            "$(env_get NEXTCLOUD_IMAGE):$(env_get NEXTCLOUD_TAG)"
    )" || fail "${decision}"

    [[ "${decision}" == "allow" ]] \
        || fail "Unexpected recovery decision: ${decision}"

    ok "Existing installation matches the pinned Nextcloud and PostgreSQL."
}

###############################################################################
# Write installed-version and postgres-major only after the running
# install has been checked. Complete matching evidence is not rewritten.
# A different recorded value is left in place and deploy stops.
###############################################################################

deploy_record_verified_install()
{
    local installed_state
    local postgres_state
    local version_php=""
    local pg_disk=""
    local disk_status=0
    local occ_installed=""
    local occ_version=""
    local occ_maintenance=""
    local occ_needs_db=""
    local live_pg=""
    local cron_health=""
    local config_flag="no"
    local decision
    local pg_dir

    installed_state="$(deploy_state_file_value "${INSTALLED_VERSION_FILE}")"
    postgres_state="$(deploy_state_file_value "${POSTGRES_MAJOR_FILE}")"

    if nextcloud_config_marked_installed \
        "${NEXTCLOUD_HTML_DIR}/config/config.php"
    then
        config_flag="yes"
    fi

    version_php="$(deploy_installed_code_version)"

    pg_dir="$(env_get POSTGRESQL_HOST_DIR)"
    pg_disk="$(postgres_major_from_data_dir "${pg_dir}")" || disk_status=$?
    if [[ "${disk_status}" -eq 2 ]]; then
        fail "More than one PG_VERSION file is under ${pg_dir}. State files were not written."
    fi
    if [[ "${disk_status}" -eq 3 ]]; then
        fail "PG_VERSION under ${pg_dir} is not a PostgreSQL major. State files were not written."
    fi
    if [[ "${disk_status}" -eq 4 ]]; then
        fail "PostgreSQL data under ${pg_dir} has no single readable major. State files were not written."
    fi
    if [[ "${disk_status}" -ne 0 ]]; then
        pg_disk=""
    fi

    occ_installed="$(nextcloud_occ_status_value installed 2>/dev/null || true)"
    occ_version="$(nextcloud_occ_status_value versionstring 2>/dev/null || true)"
    occ_maintenance="$(nextcloud_occ_status_value maintenance 2>/dev/null || true)"
    occ_needs_db="$(nextcloud_occ_status_value needsDbUpgrade 2>/dev/null || true)"
    live_pg="$(post_deploy_postgres_major 2>/dev/null || true)"
    cron_health="$(post_deploy_health_status "${NEXTCLOUD_CRON_CONTAINER}" 2>/dev/null || true)"

    decision="$(
        deploy_evidence_write_decision \
            "${config_flag}" \
            "${occ_installed}" \
            "${occ_version}" \
            "${occ_maintenance}" \
            "${occ_needs_db}" \
            "${version_php}" \
            "${live_pg}" \
            "${pg_disk}" \
            "$(env_get NEXTCLOUD_TAG)" \
            "$(env_get POSTGRES_IMAGE)" \
            "${cron_health}" \
            "${installed_state}" \
            "${postgres_state}"
    )" || fail "${decision}"

    if [[ "${decision}" == "unchanged" ]]; then
        ok "Installed Nextcloud tag and PostgreSQL major are already recorded."
        return 0
    fi

    [[ "${decision}" == "record" ]] \
        || fail "Unexpected evidence decision: ${decision}"

    state_write_installed "$(env_get NEXTCLOUD_TAG)" "${live_pg}" \
        || fail "Could not record the installed version. The previous evidence was left in place."

    ok "Installed version recorded as $(env_get NEXTCLOUD_TAG)."
}
