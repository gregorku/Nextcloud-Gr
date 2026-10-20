#!/usr/bin/env bash

###############################################################################
#
# Nextcloud-Gr Project
#
# File:
#   scripts/lib/nextcloud/occ.sh
#
# Description:
#   Run occ in the PHP-FPM container as www-data.
#   Callers must not log arguments that contain secrets.
#
###############################################################################

nextcloud_occ()
{
    docker exec -u www-data "${NEXTCLOUD_APP_CONTAINER}" \
        php occ "$@"
}

nextcloud_occ_status_value()
{
    local field="$1"

    nextcloud_occ status \
        | sed -n "s/^[[:space:]]*-[[:space:]]*${field}:[[:space:]]*//p" \
        | head -n 1
}

nextcloud_maintenance()
{
    local mode="$1"

    case "${mode}" in
        on|off)
            ;;
        *)
            return 1
            ;;
    esac

    nextcloud_occ maintenance:mode "--${mode}"
}
