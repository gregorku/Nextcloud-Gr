#!/usr/bin/env bash

###############################################################################
#
# Authentik-netcup Project
#
# File:
#   scripts/lib/tests/static.sh
#
# Description:
#   Checks that read the Git checkout and temporary directories.
#
#   They do not require root, Docker, or the Incus container, and they
#   do not write to /docker-data.
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
    require_file "${root}/compose/20-authentik-server.yml"
    require_file "${root}/compose/30-authentik-worker.yml"
    require_file "${root}/configs/authentik/README.md"

    [[ ! -e "${root}/compose/50-grafana.yml" ]] \
        || fail "Grafana Compose file is still present."

    [[ ! -e "${root}/scripts/lib/deploy/sync.sh" ]] \
        || fail "Duplicate sync implementation is still present."

    [[ ! -e "${root}/scripts/lib/sync.sh" ]] \
        || fail "Duplicate sync implementation is still present."

    if grep -E -n 'docker[[:space:]]+(rm|stop)' \
        "${root}/scripts/install-dockge.sh" \
        "${root}/scripts/lib/deploy/dockge.sh"; then
        fail "Dockge install or deploy still stops or removes the container."
    fi

    ok "Repository layout OK."
}

test_env_example()
{
    print_section ".env.example"

    local root

    root="$(cd "${SCRIPT_DIR}/.." && pwd)"

    env_validate_file "${root}/.env.example" example

    local example_host
    local example_port

    example_host="$(
        awk -F= '$1 == "AUTHENTIK_HOST_IP" { print substr($0, index($0, "=") + 1); exit }' \
            "${root}/.env.example"
    )"

    example_port="$(
        awk -F= '$1 == "AUTHENTIK_HTTP_PORT" { print substr($0, index($0, "=") + 1); exit }' \
            "${root}/.env.example"
    )"

    [[ "${example_host}" == "${AUTHENTIK_HOST_IP}" ]] \
        || fail ".env.example host does not match config.sh."

    [[ "${example_port}" == "${AUTHENTIK_HTTP_PORT}" ]] \
        || fail ".env.example port does not match config.sh."

    ok ".env.example matches the variable policy."
}

test_runtime_placeholder_rejection()
{
    print_section "Placeholder rejection"

    local root
    local work
    local runtime

    root="$(cd "${SCRIPT_DIR}/.." && pwd)"
    work="$(mktemp -d)"
    runtime="${work}/.env"

    cp "${root}/.env.example" "${runtime}"

    #
    # The example is valid as an example and invalid as a deployment
    # file because of the set_* placeholders.
    #

    #
    # fail() exits. Run the check in a command substitution so a
    # rejected file does not abort this script, then require the
    # placeholder message. ENV_FILE is readonly in config.sh and must
    # not be assigned here.
    #

    local message

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

    grep -Fq '"${AUTHENTIK_HOST_IP}:${AUTHENTIK_HTTP_PORT}:9000"' \
        "${root}/compose/20-authentik-server.yml" \
        || fail "HTTP port is not bound to the Incus address."

    if grep -Eq '^[[:space:]]*ports:' "${root}/compose/10-postgresql.yml"; then
        fail "PostgreSQL Compose file publishes ports."
    fi

    if grep -R -n -E '9443:9443|5432:5432|6379:6379|/var/run/docker\.sock' \
        "${root}/compose" "${root}/compose.yml"; then
        fail "Compose publishes a forbidden port or mounts the Docker socket."
    fi

    if grep -R -n -E 'image:.*redis|container_name:.*redis' \
        "${root}/compose" "${root}/compose.yml"; then
        fail "Redis is still defined by Compose."
    fi

    ok "Compose bindings match the Authentik stack."

    if command -v docker >/dev/null 2>&1 \
        && docker compose version >/dev/null 2>&1; then

        docker compose \
            --env-file "${root}/.env.example" \
            -f "${root}/compose.yml" \
            config >/dev/null \
            || fail "docker compose config failed."

        ok "docker compose config accepted the project."
    else
        warn "Docker Compose CLI is not available. docker compose config was not executed."
    fi
}

test_sync_guards()
{
    print_section "Sync guards"

    assert_sync_paths

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
