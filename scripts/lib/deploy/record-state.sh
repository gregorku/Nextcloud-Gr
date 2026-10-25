#!/usr/bin/env bash

###############################################################################
#
# Nextcloud-Gr Project
#
# File:
#   scripts/lib/deploy/record-state.sh
#
# Description:
#   Decide whether missing installed-version evidence can be recovered.
#   deploy.sh does not call this. The command does not write state
#   itself: post-deploy.sh writes it after the running checks pass.
#   Compose is started only when the on-disk code and PostgreSQL major
#   already match the pins and the containers are not running.
#
###############################################################################

###############################################################################
# Arguments:
#   $1  - config.php path
#   $2  - installed-version contents, "missing", or "empty"
#   $3  - postgres-major contents, "missing", or "empty"
#   $4  - upgrade lock path
#   $5  - NEXTCLOUD_TAG
#   $6  - POSTGRES_IMAGE
#   $7  - version.php OC_VersionString, or empty
#   $8  - PG_VERSION major, or empty
#   $9  - running, partial, stopped or absent
#   $10 - nextcloud container image, or empty
#   $11 - postgres container image, or empty
#   $12 - occ versionstring, or empty
#   $13 - live PostgreSQL major, or empty
#   $14 - expected nextcloud image reference
#
# Prints already-recorded, verify-running or start-then-verify.
#
###############################################################################

