#!/usr/bin/env bash

###############################################################################
#
# Nextcloud-Gr Project
#
# File:
#   scripts/lib/upgrade/version.sh
#
# Description:
#   Compare Nextcloud tags and PostgreSQL majors without Docker.
#   deploy.sh uses this to refuse an unnoticed upgrade. upgrade.sh uses
#   it to allow only the next major, or a newer release of the same
#   major. A missing installed-version on an existing installation is
#   "recover": deploy may continue only when the code and PostgreSQL
#   data already match, and it writes the state files only after occ
#   agrees. It does not treat that installation as a first install.
#
###############################################################################

upgrade_tag_parts()
{
    local tag="$1"

    [[ "${tag}" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)-fpm$ ]] || return 1

    printf '%s %s %s\n' \
        "${BASH_REMATCH[1]}" \
        "${BASH_REMATCH[2]}" \
        "${BASH_REMATCH[3]}"
}

upgrade_release_number()
{
    local tag="$1"
    local major minor patch

    IFS=' ' read -r major minor patch <<< "$(upgrade_tag_parts "${tag}")" || return 1
    printf '%s.%s.%s\n' "${major}" "${minor}" "${patch}"
}

###############################################################################
# 0 when target is a later same-major release or exactly the next major.
# 1 for the same tag, a downgrade, a skipped major or a bad tag.
#
# Arguments:
#   $1 - Installed tag
#   $2 - Requested tag
#
###############################################################################

upgrade_step_allowed()
{
    local current="$1"
    local target="$2"
    local current_major current_minor current_patch
    local target_major target_minor target_patch

    IFS=' ' read -r current_major current_minor current_patch <<< "$(upgrade_tag_parts "${current}")" || return 1
    IFS=' ' read -r target_major target_minor target_patch <<< "$(upgrade_tag_parts "${target}")" || return 1

    [[ "${current}" != "${target}" ]] || return 1

    if [[ "${target_major}" -eq "${current_major}" ]]; then
        if [[ "${target_minor}" -gt "${current_minor}" ]]; then
            return 0
        fi
        if [[ "${target_minor}" -eq "${current_minor}" && "${target_patch}" -gt "${current_patch}" ]]; then
            return 0
        fi
        return 1
    fi

    [[ "${target_major}" -eq $((current_major + 1)) ]]
}

postgres_image_major()
{
    local image="$1"

    [[ "${image}" =~ :([0-9]+)\.[0-9]+$ ]] || return 1
    printf '%s\n' "${BASH_REMATCH[1]}"
}

###############################################################################
# Decide whether deploy.sh may start this Nextcloud tag.
#
# Arguments:
#   $1 - installed-version file
#   $2 - config.php path
#   $3 - intended tag
#
# Prints "unchanged", "first-install", "unfinished" or "recover" on
# success. "recover" means config.php is installed and the version
# file is absent. It does not write state and it is not a first
# install. On failure prints the operator message and returns 1.
#
###############################################################################

deploy_version_decision()
{
    local installed_file="$1"
    local config_php="$2"
    local intended="$3"
    local installed

    if ! upgrade_tag_parts "${intended}" >/dev/null; then
        printf 'NEXTCLOUD_TAG %s is not an exact X.Y.Z-fpm release.\n' "${intended}"
        return 1
    fi

    if [[ -f "${installed_file}" ]]; then
        installed="$(tr -d '[:space:]' < "${installed_file}")"

        if [[ -z "${installed}" ]]; then
            printf '%s exists but is empty. Refusing to start or replace it.\n' \
                "${installed_file}"
            return 1
        fi

        if [[ "${installed}" == "${intended}" ]]; then
            printf 'unchanged\n'
            return 0
        fi

        printf 'Installed Nextcloud tag is %s and the intended tag is %s. deploy.sh will not upgrade. Run ./scripts/upgrade.sh --target %s --confirm %s.\n' \
            "${installed}" \
            "${intended}" \
            "${intended}" \
            "${STACK_NAME}"
        return 1
    fi

    if [[ -f "${config_php}" ]]; then
        if nextcloud_config_marked_installed "${config_php}"; then
            printf 'recover\n'
            return 0
        fi

        printf 'unfinished\n'
        return 0
    fi

    printf 'first-install\n'
    return 0
}

