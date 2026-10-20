#!/usr/bin/env bash

init_summary()
{
    print_section "Finished"

    ok "Initialization completed."

    echo

    info "Next steps:"
    info "1. Run ./scripts/update-env.sh"
    info "2. Replace every set_* value in ${ENV_FILE}"
    info "3. Run ./scripts/check-env.sh"
    info "4. Run ./scripts/deploy.sh"

    echo

    info "deploy.sh creates the Docker bridge and the data directories."
    info "It does not upgrade an installed Nextcloud version."
}