record_installed_decision()
{
    local config_php="$1"
    local installed_state="$2"
    local postgres_state="$3"
    local upgrade_lock="$4"
    local intended="$5"
    local pg_image="$6"
    local version_php="$7"
    local pg_disk="$8"
    local containers="$9"
    local nextcloud_image="${10}"
    local postgres_image="${11}"
    local occ_version="${12}"
    local live_pg="${13}"
    local expected_image="${14}"
    local expected
    local image_major
    local lock_message

    [[ "$#" -eq 14 ]] || {
        printf 'record_installed_decision expects 14 arguments.\n'
        return 1
    }

    if ! lock_message="$(deploy_upgrade_lock_decision "${upgrade_lock}")"; then
        printf '%s\n' "${lock_message}"
        return 1
    fi

    if [[ ! -f "${config_php}" ]]; then
        printf 'config.php does not exist. This is not an existing installation. Run ./scripts/deploy.sh. State files are written by ./scripts/post-deploy.sh only after Nextcloud is installed. This command does not create them.\n'
        return 1
    fi

    if ! expected="$(upgrade_release_number "${intended}")"; then
        printf 'NEXTCLOUD_TAG %s is not an exact X.Y.Z-fpm release.\n' "${intended}"
        return 1
    fi

    image_major="$(postgres_image_major "${pg_image}")" || {
        printf 'POSTGRES_IMAGE %s is not an exact major.minor tag.\n' "${pg_image}"
        return 1
    }

    if [[ "${installed_state}" == "empty" || "${postgres_state}" == "empty" ]]; then
        printf 'A state file exists but is empty. Refusing to overwrite it. State files were not written.\n'
        return 1
    fi

    if [[ "${installed_state}" != "missing" && "${installed_state}" != "${intended}" ]]; then
        printf 'Installed Nextcloud tag is %s and NEXTCLOUD_TAG is %s. Refusing to overwrite evidence. Run ./scripts/upgrade.sh --target %s --confirm %s.\n' \
            "${installed_state}" \
            "${intended}" \
            "${intended}" \
            "${STACK_NAME}"
        return 1
    fi

    if [[ "${postgres_state}" != "missing" && "${postgres_state}" != "${image_major}" ]]; then
        printf 'PostgreSQL major on disk is %s and POSTGRES_IMAGE is major %s. Change of database major is a separate migration, not upgrade.sh.\n' \
            "${postgres_state}" \
            "${image_major}"
        return 1
    fi

    if [[ "${installed_state}" != "missing" && "${postgres_state}" != "missing" ]]; then
        printf 'already-recorded\n'
        return 0
    fi

    case "${containers}" in
        partial)
            printf 'Only some stack containers are running. This command will not start or recreate the others. State files were not written.\n'
            return 1
            ;;
        running)
            if ! image_reference_matches "${nextcloud_image}" "${expected_image}"; then
                printf 'The running Nextcloud image is %s. Expected %s. occ versionstring is %s. This command will not recreate the container. State files were not written.\n' \
                    "${nextcloud_image:-unknown}" \
                    "${expected_image}" \
                    "${occ_version:-unknown}"
                return 1
            fi

            if ! image_reference_matches "${postgres_image}" "${pg_image}"; then
                printf 'The running PostgreSQL image is %s. Expected %s. This command will not recreate the container. State files were not written.\n' \
                    "${postgres_image:-unknown}" \
                    "${pg_image}"
                return 1
            fi

            if [[ -z "${occ_version}" ]]; then
                printf 'The stack is running but occ did not report versionstring. State files were not written. Wait until Nextcloud is installed, then run ./scripts/post-deploy.sh.\n'
                return 1
            fi

            if [[ "${occ_version}" != "${expected}" ]]; then
                printf 'occ versionstring is %s and NEXTCLOUD_TAG is %s. Refusing to record a different version. Pin NEXTCLOUD_TAG to %s-fpm, run ./scripts/update-env.sh, then run ./scripts/record-installed.sh --confirm %s. State files were not written.\n' \
                    "${occ_version}" \
                    "${intended}" \
                    "${occ_version}" \
                    "${STACK_NAME}"
                return 1
            fi

            if [[ -z "${version_php}" ]]; then
                printf 'version.php was not found. The running image and occ report %s. Refusing to record state without the on-disk code version. State files were not written.\n' \
                    "${occ_version}"
                return 1
            fi

            if [[ "${version_php}" != "${occ_version}" ]]; then
                printf 'version.php says %s and occ says %s. Refusing to record a version while the code and the installed application disagree. State files were not written.\n' \
                    "${version_php}" \
                    "${occ_version}"
                return 1
            fi

            if [[ -z "${live_pg}" ]]; then
                printf 'The stack is running but the PostgreSQL major could not be read. State files were not written.\n'
                return 1
            fi

            if [[ "${live_pg}" != "${image_major}" ]]; then
                printf 'Running PostgreSQL is major %s and POSTGRES_IMAGE is major %s. Refusing to record a different major. State files were not written.\n' \
                    "${live_pg}" \
                    "${image_major}"
                return 1
            fi

            if [[ -z "${pg_disk}" ]]; then
                printf 'PG_VERSION was not found in the PostgreSQL data directory. The running server reports major %s. Refusing to record state without the data directory major. State files were not written.\n' \
                    "${live_pg}"
                return 1
            fi

            if [[ "${pg_disk}" != "${live_pg}" ]]; then
                printf 'PostgreSQL data directory is major %s and the running server is major %s. State files were not written.\n' \
                    "${pg_disk}" \
                    "${live_pg}"
                return 1
            fi

            printf 'verify-running\n'
            return 0
            ;;
        stopped|absent)
            if [[ -n "${nextcloud_image}" ]] && ! image_reference_matches "${nextcloud_image}" "${expected_image}"; then
                printf 'Container %s exists with image %s, expected %s. This command will not recreate it. State files were not written.\n' \
                    "${NEXTCLOUD_APP_CONTAINER}" \
                    "${nextcloud_image}" \
                    "${expected_image}"
                return 1
            fi

            if [[ -n "${postgres_image}" ]] && ! image_reference_matches "${postgres_image}" "${pg_image}"; then
                printf 'Container %s exists with image %s, expected %s. This command will not recreate it. State files were not written.\n' \
                    "${POSTGRESQL_CONTAINER}" \
                    "${postgres_image}" \
                    "${pg_image}"
                return 1
            fi

            if [[ -z "${version_php}" ]]; then
                printf 'Containers are not running and version.php has no Nextcloud version. This command will not start Compose and will not write state files. Restore the HTML directory, or run ./scripts/post-deploy.sh if the stack is already running the pinned images.\n'
                return 1
            fi

            if [[ "${version_php}" != "${expected}" ]]; then
                printf 'Nextcloud code in version.php is %s and NEXTCLOUD_TAG is %s. Refusing to start a different version over existing data. Set NEXTCLOUD_TAG to %s-fpm, run ./scripts/update-env.sh, then run ./scripts/record-installed.sh --confirm %s. Do not run deploy.sh before that. State files were not written.\n' \
                    "${version_php}" \
                    "${intended}" \
                    "${version_php}" \
                    "${STACK_NAME}"
                return 1
            fi

            if [[ -z "${pg_disk}" ]]; then
                printf 'Containers are not running and PG_VERSION was not found. This command will not start Compose and will not write state files.\n'
                return 1
            fi

            if [[ "${pg_disk}" != "${image_major}" ]]; then
                printf 'PostgreSQL data directory is major %s and POSTGRES_IMAGE is major %s. Refusing to start a different major over existing data. This stack accepts the pinned major only. A major change is a separate migration. State files were not written.\n' \
                    "${pg_disk}" \
                    "${image_major}"
                return 1
            fi

            printf 'start-then-verify\n'
            return 0
            ;;
        *)
            printf 'Unexpected container state: %s\n' "${containers}"
            return 1
            ;;
    esac
}

