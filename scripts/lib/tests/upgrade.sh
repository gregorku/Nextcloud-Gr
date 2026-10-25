#!/usr/bin/env bash

###############################################################################
#
# Nextcloud-Gr Project
#
# Version guard, PostgreSQL major and dump-format checks.
# They use temporary files and do not call Docker.
#
###############################################################################

test_version_guard()
{
    print_section "Version guard"

    local work
    local installed
    local config
    local message
    local status

    upgrade_step_allowed "35.0.2-fpm" "35.0.3-fpm" \
        || fail "A same-major patch upgrade was rejected."

    upgrade_step_allowed "35.0.2-fpm" "36.0.0-fpm" \
        || fail "The next major upgrade was rejected."

    if upgrade_step_allowed "35.0.2-fpm" "37.0.0-fpm"; then
        fail "A skipped major was accepted."
    fi

    if upgrade_step_allowed "35.0.2-fpm" "35.0.2-fpm"; then
        fail "The same tag was accepted as an upgrade."
    fi

    if upgrade_step_allowed "35.0.2-fpm" "34.0.5-fpm"; then
        fail "A downgrade was accepted."
    fi

    if upgrade_step_allowed "35.0.2-fpm" "stable-fpm"; then
        fail "A floating tag was accepted."
    fi

    work="$(mktemp -d)"
    installed="${work}/installed-version"
    config="${work}/config.php"

    message="$(deploy_version_decision "${installed}" "${config}" "35.0.2-fpm")" \
        || fail "A first installation was refused: ${message}"
    [[ "${message}" == "first-install" ]] \
        || fail "First installation decision was ${message}."

    printf '35.0.2-fpm\n' > "${installed}"
    message="$(deploy_version_decision "${installed}" "${config}" "35.0.2-fpm")" \
        || fail "An unchanged tag was refused: ${message}"
    [[ "${message}" == "unchanged" ]] \
        || fail "Unchanged decision was ${message}."

    status=0
    message="$(deploy_version_decision "${installed}" "${config}" "36.0.0-fpm")" || status=$?
    [[ "${status}" -ne 0 ]] \
        || fail "A tag change was allowed through deploy."
    [[ "${message}" == *"upgrade.sh"* ]] \
        || fail "The refusal did not point at upgrade.sh: ${message}"

    rm -f "${installed}"
    printf '<?php\n' > "${config}"
    message="$(deploy_version_decision "${installed}" "${config}" "35.0.2-fpm")" \
        || fail "An unfinished config.php was refused: ${message}"
    [[ "${message}" == "unfinished" ]] \
        || fail "A config.php without installed => true was ${message}."

    printf '%s\n' '<?php' "'installed' => true," > "${config}"
    message="$(deploy_version_decision "${installed}" "${config}" "35.0.2-fpm")" \
        || fail "An installed config.php without evidence was refused before verification: ${message}"
    [[ "${message}" == "recover" ]] \
        || fail "Missing installed-version decision was ${message}."
    [[ "${message}" != "first-install" && "${message}" != "unfinished" ]] \
        || fail "An installed config.php was treated as ${message}."

    [[ "$(postgres_owner_action "" "nextcloud")" == "none" ]] \
        || fail "An empty database was not left alone."
    [[ "$(postgres_owner_action "nextcloud" "nextcloud")" == "aligned" ]] \
        || fail "A matching database owner was reassigned."
    [[ "$(postgres_owner_action "oc_admin" "oc_admin11")" == "reassign" ]] \
        || fail "A different table owner was accepted."
    if postgres_owner_action "oc_admin" "oc-admin"; then
        fail "A role name with a hyphen was accepted."
    fi

    printf '%s\n' \
        '<?php' \
        '  '"'"'dbtype'"'"' => '"'"'pgsql'"'"',' \
        '  '"'"'dbname'"'"' => '"'"'nextcloud'"'"',' \
        '  '"'"'dbuser'"'"' => '"'"'oc_admin11'"'"',' \
        '  '"'"'dbpassword'"'"' => '"'"'old-secret'"'"',' \
        '  '"'"'dbhost'"'"' => '"'"'postgresql'"'"',' \
        '  '"'"'version'"'"' => '"'"'35.0.2.2'"'"',' \
        ');' > "${config}"
    nextcloud_config_set_database "${config}" nextcloud nextcloud 'abc+/=' postgresql \
        || fail "config.php database identity was not rewritten."
    grep -q "'dbuser' => 'nextcloud'" "${config}" \
        || fail "config.php still names the old database user."
    grep -q "'dbpassword' => 'abc+/='" "${config}" \
        || fail "config.php password was not updated."
    grep -q "'version' => '35.0.2.2'" "${config}" \
        || fail "config.php version was rewritten."
    if nextcloud_config_marked_installed "${config}"; then
        fail "Rewriting the database identity marked Nextcloud installed."
    fi

    printf '18\n' > "${work}/pg"
    message="$(deploy_postgres_major_decision "${work}/pg" "docker.io/library/postgres:18.6")" \
        || fail "PostgreSQL 18.6 was refused: ${message}"

    status=0
    message="$(deploy_postgres_major_decision "${work}/pg" "docker.io/library/postgres:19.1")" || status=$?
    [[ "${status}" -ne 0 ]] \
        || fail "A PostgreSQL major change was allowed."
    [[ "${message}" == *"separate migration"* ]] \
        || fail "PostgreSQL major refusal was unclear: ${message}"

    rm -rf "${work}"

    ok "Version guard refuses unnoticed upgrades."
}

