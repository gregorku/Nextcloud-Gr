#!/usr/bin/env bash

###############################################################################
#
# Nextcloud-Gr
#
# File:
#   scripts/lib/upgrade/sequence.sh
#
# Description:
#   Order of one Nextcloud image upgrade. Cron is stopped first.
#   The image entrypoint then runs once in the nextcloud service.
#   Cron is created from the same tag only after verification.
#   Nothing in this sequence starts the previous image.
#
###############################################################################

upgrade_phase_stop_cron()
{
    if docker_container_running "${NEXTCLOUD_CRON_CONTAINER}"; then
        docker stop "${NEXTCLOUD_CRON_CONTAINER}" >/dev/null \
            || return 1
    fi
}

upgrade_phase_check_apps()
{
    local list
    local ids
    local major
    local reason

    list="$(mktemp)"
    ids="$(mktemp)"

    if ! nextcloud_occ app:list > "${list}"; then
        rm -f "${list}" "${ids}"
        return 1
    fi

    upgrade_enabled_app_ids "${list}" > "${ids}"
    IFS=' ' read -r major _ _ <<< "$(upgrade_tag_parts "${UPGRADE_EXPECTED_TAG}")" || {
        rm -f "${list}" "${ids}"
        return 1
    }

    if ! reason="$(upgrade_custom_apps_allow_major "${NEXTCLOUD_HTML_DIR}/custom_apps" "${major}" "${ids}")"; then
        rm -f "${list}" "${ids}"
        [[ -n "${reason}" ]] && log_error "${reason}"
        return 1
    fi

    rm -f "${list}" "${ids}"
}

upgrade_phase_hold_backup()
{
    "${SCRIPT_DIR}/backup.sh" --hold
}

upgrade_phase_recreate_app()
{
    compose_cmd up -d --no-deps --force-recreate "${NEXTCLOUD_SERVICE}"
}

upgrade_phase_verify()
{
    local expected
    local attempt=0
    local version_now
    local installed_now
    local needs_db
    local bind
    local port
    local status_body
    local postgres_status

    expected="$(upgrade_release_number "${UPGRADE_EXPECTED_TAG}")" || return 1

    while [[ "${attempt}" -lt 120 ]]
    do
        attempt=$((attempt + 1))
        version_now="$(nextcloud_occ_status_value versionstring || true)"
        installed_now="$(nextcloud_occ_status_value installed || true)"
        needs_db="$(nextcloud_occ_status_value needsDbUpgrade || true)"

        if [[ "${installed_now}" == "true" \
            && "${version_now}" == "${expected}" \
            && "${needs_db}" == "false" ]]; then
            break
        fi

        if ! docker_container_running "${NEXTCLOUD_APP_CONTAINER}"; then
            docker logs --tail 80 "${NEXTCLOUD_APP_CONTAINER}" || true
            return 1
        fi

        if [[ "${attempt}" -eq 120 ]]; then
            return 1
        fi

        sleep 15
    done

    postgres_status="$(
        docker inspect \
            --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
            "${POSTGRESQL_CONTAINER}"
    )"
    [[ "${postgres_status}" == "healthy" ]] || return 1

    bind="$(env_get NEXTCLOUD_BACKEND_BIND)"
    port="$(env_get NEXTCLOUD_BACKEND_PORT)"
    status_body="$(curl -fsS "http://${bind}:${port}/status.php")" || return 1
    [[ "${status_body}" == *'"installed":true'* ]] || return 1
    [[ "${status_body}" != *'"needsDbUpgrade":true'* ]] || return 1
}

upgrade_phase_recreate_cron()
{
    compose_cmd up -d --no-deps --force-recreate "${CRON_SERVICE}"
}

upgrade_phase_leave_maintenance()
{
    nextcloud_maintenance off
}

###############################################################################
# Run the upgrade phases. A failing verify stops cron again and does
# not recreate it. The previous image is not started.
#
###############################################################################

upgrade_run_sequence()
{
    upgrade_phase_stop_cron || return 1
    upgrade_phase_check_apps || return 1
    upgrade_phase_hold_backup || return 1
    upgrade_phase_recreate_app || return 1

    if ! upgrade_phase_verify; then
        upgrade_phase_stop_cron || true
        return 1
    fi

    upgrade_phase_recreate_cron || return 1
    upgrade_phase_leave_maintenance || {
        upgrade_phase_stop_cron || true
        return 1
    }
}
