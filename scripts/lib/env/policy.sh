#!/usr/bin/env bash

###############################################################################
#
# Nextcloud-Gr Project
#
# Environment variable policies.
#
#   framework   replaced from .env.example on every update-env.sh run
#   user        existing non-empty value is kept
#   generated   existing non-placeholder value is kept; otherwise a new
#               secret is generated once and then kept
#
###############################################################################

declare -gA ENV_POLICY

ENV_POLICY[COMPOSE_PROJECT_NAME]="framework"

ENV_POLICY[DATA_DIR]="framework"
ENV_POLICY[NEXTCLOUD_HTML_HOST_DIR]="framework"
ENV_POLICY[POSTGRESQL_HOST_DIR]="user"
ENV_POLICY[NEXTCLOUD_DATA_HOST_DIR]="user"
ENV_POLICY[NEXTCLOUD_SOURCE_DATA_DIR]="user"

ENV_POLICY[NEXTCLOUD_DOMAIN]="framework"
ENV_POLICY[NEXTCLOUD_BACKEND_BIND]="user"
ENV_POLICY[NEXTCLOUD_BACKEND_PORT]="user"
ENV_POLICY[NEXTCLOUD_TRUSTED_DOMAINS]="framework"

ENV_POLICY[NEXTCLOUD_IMAGE]="framework"
ENV_POLICY[NEXTCLOUD_TAG]="framework"
ENV_POLICY[POSTGRES_IMAGE]="framework"
ENV_POLICY[REDIS_IMAGE]="framework"
ENV_POLICY[NGINX_IMAGE]="framework"

ENV_POLICY[DOCKER_NETWORK_SUBNET]="user"
ENV_POLICY[DOCKER_NETWORK_GATEWAY]="user"

ENV_POLICY[PG_DB]="framework"
ENV_POLICY[PG_USER]="framework"
ENV_POLICY[PG_PASS]="generated"

ENV_POLICY[REDIS_PASSWORD]="generated"

ENV_POLICY[NEXTCLOUD_ADMIN_USER]="user"
ENV_POLICY[NEXTCLOUD_ADMIN_PASSWORD]="generated"

ENV_POLICY[TRUSTED_PROXIES]="user"
ENV_POLICY[OVERWRITEPROTOCOL]="framework"
ENV_POLICY[OVERWRITEHOST]="framework"
ENV_POLICY[OVERWRITECLIURL]="framework"
ENV_POLICY[FORWARDED_FOR_HEADERS]="framework"

ENV_POLICY[PHP_MEMORY_LIMIT]="framework"
ENV_POLICY[PHP_UPLOAD_LIMIT]="framework"
ENV_POLICY[PHP_OPCACHE_MEMORY_CONSUMPTION]="framework"

ENV_POLICY[LOG_MAX_SIZE]="framework"
ENV_POLICY[LOG_MAX_FILES]="framework"

ENV_POLICY[BACKUP_LOCAL_DIR]="framework"
ENV_POLICY[BACKUP_EXTERNAL_DIR]="user"
ENV_POLICY[BACKUP_AGE_RECIPIENT]="user"

ENV_POLICY[RESTIC_REPOSITORY]="user"
ENV_POLICY[RESTIC_PASSWORD]="generated"
ENV_POLICY[RESTIC_KEEP_DAILY]="framework"
ENV_POLICY[RESTIC_KEEP_WEEKLY]="framework"
ENV_POLICY[RESTIC_KEEP_MONTHLY]="framework"
ENV_POLICY[RESTIC_KEEP_YEARLY]="framework"

ENV_POLICY[UPGRADE_MIN_FREE_MB]="framework"

ENV_POLICY[SMTP_HOST]="user"
ENV_POLICY[SMTP_PORT]="user"
ENV_POLICY[SMTP_SECURE]="user"
ENV_POLICY[SMTP_NAME]="user"
ENV_POLICY[SMTP_PASSWORD]="user"
ENV_POLICY[MAIL_FROM_ADDRESS]="user"
ENV_POLICY[MAIL_DOMAIN]="user"

###############################################################################
# Return variable policy
###############################################################################

env_variable_policy()
{
    local variable="$1"

    printf '%s\n' "${ENV_POLICY[$variable]:-user}"
}

###############################################################################
# Variable exists in policy
###############################################################################

env_is_known_variable()
{
    local variable="$1"

    [[ -v ENV_POLICY["$variable"] ]]
}