###############################################################################
# Read one state file without treating a missing file as empty.
#
# Arguments:
#   $1 - path
#
# Prints missing, empty, or the file contents.
#
###############################################################################

deploy_state_file_value()
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

###############################################################################
# Major from `postgres -V`. The text is passed in so tests do not need
# a server. Example: postgres (PostgreSQL) 18.6 (Debian ...)
#
# Arguments:
#   $1 - version text
#
###############################################################################

postgres_major_from_version_text()
{
    local text="$1"

    [[ "${text}" =~ PostgreSQL\)[[:space:]]+([0-9]+) ]] || return 1
    printf '%s\n' "${BASH_REMATCH[1]}"
}

###############################################################################
# PID 1 of nextcloud:35.0.2-fpm cron is `busybox crond`, because
# /cron.sh replaces itself with that exec. A shell still running
# /cron.sh is not crond.
#
# Arguments:
#   $1 - /proc/1/cmdline with NUL bytes already turned into spaces
#
###############################################################################

cron_pid1_is_crond()
{
    local cmdline="$1"

    [[ "${cmdline}" == *'busybox crond'* ]] || return 1
    [[ "${cmdline}" != *cron.sh* ]] || return 1
    [[ "${cmdline}" != */bin/sh* && "${cmdline}" != */bin/bash* ]] || return 1
    return 0
}

###############################################################################
# May deploy continue when installed-version is missing?
#
# This does not write state. Cron health is intentionally not an input:
# an unhealthy cron must not block the Compose refresh that replaces
# its healthcheck. The write below still requires cron to be healthy.
#
# Arguments:
#   $1  - version.php OC_VersionString, or empty
#   $2  - PG_VERSION major, or empty
#   $3  - NEXTCLOUD_TAG
#   $4  - POSTGRES_IMAGE
#   $5  - running, partial, stopped or absent
#   $6  - nextcloud container image, or empty
#   $7  - postgres container image, or empty
#   $8  - occ installed, or empty when occ failed
#   $9  - occ versionstring, or empty
#   $10 - occ maintenance, or empty
#   $11 - occ needsDbUpgrade, or empty
#   $12 - running PostgreSQL major, or empty
#   $13 - expected nextcloud image reference
#
# Prints allow. On failure prints the operator message and returns 1.
#
###############################################################################