test_dump_kind()
{
    print_section "Database dump kind"

    local work
    local dump

    work="$(mktemp -d)"
    dump="${work}/db"

    printf 'PGDMP\nnextcloud\n' > "${dump}"
    backup_dump_is_postgres_custom "${dump}" \
        || fail "A PostgreSQL custom dump was rejected."

    printf -- '-- MariaDB dump 10.11\n' > "${dump}"
    if backup_dump_is_postgres_custom "${dump}"; then
        fail "A MariaDB dump was accepted as PostgreSQL."
    fi

    printf 'PGDMP\n-- MariaDB dump\n' > "${dump}"
    if backup_dump_is_postgres_custom "${dump}"; then
        fail "A dump that names MariaDB was accepted."
    fi

    restore_postgres_major_ok "18" "18" "no" \
        || fail "PostgreSQL 18 was rejected."

    if restore_postgres_major_ok "10" "18" "no"; then
        fail "PostgreSQL major 10 was accepted."
    fi

    if restore_postgres_major_ok "10" "18" "yes"; then
        fail "A PostgreSQL major mismatch was allowed by the Nextcloud version flag."
    fi

    rm -rf "${work}"

    ok "MariaDB dumps and foreign PostgreSQL majors are refused."
}

test_storage_guard()
{
    print_section "Storage mount guard"

    local work
    local message

    work="$(mktemp -d)"

    message="$(
        findmnt()
        {
            if [[ "$1" == "-T" && "$2" == "${work}" ]]; then
                printf '/\n'
                return 0
            fi
            return 1
        }

        storage_require_ready_directory "${work}/data" "Nextcloud data" 2>&1
    )" || true

    [[ "${message}" == *"root filesystem"* ]] \
        || fail "A directory on / was accepted: ${message}"

    [[ ! -d "${work}/data" ]] \
        || fail "The refused directory was created."

    rm -rf "${work}"

    ok "Data directories on the root filesystem are refused."
}

test_php_matrix()
{
    print_section "PHP matrix"

    upgrade_php_is_supported 35 "8.5.1" \
        || fail "PHP 8.5.1 was rejected for Nextcloud 35."

    upgrade_php_is_supported 35 "8.3.0" \
        || fail "PHP 8.3.0 was rejected for Nextcloud 35."

    if upgrade_php_is_supported 35 "8.2.28"; then
        fail "PHP 8.2 was accepted for Nextcloud 35."
    fi

    local status=0
    upgrade_php_is_supported 36 "8.5.1" || status=$?
    [[ "${status}" -eq 2 ]] \
        || fail "An unverified Nextcloud major was not refused (status ${status})."

    ok "PHP support is limited to the verified Nextcloud 35 matrix."
}

