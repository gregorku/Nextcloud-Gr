#!/usr/bin/env bash

###############################################################################
#
# Nextcloud-Gr Project
#
# File:
#   scripts/lib/env/validate.sh
#
# Description:
#   Validate environment configuration.
#
#   Runtime .env must contain every policy key, must not contain keys
#   outside the policy, and must not still hold set_* placeholders.
#   BACKUP_EXTERNAL_DIR, BACKUP_AGE_RECIPIENT, NEXTCLOUD_SOURCE_DATA_DIR
#   and SMTP may be empty.
#
###############################################################################

###############################################################################
# IPv4 helpers
###############################################################################

env_ipv4_octets_ok()
{
    local ip="$1"
    local octet

    [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1

    local IFS=.
    for octet in ${ip}
    do
        [[ "${octet}" =~ ^[0-9]+$ ]] || return 1
        [[ "$((10#${octet}))" -le 255 ]] || return 1
    done
}

env_ipv4_to_int()
{
    local ip="$1"
    local a b c d

    IFS=. read -r a b c d <<< "${ip}"
    printf '%s\n' $(( (10#${a} << 24) + (10#${b} << 16) + (10#${c} << 8) + 10#${d} ))
}

env_cidr_ok()
{
    local cidr="$1"
    local base prefix

    [[ "${cidr}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || return 1

    base="${cidr%/*}"
    prefix="${cidr#*/}"

    env_ipv4_octets_ok "${base}" || return 1
    [[ "$((10#${prefix}))" -le 32 ]] || return 1
}

env_cidr_contains_ip()
{
    local cidr="$1"
    local ip="$2"
    local base prefix ip_int base_int mask

    base="${cidr%/*}"
    prefix="${cidr#*/}"
    ip_int="$(env_ipv4_to_int "${ip}")"
    base_int="$(env_ipv4_to_int "${base}")"

    if [[ "${prefix}" -eq 0 ]]; then
        return 0
    fi

    mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
    [[ $(( ip_int & mask )) -eq $(( base_int & mask )) ]]
}

env_cidr_is_network_address()
{
    local cidr="$1"
    local base prefix base_int mask network

    base="${cidr%/*}"
    prefix="${cidr#*/}"
    base_int="$(env_ipv4_to_int "${base}")"

    if [[ "${prefix}" -eq 0 ]]; then
        [[ "${base}" == "0.0.0.0" ]]
        return
    fi

    mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
    network=$(( base_int & mask ))
    [[ "${network}" -eq "${base_int}" ]]
}

env_ip_in_rfc1918_or_cgnat()
{
    local ip="$1"

    env_cidr_contains_ip "10.0.0.0/8" "${ip}" && return 0
    env_cidr_contains_ip "172.16.0.0/12" "${ip}" && return 0
    env_cidr_contains_ip "192.168.0.0/16" "${ip}" && return 0
    env_cidr_contains_ip "100.64.0.0/10" "${ip}" && return 0
    return 1
}

###############################################################################
# Paths
###############################################################################

env_validate_absolute_path()
{
    local name="$1"
    local value="$2"

    [[ "${value}" == /* ]] \
        || fail "${name} must be an absolute path."

    [[ "${value}" != "/" ]] \
        || fail "${name} must not be '/'."

    [[ "${value}" != *..* ]] \
        || fail "${name} must not contain '..'."
}

env_path_is_legacy_target()
{
    local value="$1"

    [[ "${value}" == "${LEGACY_APP_DIR}" \
        || "${value}" == "${LEGACY_USER_DATA_DIR}" \
        || "${value}" == "${LEGACY_MARIADB_DIR}" \
        || "${value}" == "${LEGACY_REDIS_DIR}" ]]
}

env_validate_backup_target()
{
    local value="$1"
    local protected

    [[ -z "${value}" ]] && return 0

    env_validate_absolute_path "BACKUP_EXTERNAL_DIR" "${value}"

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
}

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

env_validate_proxy_cidrs()
{
    local value="$1"
    local cidr

    [[ -n "${value}" ]] \
        || fail "TRUSTED_PROXIES is empty."

    env_is_placeholder "${value}" \
        && fail "TRUSTED_PROXIES is still a placeholder."

    [[ "${value}" != *","* ]] \
        || fail "TRUSTED_PROXIES is space-separated. Commas are not accepted."

    local IFS=' '

    for cidr in ${value}
    do
        env_cidr_ok "${cidr}" \
            || fail "Invalid proxy CIDR: ${cidr}"
    done
}

env_validate_restic_repository()
{
    local value="$1"

    [[ "${value}" != *$'\n'* ]] \
        || fail "RESTIC_REPOSITORY must be a single line."

    if [[ "${value}" =~ ^(sftp|rest|s3|rclone|azure|gs|b2|swift): ]]; then
        return 0
    fi

    env_validate_absolute_path "RESTIC_REPOSITORY" "${value}"
}

env_image_has_floating_tag()
{
    local value="$1"

    [[ "${value}" == *":latest" || "${value}" == *":stable" \
        || "${value}" == *":stable-fpm" || "${value}" == *":fpm" \
        || "${value}" == *":production" || "${value}" == *":production-fpm" \
        || "${value}" == *":alpine" ]]
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

        case "${variable}" in
            BACKUP_EXTERNAL_DIR)
                env_validate_backup_target "${value}"
                continue
                ;;
            BACKUP_AGE_RECIPIENT)
                env_validate_age_recipient "${value}"
                continue
                ;;
            NEXTCLOUD_SOURCE_DATA_DIR|SMTP_HOST|SMTP_NAME|SMTP_PASSWORD|MAIL_FROM_ADDRESS|MAIL_DOMAIN)
                if [[ -z "${value}" ]]; then
                    continue
                fi
                ;;
        esac

        [[ -n "${value}" ]] \
            || fail "Empty variable: ${variable}"

        case "${mode}" in

            example)

                case "${variable}" in

                    NEXTCLOUD_BACKEND_BIND|TRUSTED_PROXIES|DOCKER_NETWORK_SUBNET|DOCKER_NETWORK_GATEWAY|POSTGRESQL_HOST_DIR|NEXTCLOUD_DATA_HOST_DIR|PG_PASS|REDIS_PASSWORD|NEXTCLOUD_ADMIN_USER|NEXTCLOUD_ADMIN_PASSWORD|RESTIC_REPOSITORY|RESTIC_PASSWORD)

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

    eval "value=\"\${${array_name}[COMPOSE_PROJECT_NAME]}\""
    [[ "${value}" == "${STACK_NAME}" ]] \
        || fail "COMPOSE_PROJECT_NAME must be ${STACK_NAME}."

    eval "value=\"\${${array_name}[DATA_DIR]}\""
    [[ "${value}" == "${DATA_DIR}" ]] \
        || fail "DATA_DIR must be ${DATA_DIR}."

    eval "value=\"\${${array_name}[NEXTCLOUD_HTML_HOST_DIR]}\""
    [[ "${value}" == "${NEXTCLOUD_HTML_DIR}" ]] \
        || fail "NEXTCLOUD_HTML_HOST_DIR must be ${NEXTCLOUD_HTML_DIR}."

    eval "value=\"\${${array_name}[BACKUP_LOCAL_DIR]}\""
    [[ "${value}" == "${BACKUP_LOCAL_DIR}" ]] \
        || fail "BACKUP_LOCAL_DIR must be ${BACKUP_LOCAL_DIR}."

    eval "value=\"\${${array_name}[NEXTCLOUD_DOMAIN]}\""
    [[ "${value}" == "${NEXTCLOUD_DOMAIN}" ]] \
        || fail "NEXTCLOUD_DOMAIN must be ${NEXTCLOUD_DOMAIN}."

    eval "value=\"\${${array_name}[NEXTCLOUD_BACKEND_BIND]}\""
    env_ipv4_octets_ok "${value}" \
        || fail "NEXTCLOUD_BACKEND_BIND is not an IPv4 address."
    [[ "${value}" != "0.0.0.0" ]] \
        || fail "NEXTCLOUD_BACKEND_BIND must not be 0.0.0.0."
    env_ip_in_rfc1918_or_cgnat "${value}" \
        || fail "NEXTCLOUD_BACKEND_BIND must be an RFC1918 or CGNAT address."
    env_cidr_contains_ip "127.0.0.0/8" "${value}" \
        && fail "NEXTCLOUD_BACKEND_BIND must not be a loopback address."

    eval "value=\"\${${array_name}[NEXTCLOUD_BACKEND_PORT]}\""
    [[ "${value}" =~ ^[0-9]+$ ]] \
        || fail "NEXTCLOUD_BACKEND_PORT must be numeric."
    [[ "${value}" -ge 1 && "${value}" -le 65535 ]] \
        || fail "NEXTCLOUD_BACKEND_PORT is outside 1-65535."

    case "${value}" in
        5432|6379|9000|${DOCKGE_PORT})
            fail "NEXTCLOUD_BACKEND_PORT ${value} collides with PostgreSQL, Redis, PHP-FPM or Dockge."
            ;;
    esac

    eval "value=\"\${${array_name}[NEXTCLOUD_TAG]}\""
    [[ "${value}" =~ ^[0-9]+\.[0-9]+\.[0-9]+-fpm$ ]] \
        || fail "NEXTCLOUD_TAG must be an exact X.Y.Z-fpm release."

    eval "value=\"\${${array_name}[NEXTCLOUD_IMAGE]}\""
    [[ "${value}" == "docker.io/library/nextcloud" ]] \
        || fail "NEXTCLOUD_IMAGE must be docker.io/library/nextcloud."

    eval "value=\"\${${array_name}[POSTGRES_IMAGE]}\""
    [[ "${value}" =~ ^docker\.io/library/postgres:18\.[0-9]+$ ]] \
        || fail "POSTGRES_IMAGE must be an exact postgres:18.x tag."
    env_image_has_floating_tag "${value}" \
        && fail "POSTGRES_IMAGE uses a floating tag."

    eval "value=\"\${${array_name}[REDIS_IMAGE]}\""
    [[ "${value}" =~ ^docker\.io/library/redis:[0-9]+\.[0-9]+\.[0-9]+-alpine$ ]] \
        || fail "REDIS_IMAGE must be an exact redis patch tag."

    eval "value=\"\${${array_name}[NGINX_IMAGE]}\""
    [[ "${value}" =~ ^docker\.io/library/nginx:[0-9]+\.[0-9]+\.[0-9]+-alpine$ ]] \
        || fail "NGINX_IMAGE must be an exact nginx patch tag."

    local subnet gateway

    eval "subnet=\"\${${array_name}[DOCKER_NETWORK_SUBNET]}\""
    eval "gateway=\"\${${array_name}[DOCKER_NETWORK_GATEWAY]}\""

    env_cidr_ok "${subnet}" \
        || fail "DOCKER_NETWORK_SUBNET is not a CIDR."
    env_cidr_is_network_address "${subnet}" \
        || fail "DOCKER_NETWORK_SUBNET must be the network address, not a host inside the range."

    local prefix="${subnet#*/}"
    [[ "${prefix}" -ge 8 && "${prefix}" -le 28 ]] \
        || fail "DOCKER_NETWORK_SUBNET prefix must be between 8 and 28."

    env_ip_in_rfc1918_or_cgnat "${subnet%/*}" \
        || fail "DOCKER_NETWORK_SUBNET must be RFC1918 or CGNAT."

    env_ipv4_octets_ok "${gateway}" \
        || fail "DOCKER_NETWORK_GATEWAY is not an IPv4 address."
    env_cidr_contains_ip "${subnet}" "${gateway}" \
        || fail "DOCKER_NETWORK_GATEWAY is outside DOCKER_NETWORK_SUBNET."
    [[ "${gateway}" != "${subnet%/*}" ]] \
        || fail "DOCKER_NETWORK_GATEWAY must not be the network address."

    eval "value=\"\${${array_name}[PG_PASS]}\""
    [[ "${#value}" -ge 16 && "${#value}" -le 99 ]] \
        || fail "PG_PASS must be 16 to 99 characters."

    eval "value=\"\${${array_name}[REDIS_PASSWORD]}\""
    [[ "${#value}" -ge 16 ]] \
        || fail "REDIS_PASSWORD must be at least 16 characters."

    eval "value=\"\${${array_name}[RESTIC_PASSWORD]}\""
    [[ "${#value}" -ge 16 ]] \
        || fail "RESTIC_PASSWORD must be at least 16 characters."

    eval "value=\"\${${array_name}[NEXTCLOUD_ADMIN_USER]}\""
    [[ "${value}" =~ ^[A-Za-z0-9._-]{1,64}$ ]] \
        || fail "NEXTCLOUD_ADMIN_USER contains unsupported characters."

    eval "value=\"\${${array_name}[NEXTCLOUD_ADMIN_PASSWORD]}\""
    [[ "${#value}" -ge 16 ]] \
        || fail "NEXTCLOUD_ADMIN_PASSWORD must be at least 16 characters."

    eval "value=\"\${${array_name}[TRUSTED_PROXIES]}\""
    env_validate_proxy_cidrs "${value}"

    eval "value=\"\${${array_name}[OVERWRITEPROTOCOL]}\""
    [[ "${value}" == "https" ]] \
        || fail "OVERWRITEPROTOCOL must be https."

    local postgres_dir data_dir source_dir

    eval "postgres_dir=\"\${${array_name}[POSTGRESQL_HOST_DIR]}\""
    eval "data_dir=\"\${${array_name}[NEXTCLOUD_DATA_HOST_DIR]}\""
    eval "source_dir=\"\${${array_name}[NEXTCLOUD_SOURCE_DATA_DIR]}\""

    env_validate_absolute_path "POSTGRESQL_HOST_DIR" "${postgres_dir}"
    env_validate_absolute_path "NEXTCLOUD_DATA_HOST_DIR" "${data_dir}"

    env_path_is_legacy_target "${postgres_dir}" \
        && fail "POSTGRESQL_HOST_DIR points at a legacy MariaDB, Redis or Nextcloud path."
    env_path_is_legacy_target "${data_dir}" \
        && fail "NEXTCLOUD_DATA_HOST_DIR must be a new directory, not the live legacy data path."

    [[ "${postgres_dir}" != "${data_dir}" ]] \
        || fail "PostgreSQL and Nextcloud data must be different directories."

    case "${postgres_dir}" in
        "${DATA_DIR}"|"${DATA_DIR}"/*|"${STACK_DIR}"|"${STACK_DIR}"/*|"${GIT_DIR}"|"${GIT_DIR}"/*|"${BACKUP_LOCAL_DIR}"|"${BACKUP_LOCAL_DIR}"/*)
            fail "POSTGRESQL_HOST_DIR must stay outside Git, the stack, HTML data and local age backups."
            ;;
    esac

    case "${data_dir}" in
        "${DATA_DIR}"|"${DATA_DIR}"/*|"${STACK_DIR}"|"${STACK_DIR}"/*|"${GIT_DIR}"|"${GIT_DIR}"/*|"${BACKUP_LOCAL_DIR}"|"${BACKUP_LOCAL_DIR}"/*|"${postgres_dir}"|"${postgres_dir}"/*)
            fail "NEXTCLOUD_DATA_HOST_DIR must stay outside Git, the stack, PostgreSQL and local age backups."
            ;;
    esac

    if [[ -n "${source_dir}" ]]; then
        env_validate_absolute_path "NEXTCLOUD_SOURCE_DATA_DIR" "${source_dir}"
        [[ "${source_dir}" != "${data_dir}" ]] \
            || fail "NEXTCLOUD_SOURCE_DATA_DIR and NEXTCLOUD_DATA_HOST_DIR must differ."
        case "${data_dir}" in
            "${source_dir}"/*)
                fail "NEXTCLOUD_DATA_HOST_DIR must not be inside the migration source."
                ;;
        esac
        case "${source_dir}" in
            "${LEGACY_MARIADB_DIR}"|"${LEGACY_REDIS_DIR}"|"${LEGACY_APP_DIR}")
                fail "NEXTCLOUD_SOURCE_DATA_DIR must be user files, not MariaDB, Redis or the old application directory."
                ;;
        esac
    fi

    eval "value=\"\${${array_name}[RESTIC_REPOSITORY]}\""
    env_validate_restic_repository "${value}"

    if [[ "${value}" == /* ]]; then
        [[ "${value}" != "${data_dir}" && "${value}" != "${postgres_dir}" ]] \
            || fail "RESTIC_REPOSITORY must not be the data or database directory."
        case "${value}" in
            "${data_dir}"/*|"${postgres_dir}"/*|"${STACK_DIR}"|"${STACK_DIR}"/*|"${GIT_DIR}"|"${GIT_DIR}"/*)
                fail "RESTIC_REPOSITORY overlaps Nextcloud data, PostgreSQL, Git or the stack."
                ;;
        esac
    fi

    local smtp_host
    eval "smtp_host=\"\${${array_name}[SMTP_HOST]}\""

    if [[ -n "${smtp_host}" ]]; then
        local smtp_port smtp_secure smtp_name smtp_password from_address mail_domain

        eval "smtp_port=\"\${${array_name}[SMTP_PORT]}\""
        eval "smtp_secure=\"\${${array_name}[SMTP_SECURE]}\""
        eval "smtp_name=\"\${${array_name}[SMTP_NAME]}\""
        eval "smtp_password=\"\${${array_name}[SMTP_PASSWORD]}\""
        eval "from_address=\"\${${array_name}[MAIL_FROM_ADDRESS]}\""
        eval "mail_domain=\"\${${array_name}[MAIL_DOMAIN]}\""

        [[ "${smtp_port}" =~ ^[0-9]+$ ]] \
            || fail "SMTP_PORT must be numeric."
        [[ "${smtp_secure}" == "tls" || "${smtp_secure}" == "ssl" || "${smtp_secure}" == "" ]] \
            || fail "SMTP_SECURE must be tls, ssl or empty."
        [[ -n "${smtp_name}" && -n "${smtp_password}" && -n "${from_address}" && -n "${mail_domain}" ]] \
            || fail "SMTP_HOST is set, so SMTP_NAME, SMTP_PASSWORD, MAIL_FROM_ADDRESS and MAIL_DOMAIN are required."
    fi

    eval "value=\"\${${array_name}[UPGRADE_MIN_FREE_MB]}\""
    [[ "${value}" =~ ^[0-9]+$ && "${value}" -ge 1024 ]] \
        || fail "UPGRADE_MIN_FREE_MB must be an integer of at least 1024."

    for value in RESTIC_KEEP_DAILY RESTIC_KEEP_WEEKLY RESTIC_KEEP_MONTHLY RESTIC_KEEP_YEARLY
    do
        local keep
        eval "keep=\"\${${array_name}[${value}]}\""
        [[ "${keep}" =~ ^[0-9]+$ ]] \
            || fail "${value} must be numeric."
    done
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
