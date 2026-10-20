#!/usr/bin/env bash

###############################################################################
#
# Nextcloud-Gr Project
#
# File:
#   scripts/upgrade.sh
#
# Description:
#   Upgrade Nextcloud by one major version, or to a newer release of
#   the same major. deploy.sh refuses to do this.
#
# Usage:
#   ./scripts/upgrade.sh --target 35.0.3-fpm --confirm nextcloud-gr
#
# A failed upgrade does not start the previous image. Maintenance mode
# stays on, cron stays stopped, and the upgrade lock stays in place.
#
###############################################################################

set -Eeuo pipefail

umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${SCRIPT_DIR}/config.sh"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/logging.sh"
source "${SCRIPT_DIR}/lib/filesystem.sh"
source "${SCRIPT_DIR}/lib/docker.sh"
source "${SCRIPT_DIR}/lib/docker-compose.sh"
source "${SCRIPT_DIR}/lib/mount.sh"
source "${SCRIPT_DIR}/lib/checks/load.sh"
source "${SCRIPT_DIR}/lib/env/load.sh"
source "${SCRIPT_DIR}/lib/nextcloud/occ.sh"
source "${SCRIPT_DIR}/lib/upgrade/version.sh"

show_help()
{
cat <<EOF
Nextcloud-Gr Project

Usage:

    ./scripts/upgrade.sh --target X.Y.Z-fpm --confirm ${STACK_NAME}
    ./scripts/upgrade.sh --help

Description:

    The target must already be NEXTCLOUD_TAG in the runtime .env.
    Change that pin in Git, run update-env.sh, then run this script.
    deploy.sh will refuse the same pin change.

    The script checks the installed tag, the one-step rule, PHP in
    the target image, free space and service health. It then runs
    backup.sh --hold, recreates only the PHP-FPM container, and
    waits for occ status. Cron is recreated only after that succeeds.

    PostgreSQL major upgrades are refused.

    On failure the previous image is not started. Restore the backup
    named in the error with restore.sh. Remove ${UPGRADE_LOCK_FILE}
    only after that decision.

EOF
}

target=""
confirm=""

