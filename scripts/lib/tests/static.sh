#!/usr/bin/env bash

###############################################################################
#
# Nextcloud-Gr Project
#
# File:
#   scripts/lib/tests/static.sh
#
# Description:
#   Checks that read the Git checkout and temporary directories.
#   They do not write to /docker-data and they do not start Compose.
#
###############################################################################

test_repository_layout()
{
    print_section "Repository layout"

    local root
    local item

    root="$(cd "${SCRIPT_DIR}/.." && pwd)"

    for item in "${DEPLOY_ITEMS[@]}"; do
        require_file_or_directory "${root}/${item}"
    done

    require_file "${root}/compose/00-networks.yml"
    require_file "${root}/compose/10-postgresql.yml"
    require_file "${root}/compose/20-redis.yml"
    require_file "${root}/compose/30-nextcloud-fpm.yml"
    require_file "${root}/compose/40-nginx.yml"
    require_file "${root}/compose/50-cron.yml"
    require_file "${root}/configs/nginx/nginx.conf"
    require_file "${root}/scripts/upgrade.sh"
    require_file "${root}/scripts/record-installed.sh"
    require_file "${root}/docs/migration-from-current.md"
    require_file "${root}/docs/upgrade.md"

    [[ ! -e "${root}/compose/20-authentik-server.yml" ]] \
        || fail "Authentik server Compose file is still present."

    [[ ! -e "${root}/compose/30-authentik-worker.yml" ]] \
        || fail "Authentik worker Compose file is still present."

    [[ ! -e "${root}/scripts/install-dockge.sh" ]] \
        || fail "Dockge installer is still present."

    [[ ! -e "${root}/scripts/lib/init/authentik.sh" ]] \
        || fail "Authentik init module is still present."

    if grep -R -n -E 'traefik|caddy|/var/run/docker\.sock' \
        "${root}/compose" "${root}/compose.yml"; then
        fail "Compose references Traefik, Caddy or the Docker socket."
    fi

    ok "Repository layout OK."
}

test_env_example()
{
    print_section ".env.example"

    local root

    root="$(cd "${SCRIPT_DIR}/.." && pwd)"

    env_validate_file "${root}/.env.example" example

    local domain
    local tag

    domain="$(
        awk -F= '$1 == "NEXTCLOUD_DOMAIN" { print substr($0, index($0, "=") + 1); exit }' \
            "${root}/.env.example"
    )"
    tag="$(
        awk -F= '$1 == "NEXTCLOUD_TAG" { print substr($0, index($0, "=") + 1); exit }' \
            "${root}/.env.example"
    )"

    [[ "${domain}" == "${NEXTCLOUD_DOMAIN}" ]] \
        || fail ".env.example domain does not match config.sh."

    [[ "${tag}" == "35.0.2-fpm" ]] \
        || fail ".env.example Nextcloud tag is ${tag}."

    ok ".env.example matches the variable policy."
}

test_runtime_placeholder_rejection()
{
    print_section "Placeholder rejection"

    local root
    local work
    local runtime
    local message

    root="$(cd "${SCRIPT_DIR}/.." && pwd)"
    work="$(mktemp -d)"
    runtime="${work}/.env"

    cp "${root}/.env.example" "${runtime}"

    message="$(env_validate_file "${runtime}" runtime 2>&1)" || true

    [[ "${message}" == *"Placeholder is not usable in production"* ]] \
        || fail "Runtime validation did not reject placeholders: ${message}"

    rm -rf "${work}"

    ok "Placeholder runtime .env was rejected."
}

