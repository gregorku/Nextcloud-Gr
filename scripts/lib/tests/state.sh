#!/usr/bin/env bash

###############################################################################
#
# Nextcloud-Gr Project
#
# Install-state decisions, post-deploy failures and atomic state writes.
# Temporary directories and function stubs only. Docker is not called.
#
###############################################################################

state_record_decision()
{
    local config="$1"
    local installed_state="$2"
    local postgres_state="$3"
    local lock="$4"
    local containers="$5"
    local version_php="$6"
    local pg_disk="$7"
    local nextcloud_image="$8"
    local postgres_image="$9"
    local occ_version="${10}"
    local live_pg="${11}"

    record_installed_decision \
        "${config}" \
        "${installed_state}" \
        "${postgres_state}" \
        "${lock}" \
        "35.0.2-fpm" \
        "docker.io/library/postgres:18.6" \
        "${version_php}" \
        "${pg_disk}" \
        "${containers}" \
        "${nextcloud_image}" \
        "${postgres_image}" \
        "${occ_version}" \
        "${live_pg}" \
        "docker.io/library/nextcloud:35.0.2-fpm"
}

state_assert_no_compose()
{
    local events="$1"

    if [[ -f "${events}" ]] && grep -Eq '^(pull|up)$' "${events}"; then
        fail "Compose was started: $(paste -sd, "${events}")"
    fi
}

state_post_deploy_stubs()
{
    local work="$1"

    deploy_upgrade_lock_decision() { return 0; }
    require_directory() { return 0; }
    require_container_running() { return 0; }

    env_get()
    {
        case "$1" in
            NEXTCLOUD_TAG) printf '35.0.2-fpm\n' ;;
            NEXTCLOUD_IMAGE) printf 'docker.io/library/nextcloud\n' ;;
            POSTGRES_IMAGE) printf 'docker.io/library/postgres:18.6\n' ;;
            POSTGRESQL_HOST_DIR) printf '%s\n' "${work}/pg" ;;
            NEXTCLOUD_DATA_HOST_DIR) printf '%s\n' "${work}/data" ;;
            NEXTCLOUD_BACKEND_BIND) printf '192.0.2.10\n' ;;
            NEXTCLOUD_BACKEND_PORT) printf '8080\n' ;;
            *)
                printf 'unexpected env %s\n' "$1" >&2
                return 1
                ;;
        esac
    }

    post_deploy_health_status() { printf 'healthy\n'; }
    post_deploy_sleep() { printf 'slept\n' >> "${work}/sleep"; }

    post_deploy_container_image()
    {
        case "$1" in
            "${NEXTCLOUD_APP_CONTAINER}")
                printf 'docker.io/library/nextcloud:35.0.2-fpm\n'
                ;;
            "${POSTGRESQL_CONTAINER}")
                printf 'docker.io/library/postgres:18.6\n'
                ;;
            *)
                return 1
                ;;
        esac
    }

    nextcloud_occ_status_value()
    {
        case "$1" in
            installed) printf 'true\n' ;;
            versionstring) printf '35.0.2\n' ;;
            needsDbUpgrade) printf 'false\n' ;;
            maintenance) printf 'false\n' ;;
            *) return 1 ;;
        esac
    }

    nextcloud_occ() { printf '\\OC\\Memcache\\APCu\n'; }

    post_deploy_status_body()
    {
        printf '%s\n' '{"installed":true,"maintenance":false}'
    }

    post_deploy_published_ports()
    {
        printf '192.0.2.10:8080->80/tcp\n'
    }

    post_deploy_postgres_major() { printf '18\n'; }
    postgres_major_from_data_dir() { printf '18\n'; }

    state_write_installed()
    {
        printf '%s %s\n' "$1" "$2" > "${work}/wrote"
    }
}

