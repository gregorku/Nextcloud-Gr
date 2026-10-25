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
# Run SQL. The password is not an argument. A connection failure is a
# failure of the function, not an empty result.
###############################################################################

deploy_postgres_sql()
{
    local database="$1"
    local sql="$2"

    postgres_container_client "${database}" \
        psql -v ON_ERROR_STOP=1 -q -f - \
        <<<"${sql}"
}

deploy_postgres_value()
{
    local database="$1"
    local sql="$2"

    postgres_container_client "${database}" \
        psql -v ON_ERROR_STOP=1 -q -tA -f - \
        <<<"${sql}"
}

deploy_postgres_admin_sql()
{
    local database="$1"
    local sql="$2"

    postgres_container_admin "${database}" \
        psql -v ON_ERROR_STOP=1 -q -f - \
        <<<"${sql}"
}

deploy_postgres_admin_value()
{
    local database="$1"
    local sql="$2"

    postgres_container_admin "${database}" \
        psql -v ON_ERROR_STOP=1 -q -tA -f - \
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
# PG_USER must own the application database and must not be a superuser.
# The official image's initdb user is a superuser. Nextcloud treats that
# as permission to create oc_admin, then reads oc_migrations as oc_admin
# while the table belongs to the other role. The bootstrap role keeps
# SUPERUSER. Nothing is dropped.
###############################################################################

deploy_align_database_owner()
{
    local db_name
    local db_user
    local db_pass
    local db_ident
    local user_ident
    local boot_ident
    local pass_literal
    local present
    local superuser
    local bootstrap
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
    boot_ident="$(deploy_sql_ident "${POSTGRES_BOOTSTRAP_USER}")" \
        || fail "The cluster superuser name is not a usable PostgreSQL name."
    pass_literal="$(deploy_sql_literal "${db_pass}")" \
        || fail "PG_PASS cannot be sent to PostgreSQL."

    [[ "${db_user}" != "postgres" && "${db_user}" != "root" \
        && "${db_user}" != "${POSTGRES_BOOTSTRAP_USER}" ]] \
        || fail "PG_USER must be the application role, not ${db_user}."

    # "postgres" is the maintenance database created by initdb.
    # The login role is PG_USER, not a role named postgres.
    present="$(deploy_postgres_value postgres \
        "SELECT 1 FROM pg_database WHERE datname = '${db_name}'")" \
        || fail "Could not read pg_database. No data was deleted."

    if [[ "${present}" != "1" ]]; then
        fail "Database ${db_name} does not exist in the initialized PostgreSQL data directory. Refusing to create another database automatically."
    fi

    superuser="$(deploy_postgres_value postgres \
        "SELECT CASE WHEN rolsuper THEN 1 ELSE 0 END FROM pg_roles WHERE rolname = current_user")" \
        || fail "Could not read the privileges of ${db_user}. No data was deleted."

    if [[ "${superuser}" == "1" ]]; then
        bootstrap="$(deploy_postgres_value postgres \
            "SELECT 1 FROM pg_roles WHERE rolname = '${POSTGRES_BOOTSTRAP_USER}'")" \
            || fail "Could not read pg_roles. No data was deleted."

        if [[ "${bootstrap}" != "1" ]]; then
            info "Creating cluster superuser ${POSTGRES_BOOTSTRAP_USER} so ${db_user} does not stay a superuser."
            deploy_postgres_sql postgres \
                "CREATE ROLE ${boot_ident} LOGIN SUPERUSER PASSWORD ${pass_literal};" \
                || fail "Could not create ${POSTGRES_BOOTSTRAP_USER}. No data was deleted."
        fi
    fi

    deploy_postgres_admin_value postgres "SELECT 1" \
        || fail "Could not connect as ${POSTGRES_BOOTSTRAP_USER}. No data was deleted."

    info "Application role ${db_user} is LOGIN without SUPERUSER and owns ${db_name}."
    deploy_postgres_admin_sql postgres \
        "ALTER ROLE ${user_ident} WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD ${pass_literal}; ALTER DATABASE ${db_ident} OWNER TO ${user_ident}; GRANT CONNECT ON DATABASE ${db_ident} TO ${user_ident};" \
        || fail "Could not set the privileges of ${db_user}. No data was deleted."

    deploy_postgres_admin_sql "${db_name}" \
        "ALTER SCHEMA public OWNER TO ${user_ident}; GRANT USAGE, CREATE ON SCHEMA public TO ${user_ident}; GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO ${user_ident}; GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO ${user_ident}; ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON TABLES TO ${user_ident}; ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON SEQUENCES TO ${user_ident};" \
        || fail "Could not grant ${db_user} access to schema public. No data was deleted."

    owners="$(deploy_postgres_admin_value "${db_name}" \
        "SELECT DISTINCT pg_get_userbyid(c.relowner) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public' AND c.relkind IN ('r','S','p') AND c.relname LIKE 'oc\\_%' ORDER BY 1")" \
        || fail "Could not read Nextcloud table owners. No data was deleted."

    if [[ -z "${owners}" ]]; then
        info "No Nextcloud tables exist yet. ${db_user} will create them. Nothing was deleted."
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
        deploy_postgres_admin_sql "${db_name}" \
            "REASSIGN OWNED BY ${owner_ident} TO ${user_ident}; GRANT USAGE, CREATE ON SCHEMA public TO ${user_ident}; GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO ${user_ident}; GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO ${user_ident};" \
            || fail "Could not reassign Nextcloud objects from ${owner} to ${db_user}. No data was deleted."
    done <<< "${owners}"

    ok "Nextcloud database objects are usable by ${db_user}."

    if [[ -f "${NEXTCLOUD_HTML_DIR}/config/config.php" ]]; then
        nextcloud_config_set_database \
            "${NEXTCLOUD_HTML_DIR}/config/config.php" \
            "${db_name}" \
            "${db_user}" \
            "${db_pass}" \
            "postgresql" \
            || fail "config.php database identity was not updated. No data directory was deleted."
        info "config.php now uses ${db_user} on ${db_name}. The installed flag was not changed."
    fi
}

###############################################################################
# The image entrypoint retries maintenance:install after a database
# error. A permission failure is not an unfinished wait: stop the
# application container so it does not create another oc_* role.
# Health staying "starting" during start_period is not success.
###############################################################################

deploy_wait_nextcloud_install()
{
    local attempt=0
    local status=""
    local started=""
    local logs=""

    while [[ "${attempt}" -lt 150 ]]
    do
        started="$(
            docker inspect \
                --format '{{.State.StartedAt}}' \
                "${NEXTCLOUD_APP_CONTAINER}" 2>/dev/null || true
        )"
        logs="$(
            docker logs --since "${started:-0s}" \
                "${NEXTCLOUD_APP_CONTAINER}" 2>&1 || true
        )"

        if printf '%s\n' "${logs}" | grep -q 'permission denied for table oc_migrations'; then
            compose_cmd stop "${NEXTCLOUD_SERVICE}" >/dev/null 2>&1 || true
            fail "Nextcloud was denied access to oc_migrations. Installation stopped. No data was deleted."
        fi

        if printf '%s\n' "${logs}" | grep -q 'Installing of nextcloud failed'; then
            compose_cmd stop "${NEXTCLOUD_SERVICE}" >/dev/null 2>&1 || true
            fail "Nextcloud installation failed. It was not recorded as installed. No data was deleted."
        fi

        status="$(
            docker inspect \
                --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
                "${NEXTCLOUD_APP_CONTAINER}" 2>/dev/null || true
        )"
        [[ "${status}" == "healthy" ]] && return 0

        attempt=$((attempt + 1))
        sleep 2
    done

    fail "Nextcloud did not become healthy after installation. State was not recorded and no data was deleted."
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
    deploy_wait_nextcloud_install

    log_success "Nextcloud-Gr started."
}