test_compose_bindings()
{
    print_section "Compose bindings"

    local root

    root="$(cd "${SCRIPT_DIR}/.." && pwd)"

    grep -q 'external: true' "${root}/compose/00-networks.yml" \
        || fail "Docker network is not external."

    grep -Fq '${POSTGRESQL_HOST_DIR}:/var/lib/postgresql' \
        "${root}/compose/10-postgresql.yml" \
        || fail "PostgreSQL is not mounted at /var/lib/postgresql."

    if grep -Eq '^[[:space:]]*- .*:/var/lib/postgresql/data([[:space:]]|$)' \
        "${root}/compose/10-postgresql.yml"; then
        fail "PostgreSQL still uses the pre-18 data mount."
    fi

    if grep -Eq '^[[:space:]]*ports:' "${root}/compose/10-postgresql.yml" \
        "${root}/compose/20-redis.yml" \
        "${root}/compose/30-nextcloud-fpm.yml" \
        "${root}/compose/50-cron.yml"; then
        fail "A non-Nginx service publishes a host port."
    fi

    grep -Fq '"${NEXTCLOUD_BACKEND_BIND}:${NEXTCLOUD_BACKEND_PORT}:80"' \
        "${root}/compose/40-nginx.yml" \
        || fail "Nginx is not bound to the configured private address."

    grep -Fq '../configs/nginx/nginx.conf:/etc/nginx/conf.d/default.conf:ro' \
        "${root}/compose/40-nginx.yml" \
        || fail "Nginx snippet is not mounted in conf.d."

    if grep -q '/etc/nginx/nginx.conf' "${root}/compose/40-nginx.yml"; then
        fail "Nginx snippet replaces the main nginx.conf."
    fi

    if grep -q 'nginx.conf' "${root}/compose/30-nextcloud-fpm.yml"; then
        fail "The Nextcloud service mounts the Nginx configuration."
    fi

    grep -Fq '${NEXTCLOUD_HTML_HOST_DIR}:/var/www/html' \
        "${root}/compose/30-nextcloud-fpm.yml" \
        || fail "Nextcloud HTML is not writable."

    if grep -Fq '/var/www/html:ro' "${root}/compose/30-nextcloud-fpm.yml"; then
        fail "Nextcloud HTML is mounted read-only."
    fi

    grep -Fq '10-apcu.sh:/docker-entrypoint-hooks.d/post-installation/10-apcu.sh:ro' \
        "${root}/compose/30-nextcloud-fpm.yml" \
        || fail "The Nextcloud installation hook is not mounted."

    grep -Fq 'installed:[[:space:]]*true' \
        "${root}/compose/50-cron.yml" \
        || fail "Cron healthcheck does not require an installed Nextcloud."

    if grep -n 'docker exec -u postgres' \
        "${root}/scripts/lib/deploy/compose.sh" \
        "${root}/scripts/lib/backup/postgres.sh" \
        "${root}/scripts/lib/backup/apply.sh" \
        "${root}/scripts/backup.sh"
    then
        fail "A PostgreSQL client still logs in as the OS role postgres."
    fi

    grep -Fq -- '-U "${db_user}"' "${root}/scripts/lib/docker.sh" \
        || fail "PostgreSQL clients are not started as PG_USER."
    grep -Fq -- '-h 127.0.0.1' "${root}/scripts/lib/docker.sh" \
        || fail "PostgreSQL clients still depend on peer authentication."

    if grep -R -n -E '0\.0\.0\.0:|5432:5432|6379:6379|9000:9000' \
        "${root}/compose" "${root}/compose.yml"; then
        fail "Compose publishes a forbidden address or port."
    fi

    if grep -R -n -E ':latest|:stable-fpm|:stable|:production' \
        "${root}/.env.example" "${root}/compose" "${root}/compose.yml"; then
        fail "A floating image tag is present."
    fi

    for needle in carddav caldav webfinger nodeinfo remote.php client_max_body_size
    do
        grep -q "${needle}" "${root}/configs/nginx/nginx.conf" \
            || fail "Nginx config is missing ${needle}."
    done

    if grep -q 'listen 443' "${root}/configs/nginx/nginx.conf"; then
        fail "Nginx config listens for TLS."
    fi

    ok "Compose file constraints match the Nextcloud stack."
}

test_sync_guards()
{
    print_section "Sync guards"

    assert_sync_paths

    local item

    for item in "${DEPLOY_ITEMS[@]}"
    do
        case "${item}" in
            *postgresql*|*html*|*backup*|*.env)
                fail "DEPLOY_ITEMS includes a persistent path: ${item}"
                ;;
        esac
    done

    local work
    local git_dir
    local stack_dir
    local outside
    local refused

    work="$(mktemp -d)"
    git_dir="${work}/git"
    stack_dir="${work}/stack"
    outside="${work}/outside"

    mkdir -p "${git_dir}/configs" "${stack_dir}/configs" "${outside}"

    printf 'kept\n' > "${git_dir}/configs/kept.yml"
    printf 'old\n' > "${stack_dir}/configs/removed.yml"
    printf 'secret\n' > "${stack_dir}/.env"
    printf 'leave-me\n' > "${outside}/file"

    sync_item_contents \
        "${git_dir}/configs" \
        "${stack_dir}/configs" \
        "${stack_dir}"

    [[ -f "${stack_dir}/configs/kept.yml" ]] \
        || fail "Synced file is missing."

    [[ ! -f "${stack_dir}/configs/removed.yml" ]] \
        || fail "rsync --delete left a file removed from the source."

    [[ -f "${stack_dir}/.env" ]] \
        || fail "rsync --delete removed the runtime .env."

    mkdir -p "${git_dir}/empty-item"
    refused="$(
        sync_item_contents \
            "${git_dir}/empty-item" \
            "${stack_dir}/empty-item" \
            "${stack_dir}" \
            2>&1
    )" || true
    [[ "${refused}" == *"empty source"* ]] \
        || fail "rsync --delete accepted an empty source: ${refused}"

    refused="$(
        sync_replace_item \
            "${git_dir}/configs/kept.yml" \
            "${outside}/file" \
            "${stack_dir}" \
            2>&1
    )" || true

    [[ "${refused}" == *"Refusing to replace a path outside the stack"* ]] \
        || fail "Replace outside the stack was not refused: ${refused}"

    [[ "$(cat "${outside}/file")" == "leave-me" ]] \
        || fail "Rejected replace modified a file outside the stack."

    rm -rf "${work}"

    ok "Sync guards keep .env and refuse paths outside the stack."
}