test_install_state()
{
    print_section "Install state"

    local root
    local work
    local config
    local lock
    local events
    local message
    local status
    local version_file
    local major_file
    local left

    root="$(cd "${SCRIPT_DIR}/.." && pwd)"

    if grep -n 'record_installed' "${root}/scripts/deploy.sh"; then
        fail "deploy.sh adopts an existing installation."
    fi

    work="$(mktemp -d)"
    config="${work}/config.php"
    lock="${work}/upgrade.lock"
    events="${work}/events"
    printf '<?php\n' > "${config}"

    message="$(state_record_decision "${work}/missing.php" missing missing "${work}/no-lock" absent 35.0.2 18 "" "" "" "")" \
        || true
    [[ "${message}" == *"not an existing installation"* ]] \
        || fail "A clean install was offered for recording: ${message}"
    [[ "${message}" == *"deploy.sh"* ]] \
        || fail "A clean install was not sent to deploy.sh: ${message}"

    status=0
    message="$(
        compose_pull() { printf 'pull\n' >> "${events}"; }
        compose_up() { printf 'up\n' >> "${events}"; }
        post_deploy_checks() { printf 'post\n' >> "${events}"; }
        state_write_installed() { printf 'wrote\n' >> "${events}"; }
        record_installed_from_facts \
            "${work}/missing.php" \
            missing \
            missing \
            "${work}/no-lock" \
            35.0.2-fpm \
            docker.io/library/postgres:18.6 \
            "" \
            "" \
            absent \
            "" \
            "" \
            "" \
            "" \
            docker.io/library/nextcloud:35.0.2-fpm \
            2>&1
    )" || status=$?
    [[ "${status}" -ne 0 ]] \
        || fail "Recording a clean install succeeded."
    state_assert_no_compose "${events}"

    : > "${events}"
    message="$(state_record_decision "${config}" missing missing "${work}/no-lock" absent 35.0.2 18 "" "" "" "")" \
        || fail "Matching on-disk evidence was refused: ${message}"
    [[ "${message}" == "start-then-verify" ]] \
        || fail "Stopped matching install decision was ${message}."

    status=0
    (
        compose_pull() { printf 'pull\n' >> "${events}"; }
        compose_up() { printf 'up\n' >> "${events}"; }
        post_deploy_checks() { printf 'post\n' >> "${events}"; return 1; }
        state_write_installed() { printf 'wrote\n' >> "${events}"; }
        record_installed_from_facts \
            "${config}" \
            missing \
            missing \
            "${work}/no-lock" \
            35.0.2-fpm \
            docker.io/library/postgres:18.6 \
            35.0.2 \
            18 \
            absent \
            "" \
            "" \
            "" \
            "" \
            docker.io/library/nextcloud:35.0.2-fpm
    ) >/dev/null || status=$?
    [[ "${status}" -ne 0 ]] \
        || fail "A failed post-deploy after a safe start was treated as recorded."
    [[ "$(paste -sd, "${events}")" == "pull,up,post" ]] \
        || fail "Safe start order was $(paste -sd, "${events}" 2>/dev/null)."

    : > "${events}"
    status=0
    message="$(
        compose_pull() { printf 'pull\n' >> "${events}"; }
        compose_up() { printf 'up\n' >> "${events}"; }
        post_deploy_checks() { printf 'post\n' >> "${events}"; }
        record_installed_from_facts \
            "${config}" \
            missing \
            missing \
            "${work}/no-lock" \
            35.0.2-fpm \
            docker.io/library/postgres:18.6 \
            34.0.1 \
            18 \
            absent \
            "" \
            "" \
            "" \
            "" \
            docker.io/library/nextcloud:35.0.2-fpm \
            2>&1
    )" || status=$?
    [[ "${status}" -ne 0 ]] \
        || fail "A different on-disk Nextcloud version was started."
    [[ "${message}" == *"Refusing to start a different version"* ]] \
        || fail "Version mismatch did not refuse the start: ${message}"
    state_assert_no_compose "${events}"

    : > "${events}"
    status=0
    message="$(
        compose_pull() { printf 'pull\n' >> "${events}"; }
        compose_up() { printf 'up\n' >> "${events}"; }
        record_installed_from_facts \
            "${config}" \
            missing \
            missing \
            "${work}/no-lock" \
            35.0.2-fpm \
            docker.io/library/postgres:18.6 \
            35.0.2 \
            16 \
            absent \
            "" \
            "" \
            "" \
            "" \
            docker.io/library/nextcloud:35.0.2-fpm \
            2>&1
    )" || status=$?
    [[ "${status}" -ne 0 ]] \
        || fail "A different PostgreSQL major was started."
    [[ "${message}" == *"different major"* ]] \
        || fail "PostgreSQL major mismatch was unclear: ${message}"
    state_assert_no_compose "${events}"

    : > "${events}"
    status=0
    message="$(
        compose_pull() { printf 'pull\n' >> "${events}"; }
        compose_up() { printf 'up\n' >> "${events}"; }
        record_installed_from_facts \
            "${config}" \
            missing \
            missing \
            "${work}/no-lock" \
            35.0.2-fpm \
            docker.io/library/postgres:18.6 \
            "" \
            18 \
            absent \
            "" \
            "" \
            "" \
            "" \
            docker.io/library/nextcloud:35.0.2-fpm \
            2>&1
    )" || status=$?
    [[ "${status}" -ne 0 ]] \
        || fail "Missing version.php was allowed to start."
    [[ "${message}" == *"will not start Compose"* ]] \
        || fail "Missing version.php had no remediation: ${message}"
    state_assert_no_compose "${events}"

    status=0
    message="$(state_record_decision "${config}" 34.0.5-fpm missing "${work}/no-lock" absent 34.0.5 18 "" "" "" "")" \
        || status=$?
    [[ "${status}" -ne 0 ]] \
        || fail "A different recorded Nextcloud tag was overwritten."
    [[ "${message}" == *"upgrade.sh"* ]] \
        || fail "Recorded tag mismatch did not point at upgrade.sh: ${message}"

    status=0
    message="$(state_record_decision "${config}" 35.0.2-fpm 16 "${work}/no-lock" absent 35.0.2 18 "" "" "" "")" \
        || status=$?
    [[ "${status}" -ne 0 ]] \
        || fail "A recorded PostgreSQL major change was allowed."
    [[ "${message}" == *"separate migration"* ]] \
        || fail "Recorded PostgreSQL mismatch was unclear: ${message}"

    printf 'running\n' > "${lock}"
    status=0
    message="$(state_record_decision "${config}" missing missing "${lock}" absent 35.0.2 18 "" "" "" "")" \
        || status=$?
    [[ "${status}" -ne 0 ]] \
        || fail "An upgrade lock was ignored."
    [[ "${message}" == *"Upgrade lock"* ]] \
        || fail "Upgrade lock message was unclear: ${message}"
    rm -f "${lock}"

    message="$(deploy_upgrade_lock_decision "${work}/no-lock")" \
        || fail "A missing upgrade lock was refused."
    status=0
    message="$(deploy_upgrade_lock_decision "${work}/no-lock-dir/upgrade.lock")" || status=$?
    [[ "${status}" -eq 0 ]] \
        || fail "A missing upgrade lock path was refused: ${message}"
    printf 'failed\n' > "${lock}"
    status=0
    message="$(deploy_upgrade_lock_decision "${lock}")" || status=$?
    [[ "${status}" -ne 0 ]] \
        || fail "deploy.sh lock decision ignored the lock."

    message="$(state_record_decision "${config}" 35.0.2-fpm 18 "${work}/no-lock" running 35.0.2 18 \
        docker.io/library/nextcloud:35.0.2-fpm \
        docker.io/library/postgres:18.6 \
        35.0.2 18)" \
        || fail "Complete evidence was not treated as already recorded: ${message}"
    [[ "${message}" == "already-recorded" ]] \
        || fail "Repeat deploy decision was ${message}."

    : > "${events}"
    (
        compose_pull() { printf 'pull\n' >> "${events}"; }
        compose_up() { printf 'up\n' >> "${events}"; }
        post_deploy_checks() { printf 'post\n' >> "${events}"; }
        state_write_installed() { printf 'wrote\n' >> "${events}"; }
        record_installed_from_facts \
            "${config}" \
            35.0.2-fpm \
            18 \
            "${work}/no-lock" \
            35.0.2-fpm \
            docker.io/library/postgres:18.6 \
            35.0.2 \
            18 \
            running \
            docker.io/library/nextcloud:35.0.2-fpm \
            docker.io/library/postgres:18.6 \
            35.0.2 \
            18 \
            docker.io/library/nextcloud:35.0.2-fpm
    ) >/dev/null || fail "Already recorded evidence returned an error."
    [[ ! -s "${events}" ]] \
        || fail "Already recorded evidence rewrote state or started Compose: $(paste -sd, "${events}")"

    : > "${events}"
    (
        compose_pull() { printf 'pull\n' >> "${events}"; }
        compose_up() { printf 'up\n' >> "${events}"; }
        post_deploy_checks() { printf 'post\n' >> "${events}"; }
        record_installed_from_facts \
            "${config}" \
            missing \
            missing \
            "${work}/no-lock" \
            35.0.2-fpm \
            docker.io/library/postgres:18.6 \
            35.0.2 \
            18 \
            running \
            nextcloud:35.0.2-fpm \
            postgres:18.6 \
            35.0.2 \
            18 \
            docker.io/library/nextcloud:35.0.2-fpm
    ) >/dev/null || fail "A running matching install was refused."
    [[ "$(paste -sd, "${events}")" == "post" ]] \
        || fail "Running install should only be verified, got $(paste -sd, "${events}")."

    status=0
    message="$(state_record_decision "${config}" missing missing "${work}/no-lock" running 35.0.2 18 \
        docker.io/library/nextcloud:36.0.0-fpm \
        docker.io/library/postgres:18.6 \
        36.0.0 18)" || status=$?
    [[ "${status}" -ne 0 ]] \
        || fail "A different running image was accepted."
    [[ "${message}" == *"will not recreate"* ]] \
        || fail "Running image mismatch had no remediation: ${message}"

    status=0
    message="$(state_record_decision "${config}" missing missing "${work}/no-lock" partial 35.0.2 18 "" "" "" "")" \
        || status=$?
    [[ "${status}" -ne 0 ]] \
        || fail "A partial stack was accepted."

    status=0
    message="$(state_record_decision "${config}" missing missing "${work}/no-lock" stopped 35.0.2 18 \
        docker.io/library/nextcloud:34.0.5-fpm \
        docker.io/library/postgres:18.6 \
        "" "")" || status=$?
    [[ "${status}" -ne 0 ]] \
        || fail "A stopped container with another image was recreated."
    [[ "${message}" == *"will not recreate"* ]] \
        || fail "Stopped image mismatch had no remediation: ${message}"

    status=0
    message="$(state_record_decision "${config}" missing missing "${work}/no-lock" running 36.0.0 18 \
        docker.io/library/nextcloud:35.0.2-fpm \
        docker.io/library/postgres:18.6 \
        35.0.2 18)" || status=$?
    [[ "${status}" -ne 0 ]] \
        || fail "Disagreeing version.php and occ were recorded."
    [[ "${message}" == *"disagree"* ]] \
        || fail "Code and occ disagreement was unclear: ${message}"

    printf '18\n' > "${work}/pg"
    message="$(deploy_postgres_major_decision "${work}/pg" "docker.io/library/postgres:18.6" 18)" \
        || fail "A matching data directory was refused: ${message}"
    [[ "${message}" == "unchanged" ]] \
        || fail "Matching PostgreSQL evidence was ${message}."

    message="$(deploy_postgres_major_decision "${work}/missing-major" "docker.io/library/postgres:18.6" 18)" \
        || fail "Unrecorded matching PostgreSQL data was refused: ${message}"
    [[ "${message}" == "unrecorded" ]] \
        || fail "Missing postgres-major with matching data was ${message}."

    message="$(deploy_postgres_major_decision "${work}/missing-major" "docker.io/library/postgres:18.6")" \
        || fail "A first PostgreSQL install was refused: ${message}"
    [[ "${message}" == "first" ]] \
        || fail "PostgreSQL without data was ${message}."

    status=0
    message="$(deploy_postgres_major_decision "${work}/missing-major" "docker.io/library/postgres:18.6" 16)" \
        || status=$?
    [[ "${status}" -ne 0 ]] \
        || fail "A different PostgreSQL data major was treated as a first install."
    [[ "${message}" == *"different major"* ]] \
        || fail "Data major refusal was unclear: ${message}"

    status=0
    message="$(deploy_postgres_major_decision "${work}/pg" "docker.io/library/postgres:18.6" 16)" \
        || status=$?
    [[ "${status}" -ne 0 ]] \
        || fail "PG_VERSION was allowed to disagree with the state file."

    printf '%s\n' '<?php' '$OC_VersionString = '"'"'35.0.2'"'"';' > "${work}/version.php"
    message="$(nextcloud_version_string_from_php "${work}/version.php")" \
        || fail "version.php could not be read."
    [[ "${message}" == "35.0.2" ]] \
        || fail "version.php parsed as ${message}."

    printf '%s\n' '<?php' '$OC_VersionString = '"'"'stable'"'"';' > "${work}/version.php"
    if nextcloud_version_string_from_php "${work}/version.php" >/dev/null; then
        fail "A non-release version.php was accepted."
    fi

    mkdir -p "${work}/pgdata/18/docker"
    printf '18\n' > "${work}/pgdata/18/docker/PG_VERSION"
    message="$(postgres_major_from_data_dir "${work}/pgdata")" \
        || fail "PG_VERSION could not be read."
    [[ "${message}" == "18" ]] \
        || fail "PG_VERSION parsed as ${message}."

    mkdir -p "${work}/pgdata/16/docker"
    printf '16\n' > "${work}/pgdata/16/docker/PG_VERSION"
    status=0
    postgres_major_from_data_dir "${work}/pgdata" >/dev/null || status=$?
    [[ "${status}" -eq 2 ]] \
        || fail "Two PG_VERSION files returned status ${status}."

    mkdir -p "${work}/badpg/18/docker"
    printf 'eighteen\n' > "${work}/badpg/18/docker/PG_VERSION"
    status=0
    postgres_major_from_data_dir "${work}/badpg" >/dev/null || status=$?
    [[ "${status}" -eq 3 ]] \
        || fail "An unreadable PG_VERSION returned status ${status}."

    mkdir -p "${work}/emptypg"
    status=0
    postgres_major_from_data_dir "${work}/emptypg" >/dev/null || status=$?
    [[ "${status}" -eq 1 ]] \
        || fail "An empty PostgreSQL directory returned status ${status}."

    mkdir -p "${work}/foreignpg/data"
    printf '16\n' > "${work}/foreignpg/data/PG_VERSION"
    status=0
    postgres_major_from_data_dir "${work}/foreignpg" >/dev/null || status=$?
    [[ "${status}" -eq 4 ]] \
        || fail "Unrecognized PostgreSQL data returned status ${status}."

    status=0
    postgres_major_from_data_dir "${work}/missing-pg" >/dev/null || status=$?
    [[ "${status}" -eq 1 ]] \
        || fail "A missing PostgreSQL directory returned status ${status}."

    mkdir -p "${work}/dotpg/.hidden/docker"
    printf '18\n' > "${work}/dotpg/.hidden/docker/PG_VERSION"
    status=0
    postgres_major_from_data_dir "${work}/dotpg" >/dev/null || status=$?
    [[ "${status}" -eq 4 ]] \
        || fail "A hidden PG_VERSION returned status ${status}."

    mkdir -p "${work}/lockedpg/18/docker"
    printf '18\n' > "${work}/lockedpg/18/docker/PG_VERSION"
    chmod 000 "${work}/lockedpg/18/docker/PG_VERSION"
    status=0
    postgres_major_from_data_dir "${work}/lockedpg" >/dev/null || status=$?
    chmod 644 "${work}/lockedpg/18/docker/PG_VERSION"
    if [[ "${EUID}" -eq 0 ]]; then
        [[ "${status}" -eq 0 ]] \
            || fail "Root could not read mode 000 PG_VERSION, status ${status}."
    else
        [[ "${status}" -eq 4 ]] \
            || fail "An unreadable PG_VERSION file returned status ${status}."
    fi

    message="$(deploy_on_disk_code_decision "${work}/no-version.php" "35.0.2-fpm")" \
        || fail "Missing version.php was refused: ${message}"
    [[ "${message}" == "absent" ]] \
        || fail "Missing version.php decision was ${message}."

    printf '%s\n' '<?php' '$OC_VersionString = '"'"'35.0.2'"'"';' > "${work}/code.php"
    message="$(deploy_on_disk_code_decision "${work}/code.php" "35.0.2-fpm")" \
        || fail "Matching on-disk code was refused: ${message}"
    [[ "${message}" == "match" ]] \
        || fail "Matching on-disk code decision was ${message}."

    printf '%s\n' '<?php' '$OC_VersionString = '"'"'34.0.5'"'"';' > "${work}/code.php"
    status=0
    message="$(deploy_on_disk_code_decision "${work}/code.php" "35.0.2-fpm")" || status=$?
    [[ "${status}" -ne 0 ]] \
        || fail "Different on-disk code was allowed to start."
    [[ "${message}" == *"Refusing to start a different version"* ]] \
        || fail "Different on-disk code was unclear: ${message}"

    printf '%s\n' '<?php' '$OC_VersionString = '"'"'stable'"'"';' > "${work}/code.php"
    status=0
    message="$(deploy_on_disk_code_decision "${work}/code.php" "35.0.2-fpm")" || status=$?
    [[ "${status}" -ne 0 ]] \
        || fail "Unreadable version.php was allowed to start."
    [[ "${message}" == *"unreadable"* ]] \
        || fail "Unreadable version.php was unclear: ${message}"

    image_reference_matches "nextcloud:35.0.2-fpm" "docker.io/library/nextcloud:35.0.2-fpm" \
        || fail "A short Nextcloud image reference was rejected."
    if image_reference_matches "nextcloud:36.0.0-fpm" "docker.io/library/nextcloud:35.0.2-fpm"; then
        fail "A different image tag matched."
    fi

    : > "${work}/installed-version"
    status=0
    message="$(deploy_version_decision "${work}/installed-version" "${config}" "35.0.2-fpm")" || status=$?
    [[ "${status}" -ne 0 ]] \
        || fail "An empty installed-version file was accepted."
    [[ "${message}" == *"empty"* ]] \
        || fail "An empty installed-version file was not described: ${message}"

    version_file="${work}/state/installed-version"
    major_file="${work}/state/postgres-major"
    mkdir -p "${work}/state"
    printf '35.0.2-fpm\n' > "${version_file}"
    printf '17\n' > "${major_file}"

    status=0
    (
        mv()
        {
            if [[ "${3:-}" == "${version_file}" ]]; then
                return 1
            fi
            command mv "$@"
        }
        state_write_installed "36.0.0-fpm" "18" "${version_file}" "${major_file}"
    ) || status=$?
    [[ "${status}" -ne 0 ]] \
        || fail "A failed version rename was treated as recorded."
    [[ "$(tr -d '[:space:]' < "${version_file}")" == "35.0.2-fpm" ]] \
        || fail "A failed rename replaced installed-version."
    [[ "$(tr -d '[:space:]' < "${major_file}")" == "17" ]] \
        || fail "A failed rename replaced postgres-major."
    left="$(find "${work}/state" -name '.state.*' -print)"
    [[ -z "${left}" ]] \
        || fail "A failed rename left ${left}."

    rm -rf "${work}/state"
    state_write_installed "35.0.2-fpm" "18" "${version_file}" "${major_file}" \
        || fail "Atomic state write failed."
    [[ "$(tr -d '[:space:]' < "${version_file}")" == "35.0.2-fpm" ]] \
        || fail "installed-version contents were $(cat "${version_file}")."
    [[ "$(tr -d '[:space:]' < "${major_file}")" == "18" ]] \
        || fail "postgres-major contents were $(cat "${major_file}")."
    [[ "$(stat -c '%a' "${version_file}")" == "600" ]] \
        || fail "installed-version mode is $(stat -c '%a' "${version_file}")."
    [[ "$(stat -c '%a' "${major_file}")" == "600" ]] \
        || fail "postgres-major mode is $(stat -c '%a' "${major_file}")."
    [[ "$(stat -c '%a' "${work}/state")" == "700" ]] \
        || fail "State directory mode is $(stat -c '%a' "${work}/state")."

    if state_write_file "${work}/state/bad" $'35.0.2\n36.0.0'; then
        fail "A multi-line state value was written."
    fi
    [[ ! -f "${work}/state/bad" ]] \
        || fail "A rejected state value created a file."

    rm -f "${work}/wrote"
    status=0
    (
        state_post_deploy_stubs "${work}"
        POST_DEPLOY_HEALTH_ATTEMPTS=1
        post_deploy_health_status() { printf 'unhealthy\n'; }
        post_deploy_checks
    ) >"${work}/health.out" 2>&1 || status=$?
    [[ "${status}" -ne 0 ]] \
        || fail "An unhealthy container passed post-deploy."
    [[ "$(cat "${work}/health.out")" == *"health status is 'unhealthy'"* ]] \
        || fail "Health failure was unclear: $(cat "${work}/health.out")"
    [[ ! -f "${work}/wrote" ]] \
        || fail "A failed healthcheck wrote state."

    rm -f "${work}/sleep" "${work}/health-calls"
    (
        post_deploy_health_status()
        {
            local seen=0

            if [[ -f "${work}/health-calls" ]]; then
                seen="$(tr -d '[:space:]' < "${work}/health-calls")"
            fi
            seen=$((seen + 1))
            printf '%s\n' "${seen}" > "${work}/health-calls"

            if [[ "${seen}" -eq 1 ]]; then
                printf 'starting\n'
                return 0
            fi
            printf 'healthy\n'
        }
        post_deploy_sleep() { printf 'slept\n' >> "${work}/sleep"; }
        POST_DEPLOY_HEALTH_ATTEMPTS=3
        POST_DEPLOY_HEALTH_DELAY=1
        post_deploy_wait_healthy
    ) >/dev/null || fail "A healthcheck that became healthy was rejected."
    [[ -s "${work}/sleep" ]] \
        || fail "post-deploy did not wait for a starting healthcheck."

    rm -f "${work}/wrote"
    status=0
    (
        state_post_deploy_stubs "${work}"
        nextcloud_occ_status_value()
        {
            case "$1" in
                installed) printf 'false\n' ;;
                *) return 1 ;;
            esac
        }
        post_deploy_checks
    ) >"${work}/install.out" 2>&1 || status=$?
    [[ "${status}" -ne 0 ]] \
        || fail "An unfinished installation was recorded."
    [[ "$(cat "${work}/install.out")" == *"not installed yet"* ]] \
        || fail "Unfinished installation was unclear: $(cat "${work}/install.out")"
    [[ "$(cat "${work}/install.out")" == *"State files were not written"* ]] \
        || fail "Unfinished installation did not say state was kept."
    [[ ! -f "${work}/wrote" ]] \
        || fail "An unfinished installation wrote state."

    rm -f "${work}/wrote"
    status=0
    (
        state_post_deploy_stubs "${work}"
        nextcloud_occ_status_value()
        {
            case "$1" in
                installed) printf 'true\n' ;;
                versionstring) printf '34.0.5\n' ;;
                maintenance) printf 'false\n' ;;
                *) return 1 ;;
            esac
        }
        post_deploy_checks
    ) >"${work}/version.out" 2>&1 || status=$?
    [[ "${status}" -ne 0 ]] \
        || fail "A mismatched occ version was recorded."
    [[ "$(cat "${work}/version.out")" == *"expected 35.0.2"* ]] \
        || fail "occ mismatch was unclear: $(cat "${work}/version.out")"
    [[ ! -f "${work}/wrote" ]] \
        || fail "A mismatched occ version wrote state."

    rm -f "${work}/wrote"
    status=0
    (
        state_post_deploy_stubs "${work}"
        nextcloud_occ_status_value()
        {
            case "$1" in
                installed) printf 'true\n' ;;
                versionstring) printf '35.0.2\n' ;;
                needsDbUpgrade) printf 'true\n' ;;
                maintenance) printf 'false\n' ;;
                *) return 1 ;;
            esac
        }
        post_deploy_checks
    ) >"${work}/upgrade-db.out" 2>&1 || status=$?
    [[ "${status}" -ne 0 ]] \
        || fail "A pending database upgrade was recorded."
    [[ "$(cat "${work}/upgrade-db.out")" == *"needs a database upgrade"* ]] \
        || fail "Pending database upgrade was unclear: $(cat "${work}/upgrade-db.out")"
    [[ ! -f "${work}/wrote" ]] \
        || fail "A pending database upgrade wrote state."

    rm -f "${work}/wrote"
    status=0
    (
        state_post_deploy_stubs "${work}"
        post_deploy_published_ports()
        {
            printf '192.0.2.10:8080->80/tcp, 0.0.0.0:5432->5432/tcp\n'
        }
        post_deploy_checks
    ) >"${work}/ports.out" 2>&1 || status=$?
    [[ "${status}" -ne 0 ]] \
        || fail "A published database port passed post-deploy."
    [[ "$(cat "${work}/ports.out")" == *"published"* ]] \
        || fail "Published port failure was unclear: $(cat "${work}/ports.out")"
    [[ ! -f "${work}/wrote" ]] \
        || fail "A failed post-deploy check wrote state."

    rm -f "${work}/wrote"
    status=0
    (
        state_post_deploy_stubs "${work}"
        deploy_upgrade_lock_decision()
        {
            printf 'Upgrade lock %s is present. Finish or clear the failed upgrade before deploy.sh.\n' "$1"
            return 1
        }
        post_deploy_checks
    ) >"${work}/lock.out" 2>&1 || status=$?
    [[ "${status}" -ne 0 ]] \
        || fail "post-deploy ignored the upgrade lock."
    [[ ! -f "${work}/wrote" ]] \
        || fail "post-deploy wrote state while the upgrade lock existed."

    rm -f "${work}/wrote"
    (
        state_post_deploy_stubs "${work}"
        post_deploy_checks
    ) >"${work}/ok.out" 2>&1 || fail "A healthy matching install was rejected: $(cat "${work}/ok.out")"
    [[ "$(cat "${work}/wrote")" == "35.0.2-fpm 18" ]] \
        || fail "State writer was called as $(cat "${work}/wrote" 2>/dev/null)."
    [[ "$(cat "${work}/ok.out")" == *"Installed version recorded as 35.0.2-fpm."* ]] \
        || fail "Successful post-deploy did not record the tag: $(cat "${work}/ok.out")"

    rm -rf "${work}"

    ok "Install state is recorded only after the running checks pass."
}

