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
# Path the installer treats as the admin home.
#
# Nextcloud 35 User\Manager::validateUserId($uid, true) rejects the
# login when file_exists(datadirectory/uid). maintenance:install reports
# that as "Login is invalid because files already exist for this user".
# The directory is created while createUser runs, and installed => true
# is written only after the later steps. A new PostgreSQL cluster does
# not remove this directory: it lives on NEXTCLOUD_DATA_HOST_DIR.
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
# installed / home / uid -> what deploy may do.
# installed: do not install and do not move the real admin home.
# install: first install, maintenance:install once.
# preserve-then-install: the home is not a database account. Rename it
# out of the uid path and keep the files, then install once.
# blocked: the account already exists but Nextcloud is not installed.
# maintenance:install cannot create it again. Nothing is deleted.
#
# Arguments:
#   $1 - true or false, from config.php installed => true
#   $2 - present or absent
#   $3 - present or absent
###############################################################################

deploy_install_action()
{
    local installed="$1"
    local home="$2"
    local uid="$3"

    case "${installed}:${home}:${uid}" in
        true:*)
            printf 'installed\n'
            ;;
        false:absent:absent)
            printf 'install\n'
            ;;
        false:present:absent)
            printf 'preserve-then-install\n'
            ;;
        false:absent:present|false:present:present)
            printf 'blocked\n'
            ;;
        *)
            return 1
            ;;
    esac
}

###############################################################################
# Move an unfinished admin home aside. The bytes stay in the data
# directory under a name that is not the uid. Returns 1 when the home
# is absent. Returns 2 when the username is illegal or the destination
# already exists. Prints the destination on success.
###############################################################################

deploy_preserve_orphan_admin_home()
{
    local data_dir="$1"
    local admin_user="$2"
    local home
    local dest
    local status=0

    if ! home="$(deploy_existing_admin_home "${data_dir}" "${admin_user}")"; then
        status=$?
        return "${status}"
    fi

    dest="${data_dir%/}/.incomplete-${admin_user}-$(date +%Y%m%d%H%M%S)"
    if [[ -e "${dest}" || -L "${dest}" ]]; then
        printf '%s\n' "${dest}"
        return 2
    fi

    mv -- "${home}" "${dest}" || return 2
    printf '%s\n' "${dest}"
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

###############################################################################
# Stop a previous application process before an unfinished install.
# restart: unless-stopped does not restart a container stopped here.
# PostgreSQL stays up. Nothing is deleted.
###############################################################################

deploy_stop_application()
{
    compose_cmd stop \
        "${NEXTCLOUD_SERVICE}" \
        "${CRON_SERVICE}" \
        "${NGINX_SERVICE}" \
        >/dev/null 2>&1 || true
}

deploy_prepare_unfinished_install()
{
    local data_dir
    local html_dir
    local admin_user
    local db_name
    local installed="false"
    local home_state="absent"
    local uid_state="absent"
    local home=""
    local table=""
    local action
    local preserved
    local status=0

    data_dir="$(env_get NEXTCLOUD_DATA_HOST_DIR)"
    html_dir="$(env_get NEXTCLOUD_HTML_HOST_DIR)"
    admin_user="$(env_get NEXTCLOUD_ADMIN_USER)"
    db_name="$(env_get PG_DB)"

    if [[ -d "${data_dir}" && -d "${html_dir}" \
        && "$(realpath "${data_dir}")" == "$(realpath "${html_dir}")" ]]
    then
        deploy_stop_application
        fail "NEXTCLOUD_DATA_HOST_DIR and the HTML directory are the same path. The data mount would hide /var/www/html/data with the code tree. Nothing was deleted."
    fi

    if nextcloud_config_marked_installed \
        "${NEXTCLOUD_HTML_DIR}/config/config.php"
    then
        installed="true"
    fi

    if home="$(deploy_existing_admin_home "${data_dir}" "${admin_user}")"; then
        home_state="present"
    else
        status=$?
        [[ "${status}" -eq 1 ]] \
            || fail "NEXTCLOUD_ADMIN_USER cannot be used as a data directory name. Nothing was deleted."
    fi

    if [[ "${installed}" == "true" ]]; then
        info "Nextcloud is already installed. The admin home is left in place."
        return 0
    fi

    status=0
    if table="$(deploy_database_has_admin_uid "${db_name}" "${admin_user}")"; then
        uid_state="present"
    else
        status=$?
        [[ "${status}" -eq 1 ]] \
            || fail "Could not check whether ${admin_user} already exists in PostgreSQL. Nextcloud was not started. No data was deleted."
    fi

    action="$(deploy_install_action "${installed}" "${home_state}" "${uid_state}")" \
        || fail "Install state could not be classified. Nothing was deleted."

    case "${action}" in
        install)
            info "Nextcloud is not installed. maintenance:install will run once."
            deploy_stop_application
            ;;
        preserve-then-install)
            deploy_stop_application
            if ! preserved="$(deploy_preserve_orphan_admin_home "${data_dir}" "${admin_user}")"; then
                fail "Could not preserve ${home}. Nothing was deleted."
            fi
            info "Preserved unfinished admin home ${home} as ${preserved}. PostgreSQL has no ${admin_user} account, so the directory is not a user. Nextcloud refuses createUser while datadirectory/${admin_user} exists. The files were renamed, not deleted."
            ;;
        blocked)
            deploy_stop_application
            fail "Nextcloud is not installed, but ${admin_user} is already in ${table}${home:+ (${home})}. maintenance:install cannot create that account again and this deploy does not delete it. For this test instance run ./scripts/reset-test.sh --confirm ${STACK_NAME}. Nothing was deleted."
            ;;
        *)
            fail "Unexpected install action ${action}. Nothing was deleted."
            ;;
    esac
}