test_custom_app_compatibility()
{
    print_section "Custom app compatibility"

    local work
    local apps
    local enabled
    local message

    work="$(mktemp -d)"
    apps="${work}/custom_apps"
    enabled="${work}/enabled"
    mkdir -p "${apps}/notes/appinfo" "${apps}/oldapp/appinfo"

    printf '%s\n' \
        '<info><dependencies><nextcloud min-version="30" max-version="35"/></dependencies></info>' \
        > "${apps}/notes/appinfo/appinfo.xml"
    printf '%s\n' \
        '<info><nextcloud min-version="20" max-version="34"/></info>' \
        > "${apps}/oldapp/appinfo/appinfo.xml"

    printf 'notes\nfiles\n' > "${enabled}"
    upgrade_custom_apps_allow_major "${apps}" 35 "${enabled}" \
        || fail "A custom app within its max-version was rejected."

    printf 'oldapp\n' > "${enabled}"
    message="$(upgrade_custom_apps_allow_major "${apps}" 35 "${enabled}" 2>&1)" || true
    [[ "${message}" == *"oldapp"* ]] \
        || fail "An incompatible custom app was accepted: ${message}"

    printf '<info></info>\n' > "${apps}/notes/appinfo/appinfo.xml"
    printf 'notes\n' > "${enabled}"
    if upgrade_custom_apps_allow_major "${apps}" 35 "${enabled}" >/dev/null; then
        fail "A custom app without max-version was accepted."
    fi

    rm -rf "${work}"

    ok "Custom apps outside the target major are refused."
}

test_upgrade_sequence()
{
    print_section "Upgrade sequence"

    local work
    local events
    local status

    work="$(mktemp -d)"
    events="${work}/events"

    (
        upgrade_phase_stop_cron() { printf 'stop\n' >> "${events}"; }
        upgrade_phase_check_apps() { printf 'apps\n' >> "${events}"; }
        upgrade_phase_hold_backup() { printf 'backup\n' >> "${events}"; }
        upgrade_phase_recreate_app() { printf 'app\n' >> "${events}"; }
        upgrade_phase_verify() { printf 'verify\n' >> "${events}"; }
        upgrade_phase_recreate_cron() { printf 'cron\n' >> "${events}"; }
        upgrade_phase_leave_maintenance() { printf 'maintenance-off\n' >> "${events}"; }
        upgrade_phase_start_previous() { printf 'old-image\n' >> "${events}"; }
        upgrade_run_sequence
    ) || fail "The successful upgrade sequence returned an error."

    [[ "$(paste -sd, "${events}")" == "stop,apps,backup,app,verify,cron,maintenance-off" ]] \
        || fail "Upgrade order was $(paste -sd, "${events}")."

    : > "${events}"
    status=0
    (
        upgrade_phase_stop_cron() { printf 'stop\n' >> "${events}"; }
        upgrade_phase_check_apps() { printf 'apps\n' >> "${events}"; }
        upgrade_phase_hold_backup() { printf 'backup\n' >> "${events}"; }
        upgrade_phase_recreate_app() { printf 'app\n' >> "${events}"; }
        upgrade_phase_verify() { printf 'verify\n' >> "${events}"; return 1; }
        upgrade_phase_recreate_cron() { printf 'cron\n' >> "${events}"; }
        upgrade_phase_leave_maintenance() { printf 'maintenance-off\n' >> "${events}"; }
        upgrade_phase_start_previous() { printf 'old-image\n' >> "${events}"; }
        upgrade_run_sequence
    ) || status=$?

    [[ "${status}" -ne 0 ]] \
        || fail "A failed verification was treated as success."

    [[ "$(paste -sd, "${events}")" == "stop,apps,backup,app,verify,stop" ]] \
        || fail "Failed upgrade order was $(paste -sd, "${events}")."

    if grep -qx 'cron' "${events}" || grep -qx 'old-image' "${events}"; then
        fail "A failed upgrade started cron or the previous image."
    fi

    local root
    root="$(cd "${SCRIPT_DIR}/.." && pwd)"

    grep -q 'command:' "${root}/compose/50-cron.yml" \
        || fail "Cron does not set a command."
    grep -Fq -- '- /cron.sh' "${root}/compose/50-cron.yml" \
        || fail "Cron command is not /cron.sh."
    grep -Fq 'NEXTCLOUD_UPDATE: "0"' "${root}/compose/50-cron.yml" \
        || fail "Cron does not set NEXTCLOUD_UPDATE=0."
    if grep -Eq '^[[:space:]]*entrypoint:' "${root}/compose/50-cron.yml"; then
        fail "Cron replaces the image entrypoint."
    fi
    if grep -Eq '^[[:space:]]*entrypoint:|^[[:space:]]*NEXTCLOUD_UPDATE:' \
        "${root}/compose/30-nextcloud-fpm.yml"; then
        fail "The PHP-FPM service overrides the entrypoint or sets NEXTCLOUD_UPDATE."
    fi
    if grep -q 'compose_cmd' "${root}/scripts/upgrade.sh"; then
        fail "upgrade.sh starts containers outside the single sequence."
    fi

    rm -rf "${work}"

    ok "Cron stays stopped until the upgrade is verified."
}
