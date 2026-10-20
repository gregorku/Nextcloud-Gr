#!/usr/bin/env bash

###############################################################################
#
# Authentik-netcup Project
#
# File:
#   scripts/lib/docker.sh
#
# Description:
#   Docker Engine helper functions.
#
###############################################################################

###############################################################################
# Docker daemon
#
# Usage:
#   require_docker_daemon
#
###############################################################################

require_docker_daemon() {

    require_docker

    docker info >/dev/null 2>&1 \
        || fail "Docker daemon is not running."
}

###############################################################################
# Container exists
#
# Usage:
#   docker_container_exists traefik
#
###############################################################################

docker_container_exists() {

    local container="$1"

    docker container inspect "${container}" >/dev/null 2>&1
}

###############################################################################
# Container running
#
# Usage:
#   docker_container_running traefik
#
###############################################################################

docker_container_running() {

    local container="$1"

    docker ps \
        --format '{{.Names}}' \
        | grep -Fxq "${container}"
}

###############################################################################
# Execute command
#
# Usage:
#   docker_exec traefik ls /
#
###############################################################################

docker_exec() {

    local container="$1"

    shift

    docker exec "${container}" "$@"
}

###############################################################################
# Logs
#
# Usage:
#   docker_logs traefik
#
###############################################################################

docker_logs() {

    docker logs "$@"
}

###############################################################################
# Restart container
#
# Usage:
#   docker_restart traefik
#
###############################################################################

docker_restart() {

    docker restart "$1" >/dev/null

    ok "Restarted $1."
}

###############################################################################
# Stop container
#
# Usage:
#   docker_stop traefik
#
###############################################################################

docker_stop() {

    docker stop "$1" >/dev/null

    ok "Stopped $1."
}

###############################################################################
# Start container
#
# Usage:
#   docker_start traefik
#
###############################################################################

docker_start() {

    docker start "$1" >/dev/null

    ok "Started $1."
}

###############################################################################
# Network exists
#
# Usage:
#   docker_network_exists monitoring-netcup
#
###############################################################################

docker_network_exists() {

    docker network inspect "$1" >/dev/null 2>&1
}

###############################################################################
# Volume exists
#
# Usage:
#   docker_volume_exists volume-name
#
###############################################################################

docker_volume_exists() {

    docker volume inspect "$1" >/dev/null 2>&1
}