###############################################################################
# One maintenance:install. The image entrypoint must not do this: its
# ten retries turn the admin home created by the first attempt into
# "Login is invalid because files already exist for this user", and the
# next container start sees version.php and skips installation.
###############################################################################

deploy_run_maintenance_install()
{
    local secret
    local log
    local status=0

    secret="$(mktemp)"
    log="$(mktemp)"
    chmod 600 "${secret}" "${log}"

    # Host .env names (PG_*) are not the names the image documents.
    # Pass the image names explicitly. docker exec does not print them.
    printf 'NEXTCLOUD_ADMIN_USER=%s\nNEXTCLOUD_ADMIN_PASSWORD=%s\nPOSTGRES_DB=%s\nPOSTGRES_USER=%s\nPOSTGRES_PASSWORD=%s\nPOSTGRES_HOST=postgresql\n' \
        "$(env_get NEXTCLOUD_ADMIN_USER)" \
        "$(env_get NEXTCLOUD_ADMIN_PASSWORD)" \
        "$(env_get PG_DB)" \
        "$(env_get PG_USER)" \
        "$(env_get PG_PASS)" \
        > "${secret}"

    if ! docker exec -u www-data --env-file "${secret}" \
        "${NEXTCLOUD_APP_CONTAINER}" \
        sh -c 'php /var/www/html/occ maintenance:install -n --admin-user "$NEXTCLOUD_ADMIN_USER" --admin-pass "$NEXTCLOUD_ADMIN_PASSWORD" --data-dir /var/www/html/data --database pgsql --database-name "$POSTGRES_DB" --database-user "$POSTGRES_USER" --database-pass "$POSTGRES_PASSWORD" --database-host "$POSTGRES_HOST"' \
        > "${log}" 2>&1
    then
        status=1
    fi

    rm -f "${secret}"

    if [[ "${status}" -ne 0 ]]; then
        cat "${log}"
        rm -f "${log}"
        deploy_stop_application
        fail "maintenance:install failed. Nextcloud was not recorded as installed. Nothing was deleted."
    fi

    rm -f "${log}"
}

deploy_set_trusted_domains()
{
    local domains
    local domain
    local index=1

    domains="$(env_get NEXTCLOUD_TRUSTED_DOMAINS)"
    [[ -n "${domains}" ]] \
        || fail "NEXTCLOUD_TRUSTED_DOMAINS is empty. Installation was not recorded."

    set -f
    # Domains are separated by spaces. Globbing is off for this loop.
    # shellcheck disable=SC2086
    for domain in ${domains}
    do
        [[ "${domain}" =~ ^[A-Za-z0-9.-]{1,253}$ ]] \
            || fail "NEXTCLOUD_TRUSTED_DOMAINS contains ${domain}. Installation was not recorded."
        nextcloud_occ config:system:set trusted_domains "${index}" --value="${domain}" \
            >/dev/null \
            || fail "Could not set trusted domain ${domain}. Installation was not recorded."
        index=$((index + 1))
    done
    set +f
}

