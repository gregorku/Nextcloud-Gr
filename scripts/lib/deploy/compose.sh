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
# Return the initdb superuser. PostgreSQL assigns that role OID 10 and
# from version 16 refuses to clear its SUPERUSER attribute.
#
# A new cluster has only nc_bootstrap, so the admin login is first.
# Trying PG_USER before that role exists is recorded by PostgreSQL as
# FATAL and is not used to decide that the cluster is empty. The
# application login is only the fallback for a cluster whose OID 10
# is still PG_USER and which therefore has no nc_bootstrap role yet.
###############################################################################

deploy_read_bootstrap_name()
{
    local name=""

    if name="$(deploy_postgres_admin_value postgres \
        "SELECT rolname FROM pg_roles WHERE oid = 10" 2>/dev/null)" \
        && [[ -n "${name}" ]]
    then
        printf '%s\n' "${name}"
        return 0
    fi

    if name="$(deploy_postgres_value postgres \
        "SELECT rolname FROM pg_roles WHERE oid = 10")" \
        && [[ -n "${name}" ]]
    then
        printf '%s\n' "${name}"
        return 0
    fi

    return 1
}

###############################################################################
# PG_USER owns the application database and is not a superuser.
# Nextcloud would treat a superuser login as permission to create
# oc_admin, then fail while reading oc_migrations. Nothing is dropped
# except a non-OID-10 role named nc_bootstrap left by the previous
# attempt to add a second superuser.
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
    local bootstrap_name
    local present
    local app_oid
    local owner
    local owner_ident
    local action
    local owners
    local attributes
    local database_owner
    local schema_owner

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

    bootstrap_name="$(deploy_read_bootstrap_name)" \
        || fail "Could not read the initdb superuser. No data was deleted."

    if [[ "${bootstrap_name}" == "${db_user}" ]]; then
        info "OID 10 is ${db_user}. PostgreSQL 18 cannot remove its SUPERUSER attribute. Renaming it to ${POSTGRES_BOOTSTRAP_USER}."
        # One transaction. The extra nc_bootstrap from the failed
        # attempt is not OID 10, so dropping it does not remove the
        # initdb superuser. The renamed session remains superuser and
        # creates the application role before commit.
        # ALTER DATABASE cannot run inside a transaction block.
        # DROP, RENAME and CREATE commit together. Ownership follows.
        deploy_postgres_sql postgres \
            "BEGIN; DROP ROLE IF EXISTS ${boot_ident}; ALTER ROLE ${user_ident} RENAME TO ${boot_ident}; CREATE ROLE ${user_ident} LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD ${pass_literal}; COMMIT; ALTER DATABASE ${db_ident} OWNER TO ${user_ident}; GRANT CONNECT ON DATABASE ${db_ident} TO ${user_ident};" \
            || fail "Could not separate ${POSTGRES_BOOTSTRAP_USER} from ${db_user}. No data was deleted."
    elif [[ "${bootstrap_name}" != "${POSTGRES_BOOTSTRAP_USER}" ]]; then
        fail "The initdb superuser is ${bootstrap_name}, not ${POSTGRES_BOOTSTRAP_USER}. No data was deleted."
    fi

    deploy_postgres_admin_value postgres "SELECT 1" \
        || fail "Could not connect as ${POSTGRES_BOOTSTRAP_USER}. No data was deleted."

    # "postgres" is the maintenance database created by initdb.
    present="$(deploy_postgres_admin_value postgres \
        "SELECT 1 FROM pg_database WHERE datname = '${db_name}'")" \
        || fail "Could not read pg_database. No data was deleted."

    if [[ "${present}" != "1" ]]; then
        fail "Database ${db_name} does not exist in the initialized PostgreSQL data directory. Refusing to create another database automatically."
    fi

    app_oid="$(deploy_postgres_admin_value postgres \
        "SELECT oid FROM pg_roles WHERE rolname = '${db_user}'")" \
        || fail "Could not read pg_roles. No data was deleted."

    if [[ -n "${app_oid}" && ! "${app_oid}" =~ ^[0-9]+$ ]]; then
        fail "Refusing an unexpected role id for ${db_user}. No data was deleted."
    fi

    if [[ -z "${app_oid}" ]]; then
        info "Creating application role ${db_user} without SUPERUSER."
        deploy_postgres_admin_sql postgres \
            "CREATE ROLE ${user_ident} LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD ${pass_literal}; GRANT CONNECT ON DATABASE ${db_ident} TO ${user_ident};" \
            || fail "Could not create ${db_user}. No data was deleted."
    elif [[ "${app_oid}" == "10" ]]; then
        fail "Refusing to change SUPERUSER on the initdb role ${db_user}. No data was deleted."
    else
        # psql -tA separates the text columns with "|". PostgreSQL has
        # no || operator for integers, so the attributes stay text.
        attributes="$(deploy_postgres_admin_value postgres \
            "SELECT CASE WHEN rolsuper THEN 'yes' ELSE 'no' END, CASE WHEN rolcanlogin THEN 'yes' ELSE 'no' END, CASE WHEN rolcreatedb THEN 'yes' ELSE 'no' END, CASE WHEN rolcreaterole THEN 'yes' ELSE 'no' END FROM pg_roles WHERE oid = ${app_oid}")" \
            || fail "Could not read the attributes of ${db_user}. No data was deleted."

        if [[ "${attributes}" != "no|yes|no|no" ]]; then
            info "Setting ${db_user} to LOGIN without SUPERUSER, CREATEDB or CREATEROLE."
        fi

        deploy_postgres_admin_sql postgres \
            "ALTER ROLE ${user_ident} WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD ${pass_literal}; GRANT CONNECT ON DATABASE ${db_ident} TO ${user_ident};" \
            || fail "Could not set the privileges of ${db_user}. No data was deleted."
    fi

    database_owner="$(deploy_postgres_admin_value postgres \
        "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = '${db_name}'")" \
        || fail "Could not read the owner of ${db_name}. No data was deleted."

    if [[ "${database_owner}" != "${db_user}" ]]; then
        info "Database ${db_name} is owned by ${database_owner}. Moving ownership to ${db_user}."
        deploy_postgres_admin_sql postgres \
            "ALTER DATABASE ${db_ident} OWNER TO ${user_ident};" \
            || fail "Could not move ownership of ${db_name} to ${db_user}. No data was deleted."
    fi

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
        [[ "${owner}" == "${POSTGRES_BOOTSTRAP_USER}" ]] && continue

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

    deploy_postgres_admin_sql "${db_name}" \
        "DO \$nc\$ DECLARE r record; kind text; BEGIN FOR r IN SELECT c.relname, c.relkind FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public' AND c.relkind IN ('r','p','S','v','m') AND pg_get_userbyid(c.relowner) IS DISTINCT FROM '${db_user}' LOOP kind := CASE r.relkind WHEN 'S' THEN 'SEQUENCE' WHEN 'v' THEN 'VIEW' WHEN 'm' THEN 'MATERIALIZED VIEW' ELSE 'TABLE' END; EXECUTE format('ALTER %s public.%I OWNER TO %I', kind, r.relname, '${db_user}'); END LOOP; END \$nc\$;" \
        || fail "Could not move public relations to ${db_user}. No data was deleted."

    attributes="$(deploy_postgres_admin_value postgres \
        "SELECT CASE WHEN rolsuper THEN 'yes' ELSE 'no' END, CASE WHEN rolcanlogin THEN 'yes' ELSE 'no' END, CASE WHEN rolcreatedb THEN 'yes' ELSE 'no' END, CASE WHEN rolcreaterole THEN 'yes' ELSE 'no' END FROM pg_roles WHERE rolname = '${db_user}' AND oid <> 10")" \
        || fail "Could not verify ${db_user}. No data was deleted."
    database_owner="$(deploy_postgres_admin_value postgres \
        "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = '${db_name}'")" \
        || fail "Could not verify the owner of ${db_name}. No data was deleted."
    schema_owner="$(deploy_postgres_admin_value "${db_name}" \
        "SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'public'")" \
        || fail "Could not verify the owner of schema public. No data was deleted."

    [[ -n "${attributes}" ]] \
        || fail "Role ${db_user} was not found after setup. No data was deleted."
    [[ "${attributes}" == "no|yes|no|no" && "${database_owner}" == "${db_user}" \
        && "${schema_owner}" == "${db_user}" ]] \
        || fail "PostgreSQL role ${db_user} is not a LOGIN owner without SUPERUSER. No data was deleted."

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
# Path the installer treats as the admin home. occ maintenance:install
# refuses to create that user when the path already exists and reports
# "Login is invalid because files already exist for this user".
#
# Arguments:
#   $1 - Host data directory mounted at /var/www/html/data
#   $2 - NEXTCLOUD_ADMIN_USER
#
# Prints the path when it exists. Returns 1 when the install can create
# the user. Returns 2 when the username is not a single path component.
###############################################################################

