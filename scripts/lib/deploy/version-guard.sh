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
#   PostgreSQL major than the one already installed.
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
            info "config.php has no installed flag. The pinned images may start. Deploy does not reinstall Nextcloud and does not delete data directories."
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
            ok "No PostgreSQL data directory yet. The pinned major is recorded after post-deploy.sh."
            ;;
        unrecorded)
            ok "PostgreSQL data matches the pinned major. postgres-major is recorded after post-deploy.sh."
            ;;
        *)
            fail "Unexpected PostgreSQL decision: ${postgres_result}"
            ;;
    esac

    lock_message="$(deploy_upgrade_lock_decision "${UPGRADE_LOCK_FILE}")" \
        || fail "${lock_message}"
}