while [[ $# -gt 0 ]]
do
    case "$1" in
        --target)
            [[ $# -ge 2 ]] || fail "--target requires a Nextcloud tag."
            target="$2"
            shift 2
            ;;
        --confirm)
            [[ $# -ge 2 ]] || fail "--confirm requires the stack name."
            confirm="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            fail "Unknown option: $1"
            ;;
    esac
done

[[ -n "${target}" ]] || fail "--target is required."
[[ "${confirm}" == "${STACK_NAME}" ]] \
    || fail "--confirm must be exactly ${STACK_NAME}."

upgrade_free_mib()
{
    local path="$1"

    df -Pm "${path}" | awk 'NR == 2 { print $4 }'
}

upgrade_require_space()
{
    local path="$1"
    local label="$2"
    local free
    local minimum

    minimum="$(env_get UPGRADE_MIN_FREE_MB)"
    free="$(upgrade_free_mib "${path}")"

    [[ "${free}" =~ ^[0-9]+$ ]] \
        || fail "Could not read free space for ${label}."

    [[ "${free}" -ge "${minimum}" ]] \
        || fail "${label} has ${free} MiB free. ${minimum} MiB is required before an upgrade."

    ok "${label} has ${free} MiB free."
}

print_header "Nextcloud-Gr upgrade"

check_environment
check_docker_environment
require_command curl
require_command flock

[[ -f "${ENV_FILE}" ]] || fail ".env not found."
env_validate

pinned="$(env_get NEXTCLOUD_TAG)"
[[ "${target}" == "${pinned}" ]] \
    || fail "Target ${target} is not NEXTCLOUD_TAG ${pinned}. Update the Git pin and run update-env.sh first."

[[ -f "${INSTALLED_VERSION_FILE}" ]] \
    || fail "No installed version is recorded. Refusing to guess."

installed="$(tr -d '[:space:]' < "${INSTALLED_VERSION_FILE}")"

upgrade_step_allowed "${installed}" "${target}" \
    || fail "Refusing ${installed} -> ${target}. Move one major at a time, or to a newer release of the same major. Downgrades are refused."

postgres_decision="$(
    deploy_postgres_major_decision \
        "${POSTGRES_MAJOR_FILE}" \
        "$(env_get POSTGRES_IMAGE)"
)" || fail "${postgres_decision}"

[[ "${postgres_decision}" == "unchanged" ]] \
    || fail "PostgreSQL is not yet recorded as major ${POSTGRES_MAJOR}. upgrade.sh will not change database majors."

image="$(env_get NEXTCLOUD_IMAGE)"
info "Pulling ${image}:${target} before maintenance mode."
docker pull "${image}:${target}" >/dev/null

php_version="$(
    docker run --rm --entrypoint php "${image}:${target}" -r 'echo PHP_VERSION;'
)"
[[ "${php_version}" =~ ^8\.(3|4|5)\. ]] \
    || fail "Target image PHP is ${php_version}. Nextcloud 35 requires PHP 8.3, 8.4 or 8.5."
ok "Target image PHP ${php_version}."

upgrade_require_space "$(env_get NEXTCLOUD_DATA_HOST_DIR)" "Nextcloud data"
upgrade_require_space "$(env_get POSTGRESQL_HOST_DIR)" "PostgreSQL"
upgrade_require_space "${BACKUP_LOCAL_DIR}" "Local backups"

for container in \
    "${POSTGRESQL_CONTAINER}" \
    "${REDIS_CONTAINER}" \
    "${NEXTCLOUD_APP_CONTAINER}" \
    "${NGINX_CONTAINER}" \
    "${NEXTCLOUD_CRON_CONTAINER}"
do
    docker_container_running "${container}" \
        || fail "Container is not running: ${container}"
done

backup_require_postgresql()
{
    local status
    status="$(
        docker inspect \
            --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
            "${POSTGRESQL_CONTAINER}"
    )"
    [[ "${status}" == "healthy" ]] || fail "PostgreSQL is ${status}."
}
backup_require_postgresql

mkdir -p "${NEXTCLOUD_STATE_DIR}"
chmod 700 "${NEXTCLOUD_STATE_DIR}"

if [[ -f "${UPGRADE_LOCK_FILE}" ]]; then
    fail "Upgrade lock already exists: ${UPGRADE_LOCK_FILE}"
fi

printf 'running %s -> %s\n' "${installed}" "${target}" > "${UPGRADE_LOCK_FILE}"
chmod 600 "${UPGRADE_LOCK_FILE}"

upgrade_failed()
{
    local status=$?
    trap - EXIT
    if [[ "${status}" -ne 0 ]]; then
        {
            printf 'failed\n'
            printf 'from=%s\n' "${installed}"
            printf 'target=%s\n' "${target}"
            printf 'Do not start the previous image if the database may already be migrated.\n'
            printf 'Restore with ./scripts/restore.sh and docs/upgrade.md.\n'
        } > "${UPGRADE_LOCK_FILE}"
        warn "Upgrade failed. Maintenance mode and cron were left as backup.sh --hold set them when the backup succeeded."
        warn "The previous Nextcloud image was not started."
    fi
    exit "${status}"
}

trap 'upgrade_failed' EXIT

info "Enabled applications before the image change:"
nextcloud_occ app:list || fail "occ app:list failed. Upgrade was not started."

"${SCRIPT_DIR}/backup.sh" --hold

info "Recreating only ${NEXTCLOUD_SERVICE}. Cron stays stopped."
compose_cmd up -d --no-deps --force-recreate "${NEXTCLOUD_SERVICE}"

expected="$(upgrade_release_number "${target}")"
attempt=0
ready="no"

while [[ "${attempt}" -lt 120 ]]
do
    attempt=$((attempt + 1))
    version_now="$(nextcloud_occ_status_value versionstring || true)"
    installed_now="$(nextcloud_occ_status_value installed || true)"

    if [[ "${installed_now}" == "true" && "${version_now}" == "${expected}" ]]; then
        ready="yes"
        break
    fi

    if ! docker_container_running "${NEXTCLOUD_APP_CONTAINER}"; then
        docker logs --tail 80 "${NEXTCLOUD_APP_CONTAINER}" || true
        fail "Nextcloud container exited during the upgrade."
    fi

    sleep 15
done

[[ "${ready}" == "yes" ]] \
    || fail "Timed out waiting for Nextcloud ${expected}. See docker logs ${NEXTCLOUD_APP_CONTAINER}. Do not start the old image."

bind="$(env_get NEXTCLOUD_BACKEND_BIND)"
port="$(env_get NEXTCLOUD_BACKEND_PORT)"
status_body="$(curl -fsS "http://${bind}:${port}/status.php")" \
    || fail "status.php is not reachable at http://${bind}:${port}/status.php"

[[ "${status_body}" == *'"installed":true'* ]] \
    || fail "status.php does not report installed:true."

info "Recreating cron from ${target} now that the upgrade succeeded."
compose_cmd up -d --no-deps --force-recreate "${CRON_SERVICE}"

nextcloud_maintenance off \
    || fail "Upgrade finished but maintenance mode could not be turned off."

printf '%s\n' "${target}" > "${INSTALLED_VERSION_FILE}"
chmod 600 "${INSTALLED_VERSION_FILE}"
rm -f "${UPGRADE_LOCK_FILE}"

trap - EXIT
print_footer "Upgrade to ${target} completed."
