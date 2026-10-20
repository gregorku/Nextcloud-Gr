#!/usr/bin/env bash

###############################################################################
#
# Authentik-netcup Project
#
# File:
#   scripts/lib/env/validate.sh
#
# Description:
#   Validate environment configuration.
#
#   Runtime .env must contain every policy key, must not contain keys
#   outside the policy, and must not still hold set_* placeholders.
#   BACKUP_EXTERNAL_DIR may be empty.
#
#   .env.example is checked by the static tests. Its generated and
#   secret values must stay placeholders so a real secret is not
#   committed.
#
###############################################################################

###############################################################################
# Backup target
#
# Arguments:
#   $1 - BACKUP_EXTERNAL_DIR value
#
###############################################################################

env_validate_backup_target()
{
    local value="$1"
    local protected

    [[ -z "${value}" ]] && return 0

    [[ "${value}" == /* ]] \
        || fail "BACKUP_EXTERNAL_DIR must be an absolute path."

    [[ "${value}" != "/" ]] \
        || fail "BACKUP_EXTERNAL_DIR must not be '/'."

    #
    # case patterns are not pathname-expanded. An unquoted star in [[ ]]
    # would expand /backups/* once that mount contains files, and the
    # last false test would also become the function status under set -e.
    #

    for protected in "${DATA_DIR}" "${STACK_DIR}" "${GIT_DIR}" "${BACKUP_LOCAL_DIR}"
    do
        case "${value}" in
            "${protected}"|"${protected}"/*)
                fail "BACKUP_EXTERNAL_DIR must not point inside ${protected}."
                ;;
        esac

        case "${protected}" in
            "${value}"|"${value}"/*)
                fail "BACKUP_EXTERNAL_DIR ${value} would contain ${protected}."
                ;;
        esac
    done

    return 0
}

###############################################################################
# Public age recipient
#
# Arguments:
#   $1 - BACKUP_AGE_RECIPIENT value
#
# Empty is valid and means backup.sh keeps no archive. A private
# identity is rejected. The value is not written to the log.
#
###############################################################################

env_validate_age_recipient()
{
    local value="$1"

    [[ -z "${value}" ]] && return 0

    [[ "${value}" != *$'\n'* ]] \
        || fail "BACKUP_AGE_RECIPIENT must be a single line."

    [[ "${value}" != AGE-SECRET-KEY-* ]] \
        || fail "BACKUP_AGE_RECIPIENT must be a public recipient, not an age identity."

    if [[ "${value}" == age1* ]]; then
        [[ "${value}" =~ ^age1[a-z0-9]+$ ]] \
            || fail "BACKUP_AGE_RECIPIENT is not an age public recipient."
        return 0
    fi

    [[ "${value}" =~ ^ssh-(ed25519|rsa)[[:space:]]+[A-Za-z0-9+/=]+([[:space:]]+[^[:space:]]+)?$ ]] \
        || fail "BACKUP_AGE_RECIPIENT must be an age1 recipient or an ssh public key."
}

###############################################################################
# Trusted proxy list
#
# Arguments:
#   $1 - Comma-separated CIDRs
#
###############################################################################

env_validate_proxy_cidrs()
{
    local value="$1"
    local cidr

    [[ -n "${value}" ]] \
        || fail "AUTHENTIK_LISTEN__TRUSTED_PROXY_CIDRS is empty."

    env_is_placeholder "${value}" \
        && fail "AUTHENTIK_LISTEN__TRUSTED_PROXY_CIDRS is still a placeholder."

    local IFS=','

    for cidr in ${value}
    do
        [[ "${cidr}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] \
            || fail "Invalid proxy CIDR: ${cidr}"
    done
}

###############################################################################
# Validate one parsed environment
#
# Arguments:
#   $1 - Name of the associative array
#   $2 - runtime or example
#
###############################################################################

env_validate_array()
{
    local array_name="$1"
    local mode="$2"
    local variable
    local value

    for variable in "${!ENV_POLICY[@]}"
    do
        eval "[[ -v ${array_name}[\"\${variable}\"] ]]" \
            || fail "Missing variable: ${variable}"

        eval "value=\"\${${array_name}[\"\${variable}\"]}\""

        if [[ "${variable}" == "BACKUP_EXTERNAL_DIR" ]]; then
            env_validate_backup_target "${value}"
            continue
        fi

        if [[ "${variable}" == "BACKUP_AGE_RECIPIENT" ]]; then
            env_validate_age_recipient "${value}"
            continue
        fi

        [[ -n "${value}" ]] \
            || fail "Empty variable: ${variable}"

        case "${mode}" in

            example)

                case "${variable}" in

                    PG_PASS|AUTHENTIK_SECRET_KEY|AUTHENTIK_EMAIL__HOST|AUTHENTIK_EMAIL__USERNAME|AUTHENTIK_EMAIL__PASSWORD|AUTHENTIK_EMAIL__FROM|AUTHENTIK_LISTEN__TRUSTED_PROXY_CIDRS)

                        env_is_placeholder "${value}" \
                            || fail "Example value for ${variable} is not a placeholder."
                        ;;

                esac
                ;;

            runtime)

                env_is_placeholder "${value}" \
                    && fail "Placeholder is not usable in production: ${variable}"
                ;;

            *)
                fail "Unknown validation mode: ${mode}"
                ;;

        esac
    done

    #
    # Reject keys that the policy does not know. update-env.sh drops
    # them; a hand-edited file should not keep a typo silently.
    #

    local -a present_keys

    eval "present_keys=(\"\${!${array_name}[@]}\")"

    for variable in "${present_keys[@]}"
    do
        env_is_known_variable "${variable}" \
            || fail "Unknown variable: ${variable}"
    done

    if [[ "${mode}" == "runtime" ]]; then
        env_validate_runtime_rules "${array_name}"
    fi
}

###############################################################################
# Rules that apply only to a deployment .env
#
# Arguments:
#   $1 - Name of the associative array
#
###############################################################################

env_validate_runtime_rules()
{
    local array_name="$1"
    local value

    eval "value=\"\${${array_name}[AUTHENTIK_HOST_IP]}\""
    [[ "${value}" == "${AUTHENTIK_HOST_IP}" ]] \
        || fail "AUTHENTIK_HOST_IP must be ${AUTHENTIK_HOST_IP}."

    eval "value=\"\${${array_name}[AUTHENTIK_HTTP_PORT]}\""
    [[ "${value}" == "${AUTHENTIK_HTTP_PORT}" ]] \
        || fail "AUTHENTIK_HTTP_PORT must be ${AUTHENTIK_HTTP_PORT}."

    eval "value=\"\${${array_name}[COMPOSE_PROJECT_NAME]}\""
    [[ "${value}" == "${STACK_NAME}" ]] \
        || fail "COMPOSE_PROJECT_NAME must be ${STACK_NAME}."

    eval "value=\"\${${array_name}[PG_PASS]}\""
    [[ "${#value}" -le 99 ]] \
        || fail "PG_PASS is longer than 99 characters."

    eval "value=\"\${${array_name}[AUTHENTIK_SECRET_KEY]}\""
    [[ "${#value}" -ge 50 ]] \
        || fail "AUTHENTIK_SECRET_KEY must be at least 50 characters."

    eval "value=\"\${${array_name}[AUTHENTIK_LISTEN__TRUSTED_PROXY_CIDRS]}\""
    env_validate_proxy_cidrs "${value}"

    local use_tls
    local use_ssl

    eval "use_tls=\"\${${array_name}[AUTHENTIK_EMAIL__USE_TLS]}\""
    eval "use_ssl=\"\${${array_name}[AUTHENTIK_EMAIL__USE_SSL]}\""

    [[ "${use_tls}" == "true" && "${use_ssl}" == "true" ]] \
        && fail "AUTHENTIK_EMAIL__USE_TLS and AUTHENTIK_EMAIL__USE_SSL are mutually exclusive."

    eval "value=\"\${${array_name}[AUTHENTIK_EMAIL__PORT]}\""
    [[ "${value}" =~ ^[0-9]+$ ]] \
        || fail "AUTHENTIK_EMAIL__PORT must be numeric."
}

###############################################################################
# Validate the runtime .env
###############################################################################

env_validate()
{
    declare -A ENV

    env_read_current ENV

    env_validate_array ENV runtime
}

###############################################################################
# Validate a named environment file
#
# Arguments:
#   $1 - File path
#   $2 - runtime or example
#
###############################################################################

env_validate_file()
{
    local file="$1"
    local mode="$2"

    declare -A ENV_CHECK

    env_parse_file "${file}" ENV_CHECK

    env_validate_array ENV_CHECK "${mode}"
}