###############################################################################
# Port 9000 opens only after the entrypoint has exec'd php-fpm.
# occ can answer earlier, while that entrypoint is still copying
# /var/www/html. Installing in that window races the copy.
###############################################################################

deploy_php_fpm_is_listening()
{
    docker exec "${NEXTCLOUD_APP_CONTAINER}" \
        php -r 'exit(@fsockopen("127.0.0.1", 9000) ? 0 : 1);' \
        >/dev/null 2>&1
}

###############################################################################
# Rename only an admin home that has no database account.
# Does not stop the container and does not touch any other directory,
# including a previous .incomplete-* preserve.
###############################################################################

deploy_preserve_orphan_admin_if_needed()
{
    local data_dir
    local admin_user
    local db_name
    local home=""
    local table=""
    local preserved
    local status=0

    if nextcloud_config_marked_installed \
        "${NEXTCLOUD_HTML_DIR}/config/config.php"
    then
        return 0
    fi

    data_dir="$(env_get NEXTCLOUD_DATA_HOST_DIR)"
    admin_user="$(env_get NEXTCLOUD_ADMIN_USER)"
    db_name="$(env_get PG_DB)"

    if ! home="$(deploy_existing_admin_home "${data_dir}" "${admin_user}")"; then
        status=$?
        [[ "${status}" -eq 1 ]] && return 0
        fail "NEXTCLOUD_ADMIN_USER cannot be used as a data directory name. Nothing was deleted."
    fi

    if table="$(deploy_database_has_admin_uid "${db_name}" "${admin_user}")"; then
        fail "Nextcloud is not installed, but ${admin_user} is already in ${table} (${home}). maintenance:install cannot create that account again. Run ./scripts/reset-test.sh --confirm ${STACK_NAME} for this test instance. Nothing was deleted."
    else
        status=$?
        [[ "${status}" -eq 1 ]] \
            || fail "Could not check whether ${admin_user} already exists in PostgreSQL. Nothing was deleted."
    fi

    preserved="$(deploy_preserve_orphan_admin_home "${data_dir}" "${admin_user}")" \
        || fail "Could not preserve ${home}. Nothing was deleted."
    info "Preserved unfinished admin home ${home} as ${preserved}. PostgreSQL has no ${admin_user} account. The files were renamed, not deleted."
}

deploy_install_nextcloud_if_needed()
{
    local attempt=0
    local installed=""

    while [[ "${attempt}" -lt 150 ]]
    do
        if deploy_php_fpm_is_listening; then
            installed="$(nextcloud_occ_status_value installed 2>/dev/null || true)"
            if [[ "${installed}" == "true" || "${installed}" == "false" ]]; then
                break
            fi
        fi
        installed=""
        attempt=$((attempt + 1))
        sleep 2
    done

    [[ -n "${installed}" ]] \
        || fail "PHP-FPM did not stay up long enough for occ status. Nextcloud was not recorded as installed. No data was deleted."

    if [[ "${installed}" == "true" ]]; then
        if ! nextcloud_config_marked_installed \
            "${NEXTCLOUD_HTML_DIR}/config/config.php"
        then
            fail "occ reports installed but config.php has no installed flag. Refusing to run maintenance:install. Nothing was deleted."
        fi
        info "Nextcloud is already installed. maintenance:install was not run."
        return 0
    fi

    if nextcloud_config_marked_installed \
        "${NEXTCLOUD_HTML_DIR}/config/config.php"
    then
        fail "config.php is installed but occ reports installed: ${installed}. Refusing to run maintenance:install. Nothing was deleted."
    fi

    info "Running maintenance:install once."
    deploy_preserve_orphan_admin_if_needed
    deploy_run_maintenance_install
    deploy_set_trusted_domains
    docker exec "${NEXTCLOUD_APP_CONTAINER}" \
        sh /docker-entrypoint-hooks.d/post-installation/10-apcu.sh \
        || fail "The APCu hook failed after installation. State was not recorded. No data was deleted."
}