test_script_modes()
{
    print_section "Script modes"

    local root
    local script
    local mode
    local indexed

    root="$(cd "${SCRIPT_DIR}/.." && pwd)"

    while IFS= read -r -d '' script
    do
        mode="$(stat -c '%a' "${script}")"
        [[ "${mode}" == "755" ]] \
            || fail "Script mode is ${mode}, expected 755: ${script}"

        indexed="$(git -C "${root}" ls-files -s -- "${script#"${root}/"}" || true)"
        if [[ -n "${indexed}" ]]; then
            [[ "${indexed}" == 100755* ]] \
                || fail "Git index mode is not 100755: ${indexed}"
        fi
    done < <(find "${root}/scripts" "${root}/configs" -name '*.sh' -print0)

    ok "Shell scripts are mode 755."
}

test_external_validators()
{
    print_section "External validators"

    local root
    local work

    root="$(cd "${SCRIPT_DIR}/.." && pwd)"

    if command -v docker >/dev/null 2>&1 \
        && docker compose version >/dev/null 2>&1; then

        work="$(mktemp -d)"
        cp "${root}/.env.example" "${work}/.env"
        sed -i 's/^NEXTCLOUD_BACKEND_BIND=.*/NEXTCLOUD_BACKEND_BIND=192.0.2.10/' "${work}/.env"

        docker compose \
            --env-file "${work}/.env" \
            -f "${root}/compose.yml" \
            config >/dev/null \
            || fail "docker compose config failed."

        rm -rf "${work}"
        ok "PROVEDENO: docker compose config"
    else
        log_not_performed "docker compose config. Docker Compose CLI is not installed, so Compose YAML was not validated."
    fi

    if command -v shellcheck >/dev/null 2>&1; then
        "${root}/scripts/shellcheck.sh" \
            || fail "shellcheck reported a problem."
        ok "PROVEDENO: shellcheck"
    else
        log_not_performed "shellcheck. The binary is not installed, so shell scripts were not linted."
    fi

    if command -v nginx >/dev/null 2>&1; then
        work="$(mktemp -d)"
        mkdir -p "${work}/conf.d"
        printf 'set_real_ip_from 192.0.2.1;\nreal_ip_header X-Forwarded-For;\n' > "${work}/real-ip.conf"
        if [[ -f /etc/nginx/mime.types ]]; then
            cp /etc/nginx/mime.types "${work}/mime.types"
        fi
        sed \
            -e "s#include /etc/nginx/real-ip.conf;#include ${work}/real-ip.conf;#" \
            -e "s#include mime.types;#include ${work}/mime.types;#" \
            "${root}/configs/nginx/nginx.conf" > "${work}/nginx.conf"
        nginx -t -p "${work}" -c "${work}/nginx.conf" \
            || fail "nginx -t rejected configs/nginx/nginx.conf."
        rm -rf "${work}"
        ok "PROVEDENO: nginx -t"
    elif command -v docker >/dev/null 2>&1 \
        && docker image inspect "docker.io/library/nginx:1.30.6-alpine" >/dev/null 2>&1; then
        work="$(mktemp -d)"
        printf 'set_real_ip_from 192.0.2.1;\nreal_ip_header X-Forwarded-For;\n' > "${work}/real-ip.conf"
        docker run --rm --network none \
            -v "${root}/configs/nginx/nginx.conf:/etc/nginx/conf.d/nextcloud.conf:ro" \
            -v "${work}/real-ip.conf:/etc/nginx/real-ip.conf:ro" \
            "docker.io/library/nginx:1.30.6-alpine" \
            nginx -t \
            || fail "nginx -t in the local nginx image rejected the configuration."
        rm -rf "${work}"
        ok "PROVEDENO: nginx -t in docker.io/library/nginx:1.30.6-alpine"
    else
        log_not_performed "nginx -t. Neither nginx nor a local nginx:1.30.6-alpine image is available, and no image was pulled."
    fi
}
