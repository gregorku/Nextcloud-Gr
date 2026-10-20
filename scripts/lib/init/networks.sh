#!/usr/bin/env bash

###############################################################################
#
# Authentik-netcup Project
#
# Create the Docker network used inside the Authentik Incus container.
#
# Compose marks the network external, so this step has to run before
# the first docker compose up.
#
###############################################################################

create_docker_network()
{
    local network_name="$1"
    local subnet="$2"
    local gateway="$3"

    if docker network inspect "${network_name}" >/dev/null 2>&1; then
        log_info "Docker network '${network_name}' already exists."
        return 0
    fi

    log_info "Creating Docker network '${network_name}'..."

    docker network create \
        --driver bridge \
        --subnet "${subnet}" \
        --gateway "${gateway}" \
        "${network_name}" \
        >/dev/null

    log_success "Docker network '${network_name}' created."
}

init_networks()
{
    log_step "Docker networks"

    create_docker_network \
        "${NETWORK_INTERNAL}" \
        "${NETWORK_INTERNAL_SUBNET}" \
        "${NETWORK_INTERNAL_GATEWAY}"

    log_success "Docker networks ready."
}
