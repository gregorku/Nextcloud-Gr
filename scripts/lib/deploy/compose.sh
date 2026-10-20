#!/usr/bin/env bash

###############################################################################
#
# Authentik-netcup Project
#
# File:
#   scripts/lib/deploy/compose.sh
#
# Description:
#   Validate, pull and start the Authentik Compose stack.
#
#   deploy.sh is the only command that starts the stack. These
#   functions are not called by init.sh or by the static tests.
#
###############################################################################

deploy_validate_compose()
{
    print_section "Compose validation"

    check_compose_configuration
}

deploy_compose()
{
    print_section "Authentik-netcup"

    log_info "Pulling images..."

    compose_pull

    log_info "Starting stack..."

    compose_up

    log_success "Authentik-netcup deployed."
}
