#!/usr/bin/env bash

###############################################################################
#
# Authentik-netcup Project
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

###############################################################################
# Docker Compose
###############################################################################

ENV_POLICY[COMPOSE_PROJECT_NAME]="framework"

###############################################################################
# Persistent data
###############################################################################

ENV_POLICY[DATA_DIR]="framework"

###############################################################################
# Authentik host
###############################################################################

ENV_POLICY[AUTHENTIK_HOST_IP]="framework"
ENV_POLICY[AUTHENTIK_HTTP_PORT]="framework"
ENV_POLICY[AUTHENTIK_DOMAIN]="user"

###############################################################################
# Images
###############################################################################

ENV_POLICY[AUTHENTIK_IMAGE]="framework"
ENV_POLICY[AUTHENTIK_TAG]="framework"
ENV_POLICY[POSTGRES_IMAGE]="framework"

###############################################################################
# PostgreSQL
###############################################################################

ENV_POLICY[PG_DB]="framework"
ENV_POLICY[PG_USER]="framework"
ENV_POLICY[PG_PASS]="generated"

###############################################################################
# Authentik
###############################################################################

ENV_POLICY[AUTHENTIK_SECRET_KEY]="generated"
ENV_POLICY[AUTHENTIK_POSTGRESQL__SSLMODE]="framework"
ENV_POLICY[AUTHENTIK_ERROR_REPORTING__ENABLED]="framework"
ENV_POLICY[AUTHENTIK_OUTPOSTS__DISCOVER]="framework"
ENV_POLICY[AUTHENTIK_LISTEN__TRUSTED_PROXY_CIDRS]="user"

###############################################################################
# Internal addresses
###############################################################################

ENV_POLICY[IP_POSTGRESQL]="user"
ENV_POLICY[IP_AUTHENTIK_SERVER]="user"
ENV_POLICY[IP_AUTHENTIK_WORKER]="user"

###############################################################################
# SMTP
###############################################################################

ENV_POLICY[AUTHENTIK_EMAIL__HOST]="user"
ENV_POLICY[AUTHENTIK_EMAIL__PORT]="user"
ENV_POLICY[AUTHENTIK_EMAIL__USERNAME]="user"
ENV_POLICY[AUTHENTIK_EMAIL__PASSWORD]="user"
ENV_POLICY[AUTHENTIK_EMAIL__USE_TLS]="user"
ENV_POLICY[AUTHENTIK_EMAIL__USE_SSL]="user"
ENV_POLICY[AUTHENTIK_EMAIL__TIMEOUT]="user"
ENV_POLICY[AUTHENTIK_EMAIL__FROM]="user"

###############################################################################
# Logging
###############################################################################

ENV_POLICY[LOG_MAX_SIZE]="framework"
ENV_POLICY[LOG_MAX_FILES]="framework"

###############################################################################
# External backup destination
#
# Empty is valid and means "local backup only".
###############################################################################

ENV_POLICY[BACKUP_EXTERNAL_DIR]="user"

###############################################################################
# Public age recipient
#
# Empty means backup.sh does not write an archive. This is not an
# identity. The private key is never stored here.
###############################################################################

ENV_POLICY[BACKUP_AGE_RECIPIENT]="user"

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
