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
#   major.
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
        printf 'config.php exists but %s does not. Refusing to start an image that might migrate the database. Run ./scripts/post-deploy.sh when the running version already matches %s.\n' \
            "${installed_file}" \
            "${intended}"
        return 1
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
#
###############################################################################

deploy_postgres_major_decision()
{
    local recorded_file="$1"
    local image="$2"
    local image_major
    local recorded

    image_major="$(postgres_image_major "${image}")" || {
        printf 'POSTGRES_IMAGE %s is not an exact major.minor tag.\n' "${image}"
        return 1
    }

    if [[ ! -f "${recorded_file}" ]]; then
        printf 'first\n'
        return 0
    fi

    recorded="$(tr -d '[:space:]' < "${recorded_file}")"

    if [[ "${recorded}" == "${image_major}" ]]; then
        printf 'unchanged\n'
        return 0
    fi

    printf 'PostgreSQL major on disk is %s and POSTGRES_IMAGE is major %s. Change of database major is a separate migration, not upgrade.sh.\n' \
        "${recorded}" \
        "${image_major}"
    return 1
}
