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
    status=0
    message="$(deploy_version_decision "${installed}" "${config}" "35.0.2-fpm")" || status=$?
    [[ "${status}" -ne 0 ]] \
        || fail "Existing config.php without a version file was allowed."

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
