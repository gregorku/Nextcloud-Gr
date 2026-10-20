#!/usr/bin/env bash

###############################################################################
#
# Authentik-netcup Project
#
# File:
#   scripts/lib/init/postgresql.sh
#
# Description:
#   Initialize the PostgreSQL data directory.
#
#   postgres:16-alpine creates the postgres user as uid/gid 70.
#   The official entrypoint starts as root and drops to that user.
#   The data directory still has to be writable by uid 70 before the
#   first initialization.
#
###############################################################################

init_postgresql()
{
    print_section "PostgreSQL"

    ensure_directory_owner \
        "${POSTGRESQL_DIR}" \
        "${POSTGRESQL_UID_GID}"

    ok "PostgreSQL layout ready."
}