###############################################################################
# Recovery of missing installed-version and postgres-major.
# Temporary directories and stubs only. Docker is not called.
###############################################################################

test_evidence_recovery()
{
    print_section "Evidence recovery"

    local root
    local work
    local config
    local message
    local status
    local nc_image="docker.io/library/nextcloud:35.0.2-fpm"
    local pg_image="docker.io/library/postgres:18.6"

    root="$(cd "${SCRIPT_DIR}/.." && pwd)"
    source "${SCRIPT_DIR}/lib/deploy/version-guard.sh"

    grep -q 'deploy_record_verified_install' \
        "${root}/scripts/lib/deploy/compose.sh" \
        || fail "Deploy does not record evidence after a verified install."
    grep -q 'deploy_assert_recover_allowed' \
        "${root}/scripts/lib/deploy/version-guard.sh" \
        || fail "Deploy does not verify an existing installation before Compose."
    if grep -n 'record_installed_run' "${root}/scripts/deploy.sh"; then
        fail "deploy.sh starts the record-installed command."
    fi

    work="$(mktemp -d)"
    config="${work}/config.php"

    # 1. New installation: no config and no state.
    message="$(deploy_version_decision "${work}/installed-version" "${work}/missing.php" "35.0.2-fpm")" \
        || fail "A new installation was refused: ${message}"
    [[ "${message}" == "first-install" ]] \
        || fail "A new installation was ${message}."
    status=0
    message="$(deploy_evidence_write_decision \
        no "" "" "" "" "" "" "" \
        35.0.2-fpm "${pg_image}" healthy missing missing)" || status=$?
    [[ "${status}" -ne 0 ]] \
        || fail "A new installation was recorded before it existed."
    [[ "${message}" == *"not a finished installation"* ]] \
        || fail "An unfinished config was recorded: ${message}"

    # 2. Existing installation with both state files.
    printf '%s\n' '<?php' "'installed' => true," > "${config}"
    printf '35.0.2-fpm\n' > "${work}/installed-version"
    message="$(deploy_version_decision "${work}/installed-version" "${config}" "35.0.2-fpm")" \
        || fail "Complete evidence was refused: ${message}"
    [[ "${message}" == "unchanged" ]] \
        || fail "Complete evidence was ${message}."
    message="$(deploy_evidence_write_decision \
        yes true 35.0.2 false false 35.0.2 18 18 \
        35.0.2-fpm "${pg_image}" healthy 35.0.2-fpm 18)" \
        || fail "Complete evidence was not left unchanged: ${message}"
    [[ "${message}" == "unchanged" ]] \
        || fail "Complete evidence decision was ${message}."

    # 3. Installed, missing installed-version, running facts match.
    rm -f "${work}/installed-version"
    message="$(deploy_version_decision "${work}/installed-version" "${config}" "35.0.2-fpm")" \
        || fail "Missing installed-version was refused before verification: ${message}"
    [[ "${message}" == "recover" ]] \
        || fail "Missing installed-version was ${message}."
    message="$(deploy_missing_evidence_decision \
        35.0.2 18 35.0.2-fpm "${pg_image}" running \
        "${nc_image}" "${pg_image}" \
        true 35.0.2 false false 18 "${nc_image}")" \
        || fail "A matching running installation was refused: ${message}"
    [[ "${message}" == "allow" ]] \
        || fail "Matching recovery was ${message}."
    message="$(deploy_evidence_write_decision \
        yes true 35.0.2 false false 35.0.2 18 18 \
        35.0.2-fpm "${pg_image}" healthy missing 18)" \
        || fail "Missing installed-version was not recorded: ${message}"
    [[ "${message}" == "record" ]] \
        || fail "Missing installed-version write was ${message}."

    # 4. installed-version present, postgres-major missing.
    printf '18\n' > "${work}/pg"
    message="$(deploy_postgres_major_decision "${work}/missing-major" "${pg_image}" 18)" \
        || fail "Matching unrecorded PostgreSQL data was refused: ${message}"
    [[ "${message}" == "unrecorded" ]] \
        || fail "Missing postgres-major was ${message}."
    message="$(deploy_evidence_write_decision \
        yes true 35.0.2 false false 35.0.2 18 18 \
        35.0.2-fpm "${pg_image}" healthy 35.0.2-fpm missing)" \
        || fail "Missing postgres-major was not recorded: ${message}"
    [[ "${message}" == "record" ]] \
        || fail "Missing postgres-major write was ${message}."

    # 5. Nextcloud code does not match the pin.
    status=0
    message="$(deploy_missing_evidence_decision \
        34.0.5 18 35.0.2-fpm "${pg_image}" running \
        "${nc_image}" "${pg_image}" \
        true 34.0.5 false false 18 "${nc_image}")" || status=$?
    [[ "${status}" -ne 0 ]] \
        || fail "A different Nextcloud version was allowed."
    [[ "${message}" == *"different version"* ]] \
        || fail "Nextcloud mismatch was unclear: ${message}"
    status=0
    message="$(deploy_evidence_write_decision \
        yes true 34.0.5 false false 34.0.5 18 18 \
        35.0.2-fpm "${pg_image}" healthy missing missing)" || status=$?
    [[ "${status}" -ne 0 ]] \
        || fail "A different occ version was recorded."

    # 6. PostgreSQL cluster major does not match the image.
    status=0
    message="$(deploy_missing_evidence_decision \
        35.0.2 16 35.0.2-fpm "${pg_image}" stopped \
        "" "" "" "" "" "" "" "${nc_image}")" || status=$?
    [[ "${status}" -ne 0 ]] \
        || fail "A different PostgreSQL major was allowed."
    [[ "${message}" == *"different major"* ]] \
        || fail "PostgreSQL mismatch was unclear: ${message}"
    status=0
    message="$(deploy_evidence_write_decision \
        yes true 35.0.2 false false 35.0.2 16 16 \
        35.0.2-fpm "${pg_image}" healthy missing missing)" || status=$?
    [[ "${status}" -ne 0 ]] \
        || fail "A different running PostgreSQL major was recorded."

    # 7. config.php exists but the installation is not finished.
    printf '<?php\n' > "${config}"
    message="$(deploy_version_decision "${work}/installed-version" "${config}" "35.0.2-fpm")" \
        || fail "An unfinished config.php was refused: ${message}"
    [[ "${message}" == "unfinished" ]] \
        || fail "An unfinished config.php was ${message}."
    status=0
    message="$(deploy_missing_evidence_decision \
        35.0.2 18 35.0.2-fpm "${pg_image}" running \
        "${nc_image}" "${pg_image}" \
        false 35.0.2 false false 18 "${nc_image}")" || status=$?
    [[ "${status}" -ne 0 ]] \
        || fail "occ installed:false was treated as a finished install."
    [[ "${message}" == *"maintenance:install"* ]] \
        || fail "An incomplete install had no refusal: ${message}"

    # 8. PostgreSQL data outside the Nextcloud directory.
    mkdir -p "${work}/nextcloud-gr" "${work}/postgresql-data/data/18/docker"
    printf '16\n' > "${work}/nextcloud-gr/PG_VERSION"
    printf '18\n' > "${work}/postgresql-data/data/18/docker/PG_VERSION"
    message="$(postgres_major_from_data_dir "${work}/postgresql-data/data")" \
        || fail "PG_VERSION outside the Nextcloud directory was not read: ${message}"
    [[ "${message}" == "18" ]] \
        || fail "The PostgreSQL data directory parsed as ${message}."
    status=0
    postgres_major_from_data_dir "${work}/nextcloud-gr" >/dev/null || status=$?
    [[ "${status}" -eq 4 ]] \
        || fail "A PG_VERSION file outside the cluster layout returned ${status}."
    message="$(postgres_major_from_version_text "postgres (PostgreSQL) 18.6 (Debian 18.6-1)")" \
        || fail "postgres -V text was not read."
    [[ "${message}" == "18" ]] \
        || fail "postgres -V parsed as ${message}."

    # 9. Unhealthy cron does not receive evidence. A shell is not crond.
    status=0
    message="$(deploy_evidence_write_decision \
        yes true 35.0.2 false false 35.0.2 18 18 \
        35.0.2-fpm "${pg_image}" unhealthy missing missing)" || status=$?
    [[ "${status}" -ne 0 ]] \
        || fail "An unhealthy cron was recorded."
    [[ "${message}" == *"Cron health is unhealthy"* ]] \
        || fail "Unhealthy cron was unclear: ${message}"
    if cron_pid1_is_crond "$(printf '/bin/sh\0/cron.sh\0' | tr '\0' ' ')"; then
        fail "cron.sh as PID 1 was accepted."
    fi
    cron_pid1_is_crond "$(printf 'busybox\0crond\0-f\0-L\0/dev/stdout\0' | tr '\0' ' ')" \
        || fail "busybox crond was rejected."

    # 10. occ or the database cannot be verified.
    status=0
    message="$(deploy_missing_evidence_decision \
        35.0.2 18 35.0.2-fpm "${pg_image}" running \
        "${nc_image}" "${pg_image}" \
        "" "" "" "" "" "${nc_image}")" || status=$?
    [[ "${status}" -ne 0 ]] \
        || fail "A failed occ status was accepted."
    [[ "${message}" == *"occ status failed"* ]] \
        || fail "Failed occ was unclear: ${message}"
    status=0
    message="$(deploy_missing_evidence_decision \
        35.0.2 18 35.0.2-fpm "${pg_image}" running \
        "${nc_image}" "${pg_image}" \
        true 35.0.2 false false "" "${nc_image}")" || status=$?
    [[ "${status}" -ne 0 ]] \
        || fail "An unreadable running PostgreSQL major was accepted."
    status=0
    message="$(deploy_evidence_write_decision \
        yes true 35.0.2 false true 35.0.2 18 18 \
        35.0.2-fpm "${pg_image}" healthy missing missing)" || status=$?
    [[ "${status}" -ne 0 ]] \
        || fail "needsDbUpgrade was recorded."
    [[ "${message}" == *"database upgrade"* ]] \
        || fail "needsDbUpgrade was unclear: ${message}"

    status=0
    message="$(deploy_evidence_write_decision \
        yes true 35.0.2 false false 35.0.2 18 18 \
        35.0.2-fpm "${pg_image}" healthy 36.0.0-fpm missing)" || status=$?
    [[ "${status}" -ne 0 ]] \
        || fail "A different installed-version was overwritten."
    [[ "${message}" == *"Refusing to overwrite"* ]] \
        || fail "Overwrite refusal was unclear: ${message}"

    status=0
    message="$(deploy_missing_evidence_decision \
        35.0.2 18 35.0.2-fpm "${pg_image}" partial \
        "" "" "" "" "" "" "" "${nc_image}")" || status=$?
    [[ "${status}" -ne 0 ]] \
        || fail "A partial stack was recovered."

    status=0
    message="$(deploy_missing_evidence_decision \
        35.0.2 18 35.0.2-fpm "${pg_image}" running \
        nextcloud:36.0.0-fpm "${pg_image}" \
        true 35.0.2 false false 18 "${nc_image}")" || status=$?
    [[ "${status}" -ne 0 ]] \
        || fail "A different running image was recreated."
    [[ "${message}" == *"will not recreate"* ]] \
        || fail "Image mismatch had no refusal: ${message}"

    # The writer calls state_write only for a verified record decision.
    rm -f "${work}/wrote"
    (
        deploy_state_file_value() { printf 'missing\n'; }
        deploy_installed_code_version() { printf '35.0.2\n'; }
        nextcloud_config_marked_installed() { return 0; }
        nextcloud_occ_status_value()
        {
            case "$1" in
                installed) printf 'true\n' ;;
                versionstring) printf '35.0.2\n' ;;
                maintenance) printf 'false\n' ;;
                needsDbUpgrade) printf 'false\n' ;;
                *) return 1 ;;
            esac
        }
        postgres_major_from_data_dir() { printf '18\n'; }
        post_deploy_postgres_major() { printf '18\n'; }
        post_deploy_health_status() { printf 'healthy\n'; }
        env_get()
        {
            case "$1" in
                NEXTCLOUD_TAG) printf '35.0.2-fpm\n' ;;
                POSTGRES_IMAGE) printf '%s\n' "${pg_image}" ;;
                POSTGRESQL_HOST_DIR) printf '%s\n' "${work}/postgresql-data/data" ;;
                *) return 1 ;;
            esac
        }
        state_write_installed() { printf '%s %s\n' "$1" "$2" > "${work}/wrote"; }
        deploy_record_verified_install
    ) >"${work}/record.out" 2>&1 || fail "A verified install was not recorded: $(cat "${work}/record.out")"
    [[ "$(cat "${work}/wrote")" == "35.0.2-fpm 18" ]] \
        || fail "Recorded evidence was $(cat "${work}/wrote" 2>/dev/null)."

    rm -f "${work}/wrote"
    status=0
    (
        deploy_state_file_value() { printf 'missing\n'; }
        deploy_installed_code_version() { printf '35.0.2\n'; }
        nextcloud_config_marked_installed() { return 0; }
        nextcloud_occ_status_value()
        {
            case "$1" in
                installed) printf 'true\n' ;;
                versionstring) printf '35.0.2\n' ;;
                maintenance) printf 'false\n' ;;
                needsDbUpgrade) printf 'false\n' ;;
                *) return 1 ;;
            esac
        }
        postgres_major_from_data_dir() { printf '18\n'; }
        post_deploy_postgres_major() { printf '18\n'; }
        post_deploy_health_status() { printf 'unhealthy\n'; }
        env_get()
        {
            case "$1" in
                NEXTCLOUD_TAG) printf '35.0.2-fpm\n' ;;
                POSTGRES_IMAGE) printf '%s\n' "${pg_image}" ;;
                POSTGRESQL_HOST_DIR) printf '%s\n' "${work}/postgresql-data/data" ;;
                *) return 1 ;;
            esac
        }
        state_write_installed() { printf '%s %s\n' "$1" "$2" > "${work}/wrote"; }
        deploy_record_verified_install
    ) >"${work}/cron.out" 2>&1 || status=$?
    [[ "${status}" -ne 0 ]] \
        || fail "An unhealthy cron passed the evidence writer."
    [[ ! -f "${work}/wrote" ]] \
        || fail "An unhealthy cron wrote state."

    rm -rf "${work}"

    ok "Missing evidence is recorded only when the installation matches."
}