deploy_missing_evidence_decision()
{
    local version_php="$1"
    local pg_disk="$2"
    local intended="$3"
    local pg_image="$4"
    local containers="$5"
    local nextcloud_image="$6"
    local postgres_image="$7"
    local occ_installed="$8"
    local occ_version="$9"
    local occ_maintenance="${10}"
    local occ_needs_db="${11}"
    local live_pg="${12}"
    local expected_image="${13}"
    local expected
    local image_major

    [[ "$#" -eq 13 ]] || {
        printf 'deploy_missing_evidence_decision expects 13 arguments.\n'
        return 1
    }

    if ! expected="$(upgrade_release_number "${intended}")"; then
        printf 'NEXTCLOUD_TAG %s is not an exact X.Y.Z-fpm release. State files were not written.\n' \
            "${intended}"
        return 1
    fi

    image_major="$(postgres_image_major "${pg_image}")" || {
        printf 'POSTGRES_IMAGE %s is not an exact major.minor tag. State files were not written.\n' \
            "${pg_image}"
        return 1
    }

    if [[ -z "${version_php}" ]]; then
        printf 'config.php is installed but version.php has no Nextcloud version. This is not a first install. State files were not written and Compose was not started.\n'
        return 1
    fi

    if [[ "${version_php}" != "${expected}" ]]; then
        printf 'Nextcloud code in version.php is %s and NEXTCLOUD_TAG is %s. Refusing to start a different version over existing data. Set NEXTCLOUD_TAG to %s-fpm and run ./scripts/update-env.sh before deploy.sh. State files were not written.\n' \
            "${version_php}" \
            "${intended}" \
            "${version_php}"
        return 1
    fi

    if [[ -z "${pg_disk}" ]]; then
        printf 'config.php is installed but PG_VERSION was not found under the PostgreSQL data directory. That directory is POSTGRESQL_HOST_DIR, not /docker-data/nextcloud-gr. The cluster file is <major>/docker/PG_VERSION. Refusing to guess or initialize a database. State files were not written.\n'
        return 1
    fi

    if [[ "${pg_disk}" != "${image_major}" ]]; then
        printf 'PostgreSQL data directory is major %s and POSTGRES_IMAGE is major %s. Refusing to start a different major over existing data. State files were not written.\n' \
            "${pg_disk}" \
            "${image_major}"
        return 1
    fi

    case "${containers}" in
        partial)
            printf 'Only some stack containers are running. Refusing to start or recreate the others over an existing installation. State files were not written.\n'
            return 1
            ;;
        running)
            if ! image_reference_matches "${nextcloud_image}" "${expected_image}"; then
                printf 'The running Nextcloud image is %s. Expected %s. This deploy will not recreate it over existing data. State files were not written.\n' \
                    "${nextcloud_image:-unknown}" \
                    "${expected_image}"
                return 1
            fi

            if ! image_reference_matches "${postgres_image}" "${pg_image}"; then
                printf 'The running PostgreSQL image is %s. Expected %s. This deploy will not recreate it over existing data. State files were not written.\n' \
                    "${postgres_image:-unknown}" \
                    "${pg_image}"
                return 1
            fi

            if [[ -z "${occ_installed}" ]]; then
                printf 'occ status failed. config.php says installed, so this is not a first install and maintenance:install will not run. State files were not written.\n'
                return 1
            fi

            if [[ "${occ_installed}" != "true" ]]; then
                printf 'config.php is installed but occ reports installed: %s. Refusing to run maintenance:install and refusing to record state. Nothing was deleted.\n' \
                    "${occ_installed}"
                return 1
            fi

            if [[ "${occ_version}" != "${expected}" || "${version_php}" != "${occ_version}" ]]; then
                printf 'occ versionstring is %s and version.php is %s. NEXTCLOUD_TAG is %s. Refusing to record a different version. State files were not written.\n' \
                    "${occ_version:-unknown}" \
                    "${version_php}" \
                    "${intended}"
                return 1
            fi

            if [[ "${occ_maintenance}" != "false" ]]; then
                printf 'Nextcloud maintenance mode is %s. State files were not written.\n' \
                    "${occ_maintenance:-unknown}"
                return 1
            fi

            if [[ "${occ_needs_db}" != "false" ]]; then
                printf 'Nextcloud still needs a database upgrade. deploy.sh will not record this as the current version and will not upgrade it. State files were not written.\n'
                return 1
            fi

            if [[ -z "${live_pg}" || "${live_pg}" != "${image_major}" || "${live_pg}" != "${pg_disk}" ]]; then
                printf 'Running PostgreSQL is major %s, the data directory is major %s, and POSTGRES_IMAGE is major %s. State files were not written.\n' \
                    "${live_pg:-unknown}" \
                    "${pg_disk}" \
                    "${image_major}"
                return 1
            fi

            printf 'allow\n'
            return 0
            ;;
        stopped|absent)
            if [[ -n "${nextcloud_image}" ]] && ! image_reference_matches "${nextcloud_image}" "${expected_image}"; then
                printf 'Container %s exists with image %s, expected %s. This deploy will not recreate it. State files were not written.\n' \
                    "${NEXTCLOUD_APP_CONTAINER}" \
                    "${nextcloud_image}" \
                    "${expected_image}"
                return 1
            fi

            if [[ -n "${postgres_image}" ]] && ! image_reference_matches "${postgres_image}" "${pg_image}"; then
                printf 'Container %s exists with image %s, expected %s. This deploy will not recreate it. State files were not written.\n' \
                    "${POSTGRESQL_CONTAINER}" \
                    "${postgres_image}" \
                    "${pg_image}"
                return 1
            fi

            printf 'allow\n'
            return 0
            ;;
        *)
            printf 'Unexpected container state: %s. State files were not written.\n' \
                "${containers}"
            return 1
            ;;
    esac
}

