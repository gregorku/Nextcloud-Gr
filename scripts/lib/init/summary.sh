#!/usr/bin/env bash

###############################################################################
#
# Authentik-netcup Project
#
# File:
#   scripts/lib/init/summary.sh
#
# Description:
#   Initialization summary.
#
###############################################################################

init_summary()
{
    print_section "Finished"

    ok "Initialization completed."

    echo

    info "Next steps:"
    info "1. Edit placeholders in ${ENV_FILE} after ./scripts/update-env.sh"
    info "2. Set AUTHENTIK_LISTEN__TRUSTED_PROXY_CIDRS and SMTP."
    info "3. Run ./scripts/check-env.sh"
    info "4. Run ./scripts/deploy.sh"

    echo
}
