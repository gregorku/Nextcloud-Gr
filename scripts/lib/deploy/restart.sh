#!/usr/bin/env bash

###############################################################################
#
# Nextcloud-Gr
#
# No local reverse proxy has to be restarted. Infrastructure-netcup owns
# Traefik and its configuration.
#
###############################################################################

deploy_restart_services()
{
    print_section "Restart services"

    log_info "No local static reverse-proxy service requires restart."

    return 0
}