###############################################################################
# Decide whether the verified running install may gain state files.
# An existing different value is never replaced. Complete evidence is
# left unchanged. Missing evidence is recorded only when every fact
# matches, including a healthy cron.
#
# Arguments:
#   $1  - yes when config.php has installed => true, otherwise no
#   $2  - occ installed, or empty
#   $3  - occ versionstring, or empty
#   $4  - occ maintenance, or empty
#   $5  - occ needsDbUpgrade, or empty
#   $6  - version.php OC_VersionString, or empty
#   $7  - running PostgreSQL major, or empty
#   $8  - PG_VERSION major, or empty
#   $9  - NEXTCLOUD_TAG
#   $10 - POSTGRES_IMAGE
#   $11 - cron health status, or empty
#   $12 - installed-version contents, missing, or empty
#   $13 - postgres-major contents, missing, or empty
#
# Prints record or unchanged.
#
###############################################################################

deploy_evidence_write_decision()
{
    local config_installed="$1"
    local occ_installed="$2"
    local occ_version="$3"
    local occ_maintenance="$4"
    local occ_needs_db="$5"
    local version_php="$6"
    local live_pg="$7"
    local pg_disk="$8"
    local intended="$9"
    local pg_image="${10}"
    local cron_health="${11}"
    local installed_state="${12}"
    local postgres_state="${13}"
    local expected
    local image_major

    [[ "$#" -eq 13 ]] || {
        printf 'deploy_evidence_write_decision expects 13 arguments.\n'
        return 1
    }

    if [[ "${installed_state}" == "empty" || "${postgres_state}" == "empty" ]]; then
        printf 'A state file exists but is empty. Refusing to overwrite it. State files were not written.\n'
        return 1
    fi

    if ! expected="$(upgrade_release_number "${intended}")"; then
        printf 'NEXTCLOUD_TAG %s is not an exact X.Y.Z-fpm release. State files were not written.\n' \
            "${intended}"
        return 1
    fi

    image_major="$(postgres_image_major "${pg_image}")" || {
        printf 'POSTGRES_IMAGE %s is not an exact major.minor tag. State files were not written.\n' \
            "${pg_image}"
        return 1
    }

    if [[ "${installed_state}" != "missing" && "${installed_state}" != "${intended}" ]]; then
        printf 'Installed Nextcloud tag is %s and the verified tag is %s. Refusing to overwrite evidence. State files were not written.\n' \
            "${installed_state}" \
            "${intended}"
        return 1
    fi

    if [[ "${postgres_state}" != "missing" && "${postgres_state}" != "${image_major}" ]]; then
        printf 'Recorded PostgreSQL major is %s and the verified major is %s. Refusing to overwrite evidence. State files were not written.\n' \
            "${postgres_state}" \
            "${image_major}"
        return 1
    fi

    if [[ "${config_installed}" != "yes" ]]; then
        printf 'config.php is not a finished installation. State files were not written.\n'
        return 1
    fi

    if [[ -z "${occ_installed}" ]]; then
        printf 'occ status failed. State files were not written.\n'
        return 1
    fi

    if [[ "${occ_installed}" != "true" ]]; then
        printf 'occ reports installed: %s. State files were not written. Nothing was deleted.\n' \
            "${occ_installed}"
        return 1
    fi

    if [[ -z "${version_php}" || "${version_php}" != "${expected}" || "${occ_version}" != "${expected}" ]]; then
        printf 'occ versionstring is %s and version.php is %s. NEXTCLOUD_TAG is %s. Refusing to record a different version. State files were not written.\n' \
            "${occ_version:-unknown}" \
            "${version_php:-unknown}" \
            "${intended}"
        return 1
    fi

    if [[ "${occ_maintenance}" != "false" ]]; then
        printf 'Nextcloud maintenance mode is %s. State files were not written.\n' \
            "${occ_maintenance:-unknown}"
        return 1
    fi

    if [[ "${occ_needs_db}" != "false" ]]; then
        printf 'Nextcloud still needs a database upgrade. State files were not written.\n'
        return 1
    fi

    if [[ -z "${live_pg}" || -z "${pg_disk}" || "${live_pg}" != "${image_major}" || "${pg_disk}" != "${live_pg}" ]]; then
        printf 'Running PostgreSQL is major %s, the data directory is major %s, and POSTGRES_IMAGE is major %s. State files were not written.\n' \
            "${live_pg:-unknown}" \
            "${pg_disk:-unknown}" \
            "${image_major}"
        return 1
    fi

    if [[ "${cron_health}" != "healthy" ]]; then
        printf 'Cron health is %s. State files were not written.\n' \
            "${cron_health:-unset}"
        return 1
    fi

    if [[ "${installed_state}" != "missing" && "${postgres_state}" != "missing" ]]; then
        printf 'unchanged\n'
        return 0
    fi

    printf 'record\n'
}