deploy_existing_admin_home()
{
    local data_dir="$1"
    local admin_user="$2"
    local home

    [[ "${admin_user}" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || return 2
    [[ "${admin_user}" != "." && "${admin_user}" != ".." ]] || return 2

    home="${data_dir%/}/${admin_user}"
    if [[ -e "${home}" || -L "${home}" ]]; then
        printf '%s\n' "${home}"
        return 0
    fi

    return 1
}

###############################################################################
# An unfinished install must not already contain the admin account.
# createUser() fails for an existing home directory and for an existing
# uid, and the image entrypoint prints the files message for both.
# Returns 0 and prints the table name when the uid is present.
# Returns 1 when the account tables are absent or do not contain it.
# Returns 2 when the catalog cannot be read.
###############################################################################

deploy_database_has_admin_uid()
{
    local database="$1"
    local admin_user="$2"
    local uid_literal
    local table
    local present
    local row

    uid_literal="$(deploy_sql_literal "${admin_user}")" || return 2

    for table in oc_accounts oc_users
    do
        present="$(deploy_postgres_value "${database}" \
            "SELECT COALESCE(to_regclass('public.${table}')::text, '')")" || return 2
        [[ -n "${present}" ]] || continue

        row="$(deploy_postgres_value "${database}" \
            "SELECT 1 FROM ${table} WHERE uid = ${uid_literal} LIMIT 1")" || return 2
        if [[ "${row}" == "1" ]]; then
            printf '%s\n' "${table}"
            return 0
        fi
    done

    return 1
}

deploy_assert_new_install_can_create_admin()
{
    local data_dir
    local html_dir
    local admin_user
    local db_name
    local home=""
    local table=""
    local status=0
    local conflict=""

    if nextcloud_config_marked_installed \
        "${NEXTCLOUD_HTML_DIR}/config/config.php"
    then
        return 0
    fi

    data_dir="$(env_get NEXTCLOUD_DATA_HOST_DIR)"
    html_dir="$(env_get NEXTCLOUD_HTML_HOST_DIR)"
    admin_user="$(env_get NEXTCLOUD_ADMIN_USER)"
    db_name="$(env_get PG_DB)"

    if [[ -d "${data_dir}" && -d "${html_dir}" \
        && "$(realpath "${data_dir}")" == "$(realpath "${html_dir}")" ]]
    then
        compose_cmd stop "${NEXTCLOUD_SERVICE}" >/dev/null 2>&1 || true
        fail "NEXTCLOUD_DATA_HOST_DIR and the HTML directory are the same path. The data mount would hide /var/www/html/data with the code tree. Nothing was deleted."
    fi

    if home="$(deploy_existing_admin_home "${data_dir}" "${admin_user}")"; then
        conflict="admin home ${home}"
    else
        status=$?
        [[ "${status}" -eq 1 ]] \
            || fail "NEXTCLOUD_ADMIN_USER cannot be used as a data directory name. Nothing was deleted."
    fi

    status=0
    if table="$(deploy_database_has_admin_uid "${db_name}" "${admin_user}")"; then
        conflict="${conflict:+${conflict}; }uid ${admin_user} in ${table}"
    else
        status=$?
        [[ "${status}" -eq 1 ]] \
            || fail "Could not check whether ${admin_user} already exists in PostgreSQL. Nextcloud was not started. No data was deleted."
    fi

    if [[ -n "${conflict}" ]]; then
        compose_cmd stop "${NEXTCLOUD_SERVICE}" >/dev/null 2>&1 || true
        fail "Nextcloud is not installed, but the installer cannot create ${admin_user}: ${conflict}. occ reports that as \"Login is invalid because files already exist for this user\" and retries. Remove only that leftover admin home from a failed install, then run deploy again. Nothing was deleted."
    fi
}

###############################################################################
# The image entrypoint retries maintenance:install after a database
# error. A permission failure is not an unfinished wait: stop the
# application container so it does not create another oc_* role.
# The same stop applies when the admin home or account already exists.
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

        if printf '%s\n' "${logs}" | grep -q 'Login is invalid because files already exist for this user'; then
            compose_cmd stop "${NEXTCLOUD_SERVICE}" >/dev/null 2>&1 || true
            fail "Nextcloud installation found an existing admin home or account for $(env_get NEXTCLOUD_ADMIN_USER) under $(env_get NEXTCLOUD_DATA_HOST_DIR). The container was stopped. Nothing was deleted."
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
    deploy_assert_new_install_can_create_admin

    log_info "Starting the remaining services."

    compose_up
    deploy_wait_nextcloud_install

    log_success "Nextcloud-Gr started."
}
