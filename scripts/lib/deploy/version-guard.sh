#!/usr/bin/env bash

###############################################################################
#
# Nextcloud-Gr Project
#
# File:
#   scripts/lib/deploy/version-guard.sh
#
# Description:
#   Stop deploy.sh before it pulls or starts a different Nextcloud or
#   PostgreSQL major than the one already installed.
#
###############################################################################

deploy_assert_same_version()
{
    print_section "Version guard"

    local result
    local postgres_result

    result="$(
        deploy_version_decision \
            "${INSTALLED_VERSION_FILE}" \
            "${NEXTCLOUD_HTML_DIR}/config/config.php" \
            "$(env_get NEXTCLOUD_TAG)"
    )" || fail "${result}"

    case "${result}" in
        unchanged)
            ok "Installed Nextcloud tag matches NEXTCLOUD_TAG."
            ;;
        first-install)
            info "No installed version and no config.php. This is a first installation."
            ;;
        *)
            fail "Unexpected version decision: ${result}"
            ;;
    esac

    postgres_result="$(
        deploy_postgres_major_decision \
            "${POSTGRES_MAJOR_FILE}" \
            "$(env_get POSTGRES_IMAGE)"
    )" || fail "${postgres_result}"

    case "${postgres_result}" in
        unchanged|first)
            ok "PostgreSQL major matches the pinned image."
            ;;
        *)
            fail "Unexpected PostgreSQL decision: ${postgres_result}"
            ;;
    esac

    if [[ -f "${UPGRADE_LOCK_FILE}" ]]; then
        fail "Upgrade lock ${UPGRADE_LOCK_FILE} is present. Finish or clear the failed upgrade before deploy.sh."
    fi
}