###############################################################################
# Port 9000 and HTTP 200 are not an installation. occ, config.php,
# the admin account and cron must agree before deploy succeeds.
###############################################################################

deploy_require_running_install()
{
    local attempt=0
    local installed=""
    local versionstring=""
    local expected
    local data_dir
    local admin_user
    local table=""
    local cron_health=""
    local body

    data_dir="$(env_get NEXTCLOUD_DATA_HOST_DIR)"
    admin_user="$(env_get NEXTCLOUD_ADMIN_USER)"
    expected="$(upgrade_release_number "$(env_get NEXTCLOUD_TAG)")" \
        || fail "NEXTCLOUD_TAG is not an exact X.Y.Z-fpm release. State was not recorded."

    while [[ "${attempt}" -lt 30 ]]
    do
        installed="$(nextcloud_occ_status_value installed 2>/dev/null || true)"
        [[ "${installed}" == "true" ]] && break
        attempt=$((attempt + 1))
        sleep 2
    done

    [[ "${installed}" == "true" ]] \
        || fail "occ status installed is '${installed:-unset}'. Deploy does not call this a successful installation. No data was deleted."

    versionstring="$(nextcloud_occ_status_value versionstring 2>/dev/null || true)"
    [[ "${versionstring}" == "${expected}" ]] \
        || fail "occ versionstring is '${versionstring:-unset}', expected ${expected}. State was not recorded."

    nextcloud_config_marked_installed \
        "${NEXTCLOUD_HTML_DIR}/config/config.php" \
        || fail "config.php has no installed => true. State was not recorded. No data was deleted."

    grep -Eq \
        "['\"]datadirectory['\"][[:space:]]*=>[[:space:]]*['\"]/var/www/html/data['\"]" \
        "${NEXTCLOUD_HTML_DIR}/config/config.php" \
        || fail "config.php datadirectory is not /var/www/html/data. The data mount and the installer disagree. No data was deleted."

    if ! table="$(deploy_database_has_admin_uid "$(env_get PG_DB)" "${admin_user}")"; then
        fail "PostgreSQL has no ${admin_user} account after installation. State was not recorded. No data was deleted."
    fi

    deploy_existing_admin_home "${data_dir}" "${admin_user}" >/dev/null \
        || fail "Installation did not create the admin home for ${admin_user}. No data was deleted."

    ok "Nextcloud is installed. ${admin_user} is in ${table}."

    attempt=0
    while [[ "${attempt}" -lt 90 ]]
    do
        cron_health="$(
            docker inspect \
                --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
                "${NEXTCLOUD_CRON_CONTAINER}" 2>/dev/null || true
        )"
        [[ "${cron_health}" == "healthy" ]] && break
        attempt=$((attempt + 1))
        sleep 2
    done

    [[ "${cron_health}" == "healthy" ]] \
        || fail "Cron health is '${cron_health:-unset}'. occ status in that healthcheck requires installed: true. State was not recorded."

    ok "Cron is running against the installed instance."

    require_command curl
    attempt=0
    body=""
    while [[ "${attempt}" -lt 30 ]]
    do
        if body="$(curl -fsS "http://$(env_get NEXTCLOUD_BACKEND_BIND):$(env_get NEXTCLOUD_BACKEND_PORT)/status.php" 2>/dev/null)"; then
            [[ -n "${body}" ]] && break
        fi
        body=""
        attempt=$((attempt + 1))
        sleep 2
    done
    [[ -n "${body}" ]] \
        || fail "status.php is not reachable. State was not recorded."
    [[ "${body}" == *'"installed":true'* ]] \
        || fail "status.php did not report installed:true. HTTP success is not an installation."
    [[ "${body}" == *'"maintenance":false'* ]] \
        || fail "status.php reports maintenance mode. State was not recorded."

    ok "status.php reports installed:true."
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
    deploy_prepare_unfinished_install

    log_info "Starting Redis and Nextcloud before cron and Nginx."

    compose_up "${REDIS_SERVICE}" "${NEXTCLOUD_SERVICE}"
    deploy_install_nextcloud_if_needed

    log_info "Starting Nginx and cron."

    compose_up
    deploy_require_running_install

    log_success "Nextcloud-Gr is installed and running."
}
