#!/usr/bin/env bash

###############################################################################
#
# Nextcloud-Gr Project
#
# File:
#   scripts/config.sh
#
# Description:
#   Common configuration shared by all Nextcloud-Gr scripts.
#
#   Scripts run as root inside the existing Incus container. This file
#   does not create that container, its network devices or its disks.
#
###############################################################################

set -Eeuo pipefail
IFS=$'\n\t'

###############################################################################
# Project
###############################################################################

readonly PROJECT_NAME="Nextcloud-Gr"

#
# Docker Compose project name. Dockge uses the directory name under
# STACKS_DIR, which is the same value.
#
readonly STACK_NAME="nextcloud-gr"

###############################################################################
# Repository
###############################################################################

readonly GIT_DIR="/incus-dir/git/${PROJECT_NAME}"

###############################################################################
# Base directories
###############################################################################

readonly BASE_DIR="/docker-data"

readonly DATA_DIR="${BASE_DIR}/nextcloud-gr"

#
# /docker-data must be an Incus disk device. init.sh and deploy.sh
# refuse to create it on the container root filesystem.
#
readonly DOCKER_DATA_DIR="${BASE_DIR}"

###############################################################################
# Dockge
#
# Dockge is installed outside this project. deploy.sh checks the
# running container and does not install, reinstall or replace it.
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
# Runtime .env, runtime/, DATA_DIR, user files, PostgreSQL and
# BACKUP_LOCAL_DIR are not listed. rsync --delete cannot remove them.
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
# The bridge subnet is not chosen here. WireGuard, Incus and LAN
# ranges were not inspected from this checkout. check-env.sh rejects
# DOCKER_NETWORK_SUBNET until an administrator sets a free range.
# Containers use Compose DNS names. They do not have fixed addresses.
###############################################################################

readonly NETWORK_INTERNAL="nextcloud-gr"

###############################################################################
# Public name
#
# TLS, DNS and the Traefik router stay in Infrastructure-netcup.
# The backend bind address is not known here.
###############################################################################

readonly NEXTCLOUD_DOMAIN="gregor.serveftp.org"

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
readonly REDIS_SERVICE="redis"
readonly NEXTCLOUD_SERVICE="nextcloud"
readonly NGINX_SERVICE="nginx"
readonly CRON_SERVICE="cron"

readonly POSTGRESQL_CONTAINER="nextcloud-gr-postgresql"
readonly REDIS_CONTAINER="nextcloud-gr-redis"
readonly NEXTCLOUD_APP_CONTAINER="nextcloud-gr-app"
readonly NGINX_CONTAINER="nextcloud-gr-nginx"
readonly NEXTCLOUD_CRON_CONTAINER="nextcloud-gr-cron"

###############################################################################
# Versions pinned on 2026-10-20
#
# Nextcloud 35.0.2-fpm:
#   https://github.com/docker-library/official-images/blob/master/library/nextcloud
#   Dockerfile 35/fpm at a1af1a30: FROM php:8.5-fpm-trixie
#   https://docs.nextcloud.com/server/stable/admin_manual/installation/system_requirements.html
# PostgreSQL 18.6:
#   https://hub.docker.com/_/postgres
#   PGDATA=/var/lib/postgresql/18/docker and VOLUME /var/lib/postgresql
#   Debian image user postgres is uid 999.
# Redis 8.10.2 and nginx 1.30.6:
#   https://hub.docker.com/_/redis
#   https://hub.docker.com/_/nginx
###############################################################################

readonly POSTGRES_MAJOR="18"
readonly NEXTCLOUD_UID_GID="33:33"
readonly POSTGRESQL_UID_GID="999:999"

###############################################################################
# Persistent layout inside DATA_DIR
#
# PostgreSQL and the Nextcloud data directory are not under DATA_DIR.
# Their host paths come from the runtime .env and must already be on a
# mounted disk. HTML, state and the local backup directory are on the
# /docker-data disk.
###############################################################################

readonly NEXTCLOUD_HTML_DIR="${DATA_DIR}/html"
readonly NEXTCLOUD_STATE_DIR="${DATA_DIR}/state"
readonly INSTALLED_VERSION_FILE="${NEXTCLOUD_STATE_DIR}/installed-version"
readonly POSTGRES_MAJOR_FILE="${NEXTCLOUD_STATE_DIR}/postgres-major"
readonly UPGRADE_LOCK_FILE="${NEXTCLOUD_STATE_DIR}/upgrade.lock"

###############################################################################
# Paths of the previous installation on the physical host.
#
# These are migration sources, not mount targets for the new stack.
# They are refused as POSTGRESQL_HOST_DIR and NEXTCLOUD_DATA_HOST_DIR.
# Whether any of them is visible inside the Incus container was not
# verified from this checkout.
###############################################################################

readonly LEGACY_APP_DIR="/docker/nextcloud/nextcloud_gregor/nextcloud_app"
readonly LEGACY_USER_DATA_DIR="/HDD/data-raid-HDD/Nextcloud-data/data-Gregor"
readonly LEGACY_MARIADB_DIR="/SDD/nvme-1T-btrf/nextcloud_gregor/mariadb/db_data"
readonly LEGACY_REDIS_DIR="/docker/nextcloud/nextcloud_gregor/redis/data"

###############################################################################
# Backups
#
# Local age archives live outside DATA_DIR and outside STACK_DIR.
# User files are stored by restic, not by that age archive.
###############################################################################

readonly BACKUP_LOCAL_DIR="${BASE_DIR}/backups/${STACK_NAME}"
