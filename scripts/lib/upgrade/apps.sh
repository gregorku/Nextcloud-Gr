#!/usr/bin/env bash

###############################################################################
#
# Nextcloud-Gr
#
# File:
#   scripts/lib/upgrade/apps.sh
#
# Description:
#   Read enabled app ids from occ app:list and refuse a custom app
#   whose appinfo.xml max-version is below the target major. Bundled
#   apps are replaced by the image and are not judged from the old tree.
#   A custom app without a readable max-version is refused.
#
###############################################################################

upgrade_enabled_app_ids()
{
    local file="$1"
    local enabled="no"
    local line
    local name

    while IFS= read -r line || [[ -n "${line}" ]]
    do
        case "${line}" in
            Enabled:*)
                enabled="yes"
                continue
                ;;
            Disabled:*)
                enabled="no"
                continue
                ;;
        esac

        [[ "${enabled}" == "yes" ]] || continue
        [[ "${line}" =~ ^[[:space:]]*-[[:space:]]*([^:[:space:]]+) ]] || continue
        name="${BASH_REMATCH[1]}"
        printf '%s\n' "${name}"
    done < "${file}"
}

upgrade_appinfo_max_major()
{
    local file="$1"
    local value
    local major

    value="$(
        sed -n 's/.*<nextcloud[[:space:]].*max-version="\([0-9][0-9.]*\)".*/\1/p' "${file}" \
            | head -n 1
    )"

    [[ -n "${value}" ]] || return 1
    major="${value%%.*}"
    [[ "${major}" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "${major}"
}

###############################################################################
# Arguments:
#   $1 - custom_apps directory
#   $2 - target Nextcloud major
#   $3 - file with one enabled app id per line
#
# Prints the reason on failure.
#
###############################################################################

upgrade_custom_apps_allow_major()
{
    local apps_dir="$1"
    local target_major="$2"
    local enabled_file="$3"
    local app
    local info
    local max_major

    [[ "${target_major}" =~ ^[0-9]+$ ]] || return 1
    [[ -f "${enabled_file}" ]] || return 1

    while IFS= read -r app || [[ -n "${app}" ]]
    do
        [[ -n "${app}" ]] || continue
        info="${apps_dir}/${app}/appinfo/appinfo.xml"
        [[ -f "${info}" ]] || continue

        if ! max_major="$(upgrade_appinfo_max_major "${info}")"; then
            printf 'Custom app %s has no readable Nextcloud max-version.\n' "${app}"
            return 1
        fi

        if [[ "${target_major}" -gt "${max_major}" ]]; then
            printf 'Custom app %s supports Nextcloud up to major %s, not %s.\n' \
                "${app}" "${max_major}" "${target_major}"
            return 1
        fi
    done < "${enabled_file}"

    return 0
}
