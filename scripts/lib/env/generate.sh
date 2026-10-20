#!/usr/bin/env bash

###############################################################################
#
# Nextcloud-Gr Project
#
# File:
#   scripts/lib/env/generate.sh
#
# Description:
#   Generate secrets for policy "generated".
#
#   A generated value is written only into the runtime .env. It is not
#   printed and it is not written back to .env.example.
#
#   PostgreSQL rejects passwords longer than 99 characters. base64 of
#   36 bytes is 48 characters, without the trailing newline.
#
###############################################################################

###############################################################################
# Generate one secret
#
# Arguments:
#   $1 - Number of random bytes passed to openssl rand -base64
#
###############################################################################

env_generate_secret()
{
    local bytes="$1"
    local value

    command -v openssl >/dev/null 2>&1 \
        || fail "openssl is required to generate ${bytes} secret bytes."

    value="$(openssl rand -base64 "${bytes}" | tr -d '\n')"

    [[ -n "${value}" ]] \
        || fail "openssl returned an empty secret."

    printf '%s\n' "${value}"
}

###############################################################################
# Generate the secret for one policy key
#
# Arguments:
#   $1 - Variable name
#
###############################################################################

env_generate_secret_for()
{
    local key="$1"

    case "${key}" in

        PG_PASS|REDIS_PASSWORD|RESTIC_PASSWORD)
            env_generate_secret 36
            ;;

        NEXTCLOUD_ADMIN_PASSWORD)
            env_generate_secret 24
            ;;

        *)
            fail "No secret generator is defined for ${key}."
            ;;

    esac
}
