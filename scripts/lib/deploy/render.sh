#!/usr/bin/env bash

###############################################################################
#
# Nextcloud-Gr Project
#
# File:
#   scripts/lib/deploy/render.sh
#
# Description:
#   Write runtime files that must not live in Git.
#   Redis password is written to the config file and is not printed.
#
###############################################################################

render_redis_conf()
{
    local dest="$1"
    local password="$2"
    local directory
    local tmp

    [[ -n "${password}" ]] || return 1
    [[ "${password}" != set_* ]] || return 1

    directory="$(dirname "${dest}")"
    mkdir -p "${directory}"
    chmod 700 "${directory}"

    tmp="$(mktemp "${directory}/redis.conf.XXXXXX")"
    chmod 600 "${tmp}"

    cat > "${tmp}" <<EOF
bind 0.0.0.0
protected-mode yes
port 6379
requirepass ${password}
maxmemory 256mb
maxmemory-policy noeviction
save ""
appendonly no
EOF

    mv "${tmp}" "${dest}"
    chmod 600 "${dest}"
}

render_real_ip_conf()
{
    local dest="$1"
    local cidrs="$2"
    local directory
    local tmp
    local cidr

    [[ -n "${cidrs}" ]] || return 1

    directory="$(dirname "${dest}")"
    mkdir -p "${directory}"

    tmp="$(mktemp "${directory}/real-ip.conf.XXXXXX")"

    {
        printf 'real_ip_header X-Forwarded-For;\n'
        printf 'real_ip_recursive on;\n'

        local IFS=' '
        for cidr in ${cidrs}
        do
            printf 'set_real_ip_from %s;\n' "${cidr}"
        done
    } > "${tmp}"

    install -m 644 "${tmp}" "${dest}"
    rm -f "${tmp}"
}

deploy_render_runtime()
{
    print_section "Runtime files"

    render_redis_conf \
        "${STACK_DIR}/runtime/redis.conf" \
        "$(env_get REDIS_PASSWORD)"

    render_real_ip_conf \
        "${STACK_DIR}/runtime/real-ip.conf" \
        "$(env_get TRUSTED_PROXIES)"

    ok "Redis and Nginx runtime files written."
}
