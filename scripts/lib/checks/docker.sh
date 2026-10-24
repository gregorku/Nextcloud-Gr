#!/usr/bin/env bash

###############################################################################
#
# Nextcloud-Gr
#
# File:
#   scripts/lib/checks/docker.sh
#
# Description:
#   Docker validation and helper functions used by Nextcloud-Gr scripts.
#
###############################################################################

###############################################################################
# Docker command
###############################################################################

require_docker()
{
    require_command docker
}

###############################################################################
# Docker daemon
###############################################################################

require_docker_daemon()
{
    docker info >/dev/null 2>&1 \
        || fail "Docker daemon is not running."
}

require_container_running()
{
    local container="$1"

    docker_container_running "${container}" \
        || fail "Container is not running: ${container}"
}

###############################################################################
# Docker environment
###############################################################################

check_docker_environment()
{
    #
    # Generic framework checks
    #

    check_environment

    #
    # Docker CLI
    #

    require_docker

    #
    # Docker daemon
    #

    require_docker_daemon

    ok "Docker environment OK."
}

###############################################################################
# Execute command inside container
###############################################################################

docker_exec()
{
    local container="$1"

    shift

    docker exec "${container}" "$@"
}

###############################################################################
# Container state
###############################################################################

docker_container_running()
{
    local container="$1"

    [[ "$(docker inspect \
        --format '{{.State.Running}}' \
        "${container}" 2>/dev/null)" == "true" ]]
}

###############################################################################
# Docker network
###############################################################################

docker_network_exists()
{
    local network="$1"

    docker network inspect "${network}" >/dev/null 2>&1
}

###############################################################################
# HTTP headers from inside container
# Containers use internal certificates issued by Traefik.
###############################################################################

docker_http_headers()
{
    local container="$1"
    local url="$2"

    docker_exec "${container}" \
        wget \
            --no-check-certificate \
            -S \
            -O /dev/null \
            "${url}" \
            2>&1 || true
}