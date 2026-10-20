#!/usr/bin/env bash

###############################################################################
#
# Authentik-netcup Project
#
# File:
#   scripts/config.sh
#
# Description:
#   Common configuration shared by all Authentik-netcup scripts.
#
#   Scripts are executed inside the existing Incus container
#   10.10.10.100. This file does not create that container.
#
###############################################################################

set -Eeuo pipefail
IFS=$'\n\t'

###############################################################################
# Project
###############################################################################

readonly PROJECT_NAME="Authentik-netcup"

#
# Docker Compose stack name. Dockge uses the directory name under
# STACKS_DIR, which is the same value.
#
readonly STACK_NAME="authentik-netcup"

###############################################################################
# Repository
###############################################################################

readonly GIT_DIR="/incus-dir/git/${PROJECT_NAME}"

###############################################################################
# Base directories
###############################################################################

readonly BASE_DIR="/docker-data"

readonly DATA_DIR="${BASE_DIR}/authentik-netcup"

###############################################################################
# Dockge
#
# Dockge is already installed in the Authentik Incus container.
# These values describe that existing installation. deploy.sh checks
# them and does not reinstall Dockge.
###############################################################################

readonly DOCKGE_DIR="${BASE_DIR}/dockge"
readonly DOCKGE_DATA_DIR="${DOCKGE_DIR}/data"

readonly DOCKGE_CONTAINER="dockge"
readonly DOCKGE_IMAGE="louislam/dockge:latest"
readonly DOCKGE_PORT="5001"

###############################################################################
# Docker Compose stacks
###############################################################################

readonly STACKS_DIR="${BASE_DIR}/stacks"
readonly STACK_DIR="${STACKS_DIR}/${STACK_NAME}"

###############################################################################
# Stack files
###############################################################################

readonly COMPOSE_FILE="${STACK_DIR}/compose.yml"
readonly ENV_FILE="${STACK_DIR}/.env"
readonly ENV_EXAMPLE_FILE="${STACK_DIR}/.env.example"

###############################################################################
# Files copied during initialization and deployment
#
# Runtime .env, its backups, DATA_DIR and BACKUP_LOCAL_DIR are not
# listed here. rsync --delete therefore cannot remove them.
###############################################################################

readonly DEPLOY_ITEMS=(
    compose.yml
    compose
    configs
    .env.example
)

###############################################################################
# Docker network
#
# Subnet choice, checked against the other project configs on
# 2026-10-13:
#
#   Infrastructure-netcup   10.40.0.0/16
#   Monitoring-netcup       10.40.0.0/16
#   Vaultwarden-netcup      10.41.0.0/16
#
# 10.42.0.0/16 does not overlap the Incus LAN 10.10.10.0/24.
# Each Incus container has its own Docker daemon, so those bridges
# are not one shared L2 network. The Docker network list inside the
# running container 10.10.10.100 was not inspected from this checkout.
###############################################################################

readonly NETWORK_INTERNAL="authentik-netcup"
readonly NETWORK_INTERNAL_SUBNET="10.42.0.0/16"
readonly NETWORK_INTERNAL_GATEWAY="10.42.0.1"

###############################################################################
# Incus container address
#
# Traefik in Infrastructure-netcup reaches Authentik at this address.
# Confirmed target: 10.10.10.100 port 9000.
###############################################################################

readonly AUTHENTIK_HOST_IP="10.10.10.100"
readonly AUTHENTIK_HTTP_PORT="9000"

###############################################################################
# Colors
###############################################################################

readonly COLOR_RED="\033[0;31m"
readonly COLOR_GREEN="\033[0;32m"
readonly COLOR_YELLOW="\033[1;33m"
readonly COLOR_BLUE="\033[0;34m"
readonly COLOR_RESET="\033[0m"

###############################################################################
# Compose services and container names
###############################################################################

readonly POSTGRESQL_SERVICE="postgresql"
readonly AUTHENTIK_SERVER_SERVICE="server"
readonly AUTHENTIK_WORKER_SERVICE="worker"

readonly POSTGRESQL_CONTAINER="authentik-postgresql"
readonly AUTHENTIK_SERVER_CONTAINER="authentik-server"
readonly AUTHENTIK_WORKER_CONTAINER="authentik-worker"

###############################################################################
# Persistent data
#
# Ownership was taken from the upstream image definitions used by the
# pinned Compose file (Authentik 2026.8.3, PostgreSQL 16-alpine):
#
#   lifecycle/container/Dockerfile
#     adduser --system --uid 1000 --group authentik
#     USER 1000
#
#   docker-library postgres 16/alpine3.23/Dockerfile
#     addgroup -g 70
#     adduser -u 70 postgres
#
# The worker in the upstream Compose file sets "user: root" only so it
# can mount the Docker socket for separately deployed outposts. This
# project uses the embedded outpost and does not mount that socket, so
# the worker keeps the image user 1000.
###############################################################################

readonly POSTGRESQL_DIR="${DATA_DIR}/postgresql"
readonly POSTGRESQL_UID_GID="70:70"

readonly AUTHENTIK_DIR="${DATA_DIR}/authentik"
readonly AUTHENTIK_DATA_DIR="${AUTHENTIK_DIR}/data"
readonly AUTHENTIK_TEMPLATES_DIR="${AUTHENTIK_DIR}/templates"
readonly AUTHENTIK_CERTS_DIR="${AUTHENTIK_DIR}/certs"
readonly AUTHENTIK_UID_GID="1000:1000"

###############################################################################
# Backups
#
# Local archives live outside DATA_DIR and outside STACK_DIR.
# BACKUP_EXTERNAL_DIR is /backups: an Incus disk from the host VPS,
# visible in the container as a mountpoint. It can share a device
# number with /docker-data. backup.sh copies there only when the
# path is that mountpoint. Another program transfers those files
# off the VPS later. An empty value means local only.
###############################################################################

readonly BACKUP_LOCAL_DIR="${BASE_DIR}/backups/${STACK_NAME}"