###############################################################################
# PostgreSQL major changes are not part of upgrade.sh.
#
# Arguments:
#   $1 - File containing the recorded major, if it exists
#   $2 - POSTGRES_IMAGE value
#   $3 - Major read from PG_VERSION, or empty when that file is absent
#
# "first" means no state file and no data directory. "unrecorded" means
# the data directory already uses the pinned major but the state file
# is still missing. A different data-directory major is refused.
#
###############################################################################

deploy_postgres_major_decision()
{
    local recorded_file="$1"
    local image="$2"
    local on_disk="${3:-}"
    local image_major
    local recorded

    image_major="$(postgres_image_major "${image}")" || {
        printf 'POSTGRES_IMAGE %s is not an exact major.minor tag.\n' "${image}"
        return 1
    }

    if [[ -n "${on_disk}" && ! "${on_disk}" =~ ^[0-9]+$ ]]; then
        printf 'PostgreSQL data major %s is not a number.\n' "${on_disk}"
        return 1
    fi

    if [[ -f "${recorded_file}" ]]; then
        recorded="$(tr -d '[:space:]' < "${recorded_file}")"

        if [[ -n "${on_disk}" && "${on_disk}" != "${recorded}" ]]; then
            printf 'PostgreSQL data directory is major %s but %s records major %s. Refusing to start.\n' \
                "${on_disk}" \
                "${recorded_file}" \
                "${recorded}"
            return 1
        fi

        if [[ "${recorded}" == "${image_major}" ]]; then
            printf 'unchanged\n'
            return 0
        fi

        printf 'PostgreSQL major on disk is %s and POSTGRES_IMAGE is major %s. Change of database major is a separate migration, not upgrade.sh.\n' \
            "${recorded}" \
            "${image_major}"
        return 1
    fi

    if [[ -n "${on_disk}" ]]; then
        if [[ "${on_disk}" == "${image_major}" ]]; then
            printf 'unrecorded\n'
            return 0
        fi

        printf 'PostgreSQL data directory is major %s and POSTGRES_IMAGE is major %s. Refusing to start a different major over existing data.\n' \
            "${on_disk}" \
            "${image_major}"
        return 1
    fi

    printf 'first\n'
    return 0
}

###############################################################################
# config.php marks a finished Nextcloud installation with installed => true.
# A file without that key is an unfinished install. PHP is not executed.
#
# Arguments:
#   $1 - config.php path
#
###############################################################################

nextcloud_config_marked_installed()
{
    local file="$1"

    [[ -f "${file}" ]] || return 1
    grep -Eq \
        "['\"]installed['\"][[:space:]]*=>[[:space:]]*true" \
        "${file}"
}