record_installed_act()
{
    local decision="$1"

    case "${decision}" in
        already-recorded)
            ok "Installed Nextcloud tag and PostgreSQL major are already recorded."
            ;;
        verify-running)
            info "The running images match the pins. Recording state after post-deploy checks."
            post_deploy_checks
            ;;
        start-then-verify)
            info "Nextcloud code and PostgreSQL data match the pins. Starting those images."
            compose_pull
            compose_up
            post_deploy_checks
            ;;
        *)
            fail "Unexpected record decision: ${decision}"
            ;;
    esac
}

record_installed_from_facts()
{
    local decision

    [[ "$#" -eq 14 ]] || fail "record_installed_from_facts expects 14 arguments."

    decision="$(record_installed_decision "$@")" || fail "${decision}"
    record_installed_act "${decision}"
}

record_installed_state_value()
{
    local file="$1"
    local value

    if [[ ! -f "${file}" ]]; then
        printf 'missing\n'
        return 0
    fi

    value="$(tr -d '[:space:]' < "${file}")"
    if [[ -z "${value}" ]]; then
        printf 'empty\n'
        return 0
    fi

    printf '%s\n' "${value}"
}

record_installed_container_set()
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

record_installed_lookup_image()
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
#   $1 - Confirmation stack name
#
###############################################################################

record_installed_run()
{
    local confirm="$1"
    local installed_state
    local postgres_state
    local containers
    local version_php=""
    local pg_disk=""
    local disk_status=0
    local nextcloud_image=""
    local postgres_image=""
    local occ_version=""
    local live_pg=""
    local pg_dir
    local version_file

    [[ "${confirm}" == "${STACK_NAME}" ]] \
        || fail "--confirm must be exactly ${STACK_NAME}."

    installed_state="$(record_installed_state_value "${INSTALLED_VERSION_FILE}")"
    postgres_state="$(record_installed_state_value "${POSTGRES_MAJOR_FILE}")"
    containers="$(record_installed_container_set)"

    version_file="${NEXTCLOUD_HTML_DIR}/version.php"
    if [[ -f "${version_file}" ]]; then
        version_php="$(nextcloud_version_string_from_php "${version_file}")" \
            || fail "version.php has no exact Nextcloud version. Refusing to guess. State files were not written."
    fi

    pg_dir="$(env_get POSTGRESQL_HOST_DIR)"
    pg_disk="$(postgres_major_from_data_dir "${pg_dir}")" || disk_status=$?
    if [[ "${disk_status}" -eq 2 ]]; then
        fail "More than one PG_VERSION file is under ${pg_dir}. Refusing to guess the PostgreSQL major. State files were not written."
    fi
    if [[ "${disk_status}" -eq 3 ]]; then
        fail "PG_VERSION under ${pg_dir} is not a PostgreSQL major. Refusing to guess. State files were not written."
    fi
    if [[ "${disk_status}" -eq 4 ]]; then
        fail "PostgreSQL data under ${pg_dir} has no single readable major. Refusing to start a database image over it. State files were not written."
    fi
    if [[ "${disk_status}" -ne 0 ]]; then
        pg_disk=""
    fi

    if [[ "${containers}" != "absent" ]]; then
        nextcloud_image="$(record_installed_lookup_image "${NEXTCLOUD_APP_CONTAINER}")" \
            || fail "The Nextcloud container image could not be read. State files were not written."
        postgres_image="$(record_installed_lookup_image "${POSTGRESQL_CONTAINER}")" \
            || fail "The PostgreSQL container image could not be read. State files were not written."
    fi

    if [[ "${containers}" == "running" ]]; then
        occ_version="$(nextcloud_occ_status_value versionstring || true)"
        live_pg="$(post_deploy_postgres_major || true)"
    fi

    record_installed_from_facts \
        "${NEXTCLOUD_HTML_DIR}/config/config.php" \
        "${installed_state}" \
        "${postgres_state}" \
        "${UPGRADE_LOCK_FILE}" \
        "$(env_get NEXTCLOUD_TAG)" \
        "$(env_get POSTGRES_IMAGE)" \
        "${version_php}" \
        "${pg_disk}" \
        "${containers}" \
        "${nextcloud_image}" \
        "${postgres_image}" \
        "${occ_version}" \
        "${live_pg}" \
        "$(env_get NEXTCLOUD_IMAGE):$(env_get NEXTCLOUD_TAG)"
}
