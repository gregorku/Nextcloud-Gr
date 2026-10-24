#!/usr/bin/env bash

###############################################################################
#
# Nextcloud-Gr
#
# File:
#   scripts/lib/env/writer.sh
#
# Description:
#   Environment file writer.
#
# Responsibilities:
#   - Backup current .env
#   - Create temporary .env
#   - Write synchronized .env
#   - Replace original .env
#
###############################################################################

###############################################################################
# Backup file
#
# Arguments:
#   $1 - Source file
#   $2 - Backup prefix
#
###############################################################################

backup_file()
{
    local source="$1"
    local prefix="$2"

    [[ -f "${source}" ]] || return

    local backup

    backup="${prefix}-$(date +%Y%m%d-%H%M%S)"

    cp "${source}" "${backup}"

    chmod 600 "${backup}"

    ok "Backup created: $(basename "${backup}")"
}

###############################################################################
# Write synchronized environment
#
# Arguments:
#   stdin - Complete .env content
#
###############################################################################

env_write_file()
{
    backup_file "${ENV_FILE}" "${ENV_BACKUP_PREFIX}"

    cat > "${ENV_TMP_FILE}"

    #
    # The runtime file holds the database password and
    # AUTHENTIK_SECRET_KEY. Keep it, the temporary file and the
    # timestamped backup readable only by root.
    #

    chmod 600 "${ENV_TMP_FILE}"

    if [[ -f "${ENV_FILE}" ]]; then
        chmod 600 "${ENV_FILE}"
    fi

    mv "${ENV_TMP_FILE}" "${ENV_FILE}"

    chmod 600 "${ENV_FILE}"

    ok ".env written."
}