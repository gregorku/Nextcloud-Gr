#!/usr/bin/env bash

###############################################################################
#
# Authentik-netcup Project
#
# Prepare persistent directories that are not part of the Git checkout
# and not part of the synchronized stack.
#
###############################################################################

init_directories()
{
    log_step "Project directories"

    # DATA_DIR stays owned by root and is not chmod 700. PostgreSQL
    # uid 70 and Authentik uid 1000 have to traverse it to reach the
    # directories init_postgresql and init_authentik chown for them.
    # Mode 700 on this parent would deny that traversal. Only the
    # backup directory is mode 700, because root reads and writes it.
    ensure_directory "${DATA_DIR}"
    ensure_directory "${BACKUP_LOCAL_DIR}"

    chmod 700 "${BACKUP_LOCAL_DIR}"

    ok "Permissions 700: ${BACKUP_LOCAL_DIR}"

    log_success "Project directories ready."
}
