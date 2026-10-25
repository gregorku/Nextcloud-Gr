#!/usr/bin/env bash

###############################################################################
#
# Nextcloud-Gr
#
# File:
#   scripts/lib/deploy/compose.sh
#
# Description:
#   Validate, pull and start the Nextcloud Compose stack.
#
#   deploy.sh is the only command that starts the stack. These
#   functions are not called by init.sh or by the static tests.
#
###############################################################################

deploy_validate_compose()
{
    print_section "Compose validation"

    check_compose_configuration
}

###############################################################################
# Quote a PostgreSQL identifier or literal. Names are restricted to the
# role form accepted by postgres_owner_action.
###############################################################################

deploy_sql_ident()
{
    local value="$1"

    [[ "${value}" =~ ^[A-Za-z_][A-Za-z0-9_]{0,62}$ ]] || return 1
    printf '"%s"' "${value}"
}

deploy_sql_literal()
{
    local value="$1"

    [[ "${value}" != *$'\n'* ]] || return 1
    value="${value//\'/\'\'}"
    printf "'%s'" "${value}"
}

###############################################################################
# Run SQL as the local postgres superuser. The password is not an argument.
###############################################################################

deploy_postgres_sql()
{
    local database="$1"
    local sql="$2"

    docker exec -u postgres -i "${POSTGRESQL_CONTAINER}" \
        psql -v ON_ERROR_STOP=1 -q -d "${database}" -f - \
        <<<"${sql}"
}

deploy_postgres_value()
{
    local database="$1"
    local sql="$2"

    docker exec -u postgres -i "${POSTGRESQL_CONTAINER}" \
        psql -v ON_ERROR_STOP=1 -q -tA -d "${database}" -f - \
        <<<"${sql}"
}

deploy_wait_postgres()
{
    local attempt=0
    local status=""

    while [[ "${attempt}" -lt 30 ]]
    do
        status="$(
            docker inspect \
                --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
                "${POSTGRESQL_CONTAINER}" 2>/dev/null || true
        )"
        [[ "${status}" == "healthy" ]] && return 0
        attempt=$((attempt + 1))
        sleep 2
    done

    fail "PostgreSQL did not become healthy. Nextcloud was not started and no data directory was deleted."
}

###############################################################################
# Make PG_USER the owner of existing Nextcloud tables. Creates the role
# when it is missing, without SUPERUSER. Does not drop databases, roles
# or files.
###############################################################################

deploy_align_database_owner()
{
    local db_name
    local db_user
    local db_pass
    local db_ident
    local user_ident
    local pass_literal
    local present
    local owner
    local owner_ident
    local action
    local owners

    db_name="$(env_get PG_DB)"
    db_user="$(env_get PG_USER)"
    db_pass="$(env_get PG_PASS)"

    db_ident="$(deploy_sql_ident "${db_name}")" \
        || fail "PG_DB is not a usable PostgreSQL name."
    user_ident="$(deploy_sql_ident "${db_user}")" \
        || fail "PG_USER is not a usable PostgreSQL name."
    pass_literal="$(deploy_sql_literal "${db_pass}")" \
        || fail "PG_PASS cannot be sent to PostgreSQL."

    [[ "${db_user}" != "postgres" && "${db_user}" != "root" ]] \
        || fail "PG_USER must be the application role, not ${db_user}."

    present="$(deploy_postgres_value postgres \
        "SELECT 1 FROM pg_database WHERE datname = '${db_name}'")" \
        || fail "Could not read pg_database. No data was deleted."

    if [[ "${present}" != "1" ]]; then
        fail "Database ${db_name} does not exist in the initialized PostgreSQL data directory. Refusing to create another database automatically."
    fi

    owners="$(deploy_postgres_value "${db_name}" \
        "SELECT DISTINCT pg_get_userbyid(c.relowner) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public' AND c.relkind IN ('r','S','p') AND c.relname LIKE 'oc\\_%' ORDER BY 1")" \
        || fail "Could not read Nextcloud table owners. No data was deleted."

    if [[ -z "${owners}" ]]; then
        info "No Nextcloud tables exist yet. The PostgreSQL data directory was not changed."
        return 0
    fi

    if ! deploy_postgres_value postgres \
        "SELECT 1 FROM pg_roles WHERE rolname = '${db_user}'" | grep -qx 1
    then
        info "Creating application role ${db_user} without SUPERUSER."
        deploy_postgres_sql postgres \
            "CREATE ROLE ${user_ident} LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD ${pass_literal}; GRANT CONNECT ON DATABASE ${db_ident} TO ${user_ident};" \
            || fail "Could not create ${db_user}. No data was deleted."
    else
        deploy_postgres_sql postgres \
            "ALTER ROLE ${user_ident} WITH LOGIN PASSWORD ${pass_literal};" \
            || fail "Could not set the password of ${db_user}. No data was deleted."
    fi

    while IFS= read -r owner
    do
        [[ -n "${owner}" ]] || continue
        action="$(postgres_owner_action "${owner}" "${db_user}")" \
            || fail "Refusing to change ownership for role ${owner}."

        if [[ "${action}" == "aligned" ]]; then
            continue
        fi

        owner_ident="$(deploy_sql_ident "${owner}")" \
            || fail "Table owner ${owner} is not a usable PostgreSQL name."

        info "Nextcloud objects owned by ${owner} are reassigned to ${db_user}. Files and rows are not deleted."
        deploy_postgres_sql "${db_name}" \
            "REASSIGN OWNED BY ${owner_ident} TO ${user_ident}; GRANT USAGE, CREATE ON SCHEMA public TO ${user_ident}; GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO ${user_ident}; GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO ${user_ident};" \
            || fail "Could not reassign Nextcloud objects from ${owner} to ${db_user}. No data was deleted."
    done <<< "${owners}"

    ok "Nextcloud database objects are usable by ${db_user}."
}

deploy_compose()
{
    print_section "Nextcloud-Gr"

    log_info "Pulling pinned images..."

    compose_pull

    log_info "Starting PostgreSQL before the application."

    compose_up "${POSTGRESQL_SERVICE}"
    deploy_wait_postgres
    deploy_align_database_owner

    log_info "Starting the remaining services."

    compose_up

    log_success "Nextcloud-Gr started."
}
