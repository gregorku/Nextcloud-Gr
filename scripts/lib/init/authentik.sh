#!/usr/bin/env bash

###############################################################################
#
# Authentik-netcup Project
#
# File:
#   scripts/lib/init/authentik.sh
#
# Description:
#   Initialize Authentik file storage, custom templates and worker certs.
#
#   ghcr.io/goauthentik/server:2026.8.3 runs as uid 1000
#   (adduser --uid 1000, USER 1000 in lifecycle/container/Dockerfile).
#   /data, /templates and /certs are bind-mounted, so the image-level
#   chown does not apply to the host directories.
#
###############################################################################

init_authentik()
{
    print_section "Authentik"

    ensure_directory_owner \
        "${AUTHENTIK_DATA_DIR}" \
        "${AUTHENTIK_UID_GID}"

    ensure_directory_owner \
        "${AUTHENTIK_TEMPLATES_DIR}" \
        "${AUTHENTIK_UID_GID}"

    ensure_directory_owner \
        "${AUTHENTIK_CERTS_DIR}" \
        "${AUTHENTIK_UID_GID}"

    ok "Authentik layout ready."
}
