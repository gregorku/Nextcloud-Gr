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

    ok "Compose bindings match the Nextcloud stack."

    if command -v docker >/dev/null 2>&1 \
        && docker compose version >/dev/null 2>&1; then

        local work
        work="$(mktemp -d)"
        cp "${root}/.env.example" "${work}/.env"
        sed -i 's/^NEXTCLOUD_BACKEND_BIND=.*/NEXTCLOUD_BACKEND_BIND=192.0.2.10/' "${work}/.env"

        docker compose \
            --env-file "${work}/.env" \
            -f "${root}/compose.yml" \
            config >/dev/null \
            || fail "docker compose config failed."

        rm -rf "${work}"
        ok "docker compose config accepted the project."
    else
        warn "Docker Compose CLI is not available. docker compose config was not executed."
    fi
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

    local refused

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
