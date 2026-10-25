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
#   major. record-installed.sh uses it to recover missing evidence
#   without treating an existing install as a first installation.
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
# Prints "unchanged" or "first-install" on success. On failure prints
# the operator message and returns 1.
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
            printf 'config.php exists but %s does not. This is an existing installation, not a first install. deploy.sh will not start Compose and will not write state files. If the stack is already running the pinned images, run ./scripts/post-deploy.sh. If it is not running, run ./scripts/record-installed.sh --confirm %s. That command reads the deployed code and PG_VERSION without this state file and starts the pinned images only when they already match that data.\n' \
                "${installed_file}" \
                "${STACK_NAME}"
            return 1
        fi

        printf 'unfinished\n'
        return 0
    fi

    printf 'first-install\n'
    return 0
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