###############################################################################
# Point an existing config.php at one database identity.
# Does not add the installed flag and does not remove other lines.
#
# Arguments:
#   $1 - config.php
#   $2 - database name
#   $3 - database user
#   $4 - database password
#   $5 - database host
#
###############################################################################

nextcloud_config_set_database()
{
    local file="$1"
    local db_name="$2"
    local db_user="$3"
    local db_pass="$4"
    local db_host="$5"
    local tmp
    local line
    local key
    local value
    local prefix
    local comma
    local replaced
    local found=0

    [[ -f "${file}" ]] || return 1

    for value in "${db_name}" "${db_user}" "${db_pass}" "${db_host}"
    do
        [[ -n "${value}" && "${value}" != *[\'\"\\]* && "${value}" != *$'\n'* ]] \
            || return 1
    done

    tmp="$(mktemp "$(dirname "${file}")/.config.XXXXXX")" || return 1

    while IFS= read -r line || [[ -n "${line}" ]]
    do
        replaced=0

        for key in dbname dbuser dbpassword dbhost
        do
            if [[ "${line}" =~ ^([[:space:]]*[\'\"]${key}[\'\"][[:space:]]*=\>[[:space:]]*)[\'\"][^\'\"]*[\'\"](,?)[[:space:]]*$ ]]; then
                prefix="${BASH_REMATCH[1]}"
                comma="${BASH_REMATCH[2]}"

                case "${key}" in
                    dbname) value="${db_name}" ;;
                    dbuser) value="${db_user}" ;;
                    dbpassword) value="${db_pass}" ;;
                    dbhost) value="${db_host}" ;;
                esac

                printf "%s'%s'%s\n" "${prefix}" "${value}" "${comma}"
                replaced=1
                found=$((found + 1))
                break
            fi
        done

        if [[ "${replaced}" -eq 0 ]]; then
            printf '%s\n' "${line}"
        fi
    done < "${file}" > "${tmp}"

    if [[ "${found}" -lt 4 ]]; then
        rm -f "${tmp}"
        return 1
    fi

    chown --reference="${file}" "${tmp}" 2>/dev/null || true
    chmod --reference="${file}" "${tmp}" || {
        rm -f "${tmp}"
        return 1
    }
    mv -f "${tmp}" "${file}"
}

###############################################################################
# Decide whether Nextcloud tables already belong to the configured role.
#
# Arguments:
#   $1 - Current owner, empty when oc_* tables do not exist
#   $2 - PG_USER
#
# Prints none, aligned or reassign.
#
###############################################################################

postgres_owner_action()
{
    local owner="$1"
    local desired="$2"

    [[ "${desired}" =~ ^[A-Za-z_][A-Za-z0-9_]{0,62}$ ]] || return 1

    if [[ -z "${owner}" ]]; then
        printf 'none\n'
        return 0
    fi

    [[ "${owner}" =~ ^[A-Za-z_][A-Za-z0-9_]{0,62}$ ]] || return 1

    if [[ "${owner}" == "${desired}" ]]; then
        printf 'aligned\n'
        return 0
    fi

    printf 'reassign\n'
}

###############################################################################
# Read $OC_VersionString from a Nextcloud version.php. No PHP is executed.
#
# Arguments:
#   $1 - version.php path
#
###############################################################################

nextcloud_version_string_from_php()
{
    local file="$1"
    local value

    [[ -f "${file}" ]] || return 1

    value="$(
        sed -n \
            "s/^[[:space:]]*\\\$OC_VersionString[[:space:]]*=[[:space:]]*'\\([0-9][0-9.]*\\)'[[:space:]]*;[[:space:]]*\$/\\1/p" \
            "${file}"
    )"

    [[ "${value}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    printf '%s\n' "${value}"
}

###############################################################################
# Read the single PG_VERSION under a PostgreSQL 18+ data directory.
# Layout is <host>/<major>/docker/PG_VERSION.
#
# Arguments:
#   $1 - POSTGRESQL_HOST_DIR
#
# Returns:
#   0 and prints the major
#   1 when the directory is missing or empty
#   2 when more than one PG_VERSION exists
#   3 when a PG_VERSION file is not a plain major number
#   4 when the directory has data but no single readable major
#
###############################################################################

postgres_major_from_data_dir()
{
    local host_dir="$1"
    local entry
    local path
    local major
    local found=""
    local count=0
    local listing

    [[ -d "${host_dir}" ]] || return 1

    if ! listing="$(ls -A "${host_dir}")"; then
        return 4
    fi

    if [[ -z "${listing}" ]]; then
        return 1
    fi

    for entry in "${host_dir}"/*
    do
        [[ -d "${entry}" ]] || continue
        path="${entry}/docker/PG_VERSION"
        [[ -f "${path}" ]] || continue

        if [[ ! -r "${path}" ]]; then
            return 4
        fi
        major="$(tr -d '[:space:]' < "${path}")" || return 4
        [[ "${major}" =~ ^[0-9]+$ ]] || return 3

        count=$((count + 1))
        found="${major}"
    done

    [[ "${count}" -ne 0 ]] || return 4
    [[ "${count}" -eq 1 ]] || return 2
    printf '%s\n' "${found}"
}

###############################################################################
# Compare a container image reference with the pinned reference.
# Accepts the same name with or without the docker.io/library prefix.
#
# Arguments:
#   $1 - Image reported by Docker
#   $2 - Expected image reference
#
###############################################################################

image_reference_matches()
{
    local actual="$1"
    local expected="$2"
    local short

    [[ -n "${actual}" && -n "${expected}" ]] || return 1
    [[ "${actual}" == "${expected}" ]] && return 0

    short="${expected#docker.io/}"
    [[ "${actual}" == "${short}" ]] && return 0
    [[ "${actual}" == "docker.io/${short}" ]] && return 0

    short="${expected#docker.io/library/}"
    [[ "${actual}" == "${short}" ]] && return 0
    [[ "${actual}" == "library/${short}" ]] && return 0
    [[ "${actual}" == "docker.io/library/${short}" ]] && return 0

    return 1
}

###############################################################################
# Compare Nextcloud code already stored in the HTML volume with the pin.
# A missing version.php is "absent". A different or unreadable file refuses
# the start. deploy.sh calls this before Compose.
#
# Arguments:
#   $1 - version.php path
#   $2 - intended NEXTCLOUD_TAG
#
###############################################################################

deploy_on_disk_code_decision()
{
    local version_php_file="$1"
    local intended="$2"
    local code
    local expected

    if [[ ! -f "${version_php_file}" ]]; then
        printf 'absent\n'
        return 0
    fi

    if ! code="$(nextcloud_version_string_from_php "${version_php_file}")"; then
        printf 'version.php has no exact Nextcloud version. Refusing to start an image over unreadable code.\n'
        return 1
    fi

    if ! expected="$(upgrade_release_number "${intended}")"; then
        printf 'NEXTCLOUD_TAG %s is not an exact X.Y.Z-fpm release.\n' "${intended}"
        return 1
    fi

    if [[ "${code}" != "${expected}" ]]; then
        printf 'Nextcloud code in version.php is %s and NEXTCLOUD_TAG is %s. Refusing to start a different version over existing code.\n' \
            "${code}" \
            "${intended}"
        return 1
    fi

    printf 'match\n'
    return 0
}

###############################################################################
# Arguments:
#   $1 - upgrade lock path
#
# Prints an operator message and returns 1 when the lock exists.
#
###############################################################################

deploy_upgrade_lock_decision()
{
    local lock_file="$1"

    if [[ -f "${lock_file}" ]]; then
        printf 'Upgrade lock %s is present. Finish or clear the failed upgrade before deploy.sh.\n' \
            "${lock_file}"
        return 1
    fi

    return 0
}
