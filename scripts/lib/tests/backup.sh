#!/usr/bin/env bash

###############################################################################
#
# Nextcloud-Gr
#
# File:
#   scripts/lib/tests/backup.sh
#
# Description:
#   Backup and restore checks that use a temporary directory.
#
#   They do not call pg_dump, pg_restore, or the production data paths.
#
###############################################################################

test_backup_archive()
{
    print_section "Backup archive"

    local work
    local stage
    local archive
    local extracted

    work="$(mktemp -d)"
    stage="${work}/stage"
    archive="${work}/sample.tar.gz"
    extracted="${work}/extracted"

    mkdir -p "${stage}/postgresql" "${stage}/nextcloud/config"

    printf 'PGDMP\n' > "${stage}/postgresql/nextcloud.dump"
    printf 'media\n' > "${stage}/nextcloud/config/icon.txt"
    printf 'secret\n' > "${stage}/stack.env"

    backup_write_manifest \
        "${stage}" \
        "2026-10-13T00:00:00Z" \
        "docker.io/library/nextcloud" \
        "35.0.2-fpm" \
        "docker.io/library/postgres:18.6"

    backup_verify_tree "${stage}"

    backup_pack_stage "${stage}" "${archive}"

    backup_verify_archive "${archive}" "${extracted}"

    mkdir -p "${work}/moved"
    cp "${archive}" "${archive}.sha256" "${work}/moved/"
    backup_verify_archive \
        "${work}/moved/$(basename "${archive}")" \
        "${work}/moved-extracted"

    printf 'x\n' >> "${extracted}/stack.env"

    local rejected

    rejected="$(backup_verify_tree "${extracted}" 2>&1)" || true

    [[ "${rejected}" == *"Checksum mismatch"* ]] \
        || fail "A modified backup tree was not rejected: ${rejected}"

    rm -rf "${work}"

    ok "Backup manifest detects a modified file."
}

test_restore_confirmation()
{
    print_section "Restore confirmation"

    restore_confirmation_matches "${STACK_NAME}" \
        || fail "The stack name was rejected as a restore confirmation."

    if restore_confirmation_matches "monitoring-netcup"; then
        fail "A foreign confirmation was accepted."
    fi

    restore_versions_match "35.0.2-fpm" "35.0.2-fpm" "no" \
        || fail "Matching Nextcloud tags were rejected."

    if restore_versions_match "35.0.2-fpm" "33.0.10-fpm" "no"; then
        fail "A version mismatch was accepted."
    fi

    restore_versions_match "35.0.2-fpm" "33.0.10-fpm" "yes" \
        || fail "An explicit version mismatch was rejected."

    ok "Restore confirmation and version check OK."
}

###############################################################################
# Sixty-character value that is not a placeholder
#
# Arguments:
#   $1 - Character to repeat
#
###############################################################################

test_secret_value()
{
    local char="$1"

    printf '%60s' '' | tr ' ' "${char}"
}

###############################################################################
# Stage directory restore is willing to accept
#
# Arguments:
#   $1 - Stage directory
#   $2 - NEXTCLOUD_ADMIN_PASSWORD
#   $3 - Marker stored in nextcloud/config/icon.txt
#
###############################################################################

test_fill_backup_stage()
{
    local stage="$1"
    local key="$2"
    local marker="$3"

    mkdir -p \
        "${stage}/postgresql" \
        "${stage}/nextcloud/config" \
        "${stage}/nextcloud/custom_apps" \
        "${stage}/nextcloud/themes"

    printf 'PGDMP\n' > "${stage}/postgresql/nextcloud.dump"
    printf '%s\n' "${marker}" > "${stage}/nextcloud/config/icon.txt"
    printf 'template\n' > "${stage}/nextcloud/custom_apps/custom.html"
    printf 'cert\n' > "${stage}/nextcloud/themes/cert.pem"

    printf 'NEXTCLOUD_ADMIN_PASSWORD=%s\nSMTP_HOST=smtp.archived\nBACKUP_EXTERNAL_DIR=/mnt/archived\n' \
        "${key}" > "${stage}/stack.env"

    chmod 600 "${stage}/stack.env"

    backup_write_manifest \
        "${stage}" \
        "2026-10-13T00:00:00Z" \
        "docker.io/library/nextcloud" \
        "35.0.2-fpm" \
        "docker.io/library/postgres:18.6" \
        "18" \
        "0123456789abcdef"
}

###############################################################################
# Refuse archives that must not reach live data
###############################################################################

test_restore_rejects_incomplete()
{
    print_section "Restore preflight"

    local work
    local stage
    local live
    local env_file
    local rejected
    local key

    work="$(mktemp -d)"
    key="$(test_secret_value a)"
    stage="${work}/stage"
    live="${work}/live"
    env_file="${work}/runtime.env"

    mkdir -p "${live}/config" "${live}/custom_apps" "${live}/themes"
    printf 'sentinel\n' > "${live}/config/sentinel.txt"
    printf 'NEXTCLOUD_ADMIN_PASSWORD=%s\nSMTP_HOST=smtp.current\n' \
        "${key}" > "${env_file}"

    test_fill_backup_stage "${stage}" "${key}" "archive"
    rm -f "${stage}/postgresql/nextcloud.dump"

    rejected="$(restore_validate_stage "${stage}" 2>&1)" || true

    [[ "${rejected}" == *"PostgreSQL dump is missing or empty."* ]] \
        || fail "A backup without a database dump was accepted: ${rejected}"

    test_fill_backup_stage "${stage}" "${key}" "archive"
    rm -rf "${stage}/nextcloud/custom_apps"

    rejected="$(restore_validate_stage "${stage}" 2>&1)" || true

    [[ "${rejected}" == *"Archive is missing nextcloud/custom_apps."* ]] \
        || fail "A backup without persistent directories was accepted: ${rejected}"

    test_fill_backup_stage "${stage}" "${key}" "archive"
    printf 'SMTP_HOST=smtp.archived\n' > "${stage}/stack.env"

    rejected="$(restore_validate_stage "${stage}" 2>&1)" || true

    [[ "${rejected}" == *"no NEXTCLOUD_ADMIN_PASSWORD"* ]] \
        || fail "A backup without NEXTCLOUD_ADMIN_PASSWORD was accepted: ${rejected}"

    printf 'NEXTCLOUD_ADMIN_PASSWORD=set_admin_password\n' > "${stage}/stack.env"

    rejected="$(restore_validate_stage "${stage}" 2>&1)" || true

    [[ "${rejected}" == *"placeholder, or shorter than 16 characters."* ]] \
        || fail "A placeholder NEXTCLOUD_ADMIN_PASSWORD was accepted: ${rejected}"

    printf 'NEXTCLOUD_ADMIN_PASSWORD=short-key\n' > "${stage}/stack.env"

    rejected="$(restore_validate_stage "${stage}" 2>&1)" || true

    [[ "${rejected}" == *"placeholder, or shorter than 16 characters."* ]] \
        || fail "A short NEXTCLOUD_ADMIN_PASSWORD was accepted: ${rejected}"

    test_fill_backup_stage "${stage}" "${key}" "archive"
    printf 'changed\n' >> "${stage}/nextcloud/config/icon.txt"

    rejected="$(restore_validate_stage "${stage}" 2>&1)" || true

    [[ "${rejected}" == *"Checksum mismatch"* ]] \
        || fail "A modified backup file was accepted: ${rejected}"

    test_fill_backup_stage "${stage}" "${key}" "archive"
    printf 'project=monitoring-netcup\n' > "${stage}/manifest.txt"

    rejected="$(restore_validate_stage "${stage}" 2>&1)" || true

    [[ "${rejected}" == *"Manifest project is"* ]] \
        || fail "An invalid manifest was accepted: ${rejected}"

    test_fill_backup_stage "${stage}" "${key}" "archive"
    sed -i 's/^database_engine=.*/database_engine=mariadb/' "${stage}/manifest.txt"

    rejected="$(restore_validate_stage "${stage}" 2>&1)" || true

    [[ "${rejected}" == *"database_engine is not postgresql"* ]] \
        || fail "A non-PostgreSQL manifest was accepted: ${rejected}"

    TEST_SNAPSHOT_FLAG="${work}/snapshot-called"
    rm -f "${TEST_SNAPSHOT_FLAG}"

    restore_snapshot_database()
    {
        printf 'called\n' > "${TEST_SNAPSHOT_FLAG}"
        return 0
    }

    rm -f "${stage}/postgresql/nextcloud.dump"

    rejected="$(restore_perform "${stage}" "${live}" "${env_file}" "${work}/rollback" 2>&1)" || true

    [[ "${rejected}" == *"PostgreSQL dump is missing or empty."* ]] \
        || fail "Preflight did not reject the incomplete archive: ${rejected}"

    [[ ! -e "${TEST_SNAPSHOT_FLAG}" ]] \
        || fail "Validation failure still prepared a database snapshot."

    [[ "$(cat "${live}/config/sentinel.txt")" == "sentinel" ]] \
        || fail "Validation failure changed live files."

    rm -rf "${work}"

    ok "Incomplete archives are refused before live data changes."
}

###############################################################################
# Database failure puts files and the key back
###############################################################################

test_restore_rolls_back()
{
    print_section "Restore rollback"

    local work
    local stage
    local live
    local env_file
    local rollback
    local old_key
    local new_key
    local live_key

    work="$(mktemp -d)"
    old_key="$(test_secret_value a)"
    new_key="$(test_secret_value b)"
    stage="${work}/stage"
    live="${work}/live"
    env_file="${work}/runtime.env"
    rollback="${work}/rollback"

    mkdir -p "${live}/config" "${live}/custom_apps" "${live}/themes" "${rollback}"
    printf 'original\n' > "${live}/config/icon.txt"
    printf 'original-template\n' > "${live}/custom_apps/custom.html"
    printf 'original-cert\n' > "${live}/themes/cert.pem"

    printf 'NEXTCLOUD_ADMIN_PASSWORD=%s\nSMTP_HOST=smtp.current\nBACKUP_EXTERNAL_DIR=/mnt/current\n' \
        "${old_key}" > "${env_file}"

    test_fill_backup_stage "${stage}" "${new_key}" "from-archive"

    TEST_LOAD_MODE="fail-once"

    restore_snapshot_database()
    {
        printf 'snapshot\n' > "$1"
    }

    restore_load_database()
    {
        if [[ "${TEST_LOAD_MODE}" == "fail-once" ]]; then
            TEST_LOAD_MODE="ok"
            return 1
        fi

        if [[ "${TEST_LOAD_MODE}" == "fail" ]]; then
            return 1
        fi

        return 0
    }

    restore_database_is_ready()
    {
        return 0
    }

    if restore_perform "${stage}" "${live}" "${env_file}" "${rollback}"; then
        fail "A failed database restore was reported as success."
    fi

    [[ "${RESTORE_ERROR}" == "rolled-back" ]] \
        || fail "Database failure did not roll back (${RESTORE_ERROR})."

    [[ "${RESTORE_KEEP_ROLLBACK}" == "yes" ]] \
        || fail "Database failure cleared the rollback keep flag."

    [[ "${RESTORE_MUTATION_STARTED}" == "yes" ]] \
        || fail "Database failure lost the mutation marker."

    [[ -d "${rollback}" ]] \
        || fail "Database failure removed the rollback snapshot."

    restore_should_keep_rollback \
        || fail "A rolled-back restore would discard its snapshot."

    [[ "$(cat "${live}/config/icon.txt")" == "original" ]] \
        || fail "Rollback left archive files in place of the original data."

    live_key="$(restore_read_secret_key "${env_file}")"

    [[ "${live_key}" == "${old_key}" ]] \
        || fail "Rollback did not restore the previous secret key."

    grep -qx 'SMTP_HOST=smtp.current' "${env_file}" \
        || fail "Rollback changed a non-key environment line."

    [[ -s "${rollback}/postgresql/nextcloud.dump" ]] \
        || fail "Rollback snapshot dump is missing."

    TEST_LOAD_MODE="fail"

    if restore_perform "${stage}" "${live}" "${env_file}" "${rollback}"; then
        fail "A restore whose rollback also failed was reported as success."
    fi

    [[ "${RESTORE_ERROR}" == "rollback-failed" ]] \
        || fail "A failed rollback was not reported (${RESTORE_ERROR})."

    [[ "$(cat "${live}/config/icon.txt")" == "original" ]] \
        || fail "A failed database rollback left archive files in place."

    live_key="$(restore_read_secret_key "${env_file}")"

    [[ "${live_key}" == "${old_key}" ]] \
        || fail "A failed database rollback left the archive secret key installed."

    unset live_key old_key new_key

    rm -rf "${work}"

    ok "Database restore failure does not report success."
}

###############################################################################
# Secret key is replaced without rewriting the rest of .env
###############################################################################

test_restore_installs_secret_key()
{
    print_section "Restore secret key"

    local work
    local stage
    local live
    local env_file
    local rollback
    local old_key
    local new_key
    local live_key
    local mode
    local backup_file

    work="$(mktemp -d)"
    old_key="$(test_secret_value a)"
    new_key="$(test_secret_value b)"
    stage="${work}/stage"
    live="${work}/live"
    env_file="${work}/runtime.env"
    rollback="${work}/rollback"

    mkdir -p "${live}/config" "${live}/custom_apps" "${live}/themes" "${rollback}"
    printf 'original\n' > "${live}/config/icon.txt"
    printf 'original-template\n' > "${live}/custom_apps/custom.html"
    printf 'original-cert\n' > "${live}/themes/cert.pem"

    printf 'NEXTCLOUD_ADMIN_PASSWORD=%s\nSMTP_HOST=smtp.current\nBACKUP_EXTERNAL_DIR=/mnt/current\n' \
        "${old_key}" > "${env_file}"

    chmod 640 "${env_file}"

    test_fill_backup_stage "${stage}" "${new_key}" "from-archive"

    restore_snapshot_database()
    {
        printf 'snapshot\n' > "$1"
    }

    restore_load_database()
    {
        return 0
    }

    restore_database_is_ready()
    {
        return 0
    }

    if ! restore_perform "${stage}" "${live}" "${env_file}" "${rollback}"; then
        fail "Secret key restore failed (${RESTORE_ERROR})."
    fi

    [[ -z "${RESTORE_ERROR}" ]] \
        || fail "Successful restore left an error state (${RESTORE_ERROR})."

    live_key="$(restore_read_secret_key "${env_file}")"

    [[ "${live_key}" == "${new_key}" ]] \
        || fail "Runtime secret key does not match the archive."

    grep -qx 'SMTP_HOST=smtp.current' "${env_file}" \
        || fail "Secret key restore rewrote SMTP_HOST."

    grep -qx 'BACKUP_EXTERNAL_DIR=/mnt/current' "${env_file}" \
        || fail "Secret key restore rewrote BACKUP_EXTERNAL_DIR."

    [[ "$(grep -c '^NEXTCLOUD_ADMIN_PASSWORD=' "${env_file}")" -eq 1 ]] \
        || fail "Secret key restore left more than one key line."

    [[ "$(cat "${live}/config/icon.txt")" == "from-archive" ]] \
        || fail "Restored data file does not match the archive."

    mode="$(stat -c '%a' "${env_file}")"

    [[ "${mode}" == "640" ]] \
        || fail "Secret key restore changed .env mode from 640 to ${mode}."

    backup_file="$(find "${work}" -maxdepth 1 -name 'runtime.env.bak-*' -type f -print -quit)"

    [[ -n "${backup_file}" && -f "${backup_file}" ]] \
        || fail "Secret key restore did not keep a backup of .env."

    [[ "$(stat -c '%a' "${backup_file}")" == "600" ]] \
        || fail "The .env backup is not mode 600."

    unset live_key old_key new_key

    rm -rf "${work}"

    ok "Secret key restored without rewriting other .env lines."
}

###############################################################################
# External copy is checked where it was copied
###############################################################################

test_backup_external_copy()
{
    print_section "External backup copy"

    local work
    local stage
    local archive
    local dest
    local rejected
    local key

    work="$(mktemp -d)"
    key="$(test_secret_value c)"
    stage="${work}/stage"
    archive="${work}/sample.tar.gz"
    dest="${work}/external"

    test_fill_backup_stage "${stage}" "${key}" "media"
    backup_pack_stage "${stage}" "${archive}"

    mkdir -p "${dest}"

    backup_copy_and_verify "${archive}" "${dest}"

    printf 'x\n' >> "${dest}/$(basename "${archive}")"

    rejected="$(backup_require_sidecar "${dest}/$(basename "${archive}")" copy 2>&1)" || true

    [[ "${rejected}" == *"not a verified backup"* ]] \
        || fail "A damaged external copy was accepted: ${rejected}"

    backup_verify_sidecar "${archive}" \
        || fail "The local archive failed after the external copy was damaged."

    unset key

    rm -rf "${work}"

    ok "External copy is verified at the destination."
}

###############################################################################
# Backup stops only the Nextcloud containers that are running
###############################################################################

test_backup_quiesce()
{
    print_section "Backup quiesce"

    local work
    local events

    work="$(mktemp -d)"
    events="${work}/events"
    : > "${events}"

    (
        docker_container_running()
        {
            [[ "$1" == "${NEXTCLOUD_CRON_CONTAINER}" ]]
        }

        backup_stop_container()
        {
            printf 'stop %s\n' "$1" >> "${events}"
        }

        backup_start_container()
        {
            printf 'start %s\n' "$1" >> "${events}"
        }

        backup_enter_maintenance()
        {
            printf 'maintenance on\n' >> "${events}"
        }

        backup_leave_maintenance()
        {
            printf 'maintenance off\n' >> "${events}"
        }

        backup_quiesce_writers
        backup_resume_writers
    ) || fail "Backup quiesce returned an error."

    grep -qx "maintenance on" "${events}" \
        || fail "Backup did not enable maintenance mode."

    grep -qx "stop ${NEXTCLOUD_CRON_CONTAINER}" "${events}" \
        || fail "A running cron container was not stopped for the backup."

    grep -qx "start ${NEXTCLOUD_CRON_CONTAINER}" "${events}" \
        || fail "Cron stopped for the backup was not started again."

    grep -qx "maintenance off" "${events}" \
        || fail "Backup did not leave maintenance mode."

    if grep -q "${NEXTCLOUD_APP_CONTAINER}\|${NGINX_CONTAINER}" "${events}"; then
        fail "Backup changed Nextcloud or Nginx."
    fi

    rm -rf "${work}"

    ok "Backup stops and starts only the containers it found running."
}

###############################################################################
# age encryption of a real temporary archive
#
# age-keygen, age -r and age -d run for real. Docker and PostgreSQL
# do not. The private identity is not printed.
#
###############################################################################

test_backup_encryption()
{
    print_section "Backup encryption"

    local work
    local empty_bin
    local rejected
    local identity
    local recipient
    local plain
    local encrypted
    local restored
    local mode

    work="$(mktemp -d)"
    empty_bin="${work}/empty-bin"
    mkdir -m 700 "${empty_bin}"

    rejected="$(backup_require_encryption "" 2>&1)" || true

    [[ "${rejected}" == *"BACKUP_AGE_RECIPIENT is empty"* ]] \
        || fail "An empty age recipient was accepted: ${rejected}"

    [[ "${rejected}" == *"not a safe external backup"* ]] \
        || fail "An empty age recipient was described as a safe external backup: ${rejected}"

    rejected="$(backup_require_encryption "AGE-SECRET-KEY-1not-a-real-identity" 2>&1)" || true

    [[ "${rejected}" == *"not a public age recipient"* ]] \
        || fail "A private age identity was accepted as a recipient: ${rejected}"

    [[ "${rejected}" != *"AGE-SECRET-KEY"* ]] \
        || fail "A rejected identity was written to the error text."

    (
        PATH="${empty_bin}"
        hash -r
        backup_require_encryption "age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq"
    ) >"${work}/missing-age.out" 2>"${work}/missing-age.err" || true

    rejected="$(cat "${work}/missing-age.err")"

    [[ "${rejected}" == *"age is not installed"* ]] \
        || fail "A missing age command was accepted: ${rejected}"

    [[ "${rejected}" == *"not a safe external backup"* ]] \
        || fail "A missing age command was described as a safe external backup: ${rejected}"

    identity="${work}/identity"
    age-keygen -o "${identity}" >"${work}/age-keygen.out" 2>"${work}/age-keygen.err"
    chmod 600 "${identity}"

    recipient="$(
        awk -F': ' '/public key:/{ print $2; exit }' "${identity}"
    )"

    backup_recipient_is_public "${recipient}" \
        || fail "age-keygen did not produce a public recipient."

    plain="${work}/plain.tar.gz"
    encrypted="${work}/sample.tar.gz.age"

    (
        umask 022
        backup_create_private_file "${work}/umask-file"
        backup_create_private_dir "${work}/umask-dir"
    )

    [[ "$(stat -c '%a' "${work}/umask-file")" == "600" ]] \
        || fail "A private file was created with mode $(stat -c '%a' "${work}/umask-file") under umask 022."

    [[ "$(stat -c '%a' "${work}/umask-dir")" == "700" ]] \
        || fail "A private directory was created with mode $(stat -c '%a' "${work}/umask-dir") under umask 022."

    printf 'plaintext-marker\n' > "${work}/payload"
    tar -C "${work}" -czf "${plain}" payload

    (
        umask 022
        backup_encrypt_file "${plain}" "${encrypted}" "${recipient}"
    ) \
        || fail "age did not encrypt the archive."

    mode="$(stat -c '%a' "${encrypted}")"

    [[ "${mode}" == "600" ]] \
        || fail "Encrypted archive mode is ${mode}, expected 600."

    backup_write_checksum "${encrypted}"
    backup_require_sidecar "${encrypted}" "archive"

    printf 'x' >> "${encrypted}"

    rejected="$(backup_require_sidecar "${encrypted}" archive 2>&1)" || true

    [[ "${rejected}" == *"does not match"* ]] \
        || fail "A damaged encrypted archive was accepted: ${rejected}"

    backup_write_checksum "${encrypted}"

    restored="${work}/restored"
    backup_create_private_file "${restored}"

    if backup_decrypt_file "${encrypted}" "${restored}" "${identity}"; then
        fail "A damaged encrypted archive was decrypted."
    fi

    [[ ! -e "${restored}" ]] \
        || fail "A failed decrypt left a plaintext file."

    rm -f "${encrypted}" "${encrypted}.sha256"
    backup_encrypt_file "${plain}" "${encrypted}" "${recipient}" \
        || fail "age did not encrypt the archive on the second attempt."

    backup_write_checksum "${encrypted}"
    backup_decrypt_file "${encrypted}" "${restored}" "${identity}" \
        || fail "age did not decrypt the archive with the identity file."

    mkdir -m 700 "${work}/out"
    tar -C "${work}/out" -xzf "${restored}"

    [[ "$(cat "${work}/out/payload")" == "plaintext-marker" ]] \
        || fail "Decrypted archive does not contain the plaintext payload."

    #
    # The name is gone. This does not show that SSD or copy-on-write
    # blocks were erased.
    #

    backup_destroy_file "${plain}" \
        || fail "Plaintext archive could not be removed."

    [[ ! -e "${plain}" ]] \
        || fail "Plaintext archive name remained after removal."

    rm -rf "${work}"

    ok "age encryption, checksum and decrypt were checked with a real age binary."
}

###############################################################################
# Modes of the plaintext that exists before encryption
#
# install, tar and stat run for real under umask 022. pg_dump does not
# run: the dump path is a redirect into a file that was created mode
# 600, which is the same open the shell uses for the docker redirect.
# A tar created without that pre-created file is checked only to show
# the mode tar would otherwise choose. shred is not asked to erase media.
#
###############################################################################

test_backup_plaintext_modes()
{
    print_section "Backup plaintext modes"

    local work
    local status=0

    work="$(mktemp -d)"

    (
        umask 022

        local stage
        local live
        local plain_dir
        local plain
        local verify
        local loose
        local mode

        stage="$(mktemp -d "${work}/stage.XXXXXX")"
        mkdir -m 755 "${work}/live"
        mkdir -m 755 "${work}/live/nested"
        printf 'media\n' > "${work}/live/nested/icon.txt"

        mode="$(stat -c '%a' "${work}/live/nested/icon.txt")"
        [[ "${mode}" == "644" ]] \
            || fail "The mode fixture was not 644: ${mode}"

        backup_create_private_dir "${stage}/postgresql"
        backup_create_private_file "${stage}/postgresql/nextcloud.dump"
        printf 'PGDMP\n' > "${stage}/postgresql/nextcloud.dump"

        backup_copy_private_tree "${work}/live" "${stage}/nextcloud/config"
        printf 'NEXTCLOUD_ADMIN_PASSWORD=mode-check\n' > "${work}/runtime.env"
        install -m 600 "${work}/runtime.env" "${stage}/stack.env"

        backup_write_manifest \
            "${stage}" \
            "2026-01-01T00:00:00Z" \
            "image" \
            "tag" \
            "postgres"

        backup_require_private_tree "${stage}" \
            || fail "The stage tree was not mode 700/600 under umask 022."

        for relative in \
            postgresql/nextcloud.dump \
            nextcloud/config/nested/icon.txt \
            stack.env \
            manifest.txt
        do
            mode="$(stat -c '%a' "${stage}/${relative}")"
            [[ "${mode}" == "600" ]] \
                || fail "${relative} was created mode ${mode}, expected 600."
        done

        mode="$(stat -c '%a' "${stage}/nextcloud")"
        [[ "${mode}" == "700" ]] \
            || fail "An intermediate stage directory was mode ${mode}, expected 700."

        loose="${work}/loose.tar.gz"
        tar -C "${stage}" -czf "${loose}" .
        mode="$(stat -c '%a' "${loose}")"
        [[ "${mode}" == "644" ]] \
            || fail "A tar created without a mode 600 file was ${mode}, expected 644 under umask 022."

        plain_dir="$(mktemp -d "${work}/plain.XXXXXX")"
        plain="${plain_dir}/plain.tar.gz"
        backup_create_private_file "${plain}"
        tar -C "${stage}" -czf "${plain}" .

        backup_require_private_tree "${plain_dir}" \
            || fail "The plaintext archive directory was not mode 700/600."

        mode="$(stat -c '%a' "${plain}")"
        [[ "${mode}" == "600" ]] \
            || fail "The pre-created plaintext archive was mode ${mode}, expected 600."

        verify="$(mktemp -d "${work}/verify.XXXXXX")"
        tar -C "${verify}" -xzf "${plain}"

        backup_require_private_tree "${verify}" \
            || fail "The unpacked plaintext was not mode 700/600."

        mode="$(stat -c '%a' "${verify}/stack.env")"
        [[ "${mode}" == "600" ]] \
            || fail "Unpacked stack.env was mode ${mode}, expected 600."

        mode="$(stat -c '%a' "${verify}/postgresql/nextcloud.dump")"
        [[ "${mode}" == "600" ]] \
            || fail "Unpacked dump was mode ${mode}, expected 600."

    ) || status=$?

    rm -rf "${work}"

    [[ "${status}" -eq 0 ]] \
        || fail "Plaintext mode check failed with status ${status}."

    ok "Dump, stack.env, manifest and the plaintext tar are mode 600 at creation."
}

###############################################################################
# Stream the stage into age without a plaintext tar file
#
# tar, age and sha256sum run for real. backup.sh is not executed and
# pg_dump does not run. The throwaway identity is used only after
# backup_store_encrypted_stage returns, to read the ciphertext back.
# The store function itself receives no identity.
#
# The tar failure is a fake tar in one subshell. It exits 1 and writes
# no stdout, so age can still encrypt that empty stream. pipefail has
# to return the tar status. The success path and the age failure path
# keep the real tar. The age failure is a real age checksum rejection
# of a recipient string that backup_recipient_is_public still accepts.
#
###############################################################################

test_backup_stream_encrypt()
{
    print_section "Backup stream encryption"

    local work
    local identity
    local recipient
    local bad_recipient
    local stage
    local tar_stage
    local pending
    local final
    local status
    local leftover
    local restored
    local mode
    local fake_bin

    if grep -q 'plain\.tar\.gz' "${SCRIPT_DIR}/backup.sh"; then
        fail "backup.sh still names a plaintext tar archive."
    fi

    grep -q -- '-czf -' "${SCRIPT_DIR}/lib/backup/crypto.sh" \
        || fail "Stage encryption does not stream tar to stdout."

    work="$(mktemp -d)"
    mkdir -m 700 "${work}/publish"

    identity="${work}/identity"
    age-keygen -o "${identity}" >"${work}/age-keygen.out" 2>"${work}/age-keygen.err"
    chmod 600 "${identity}"

    recipient="$(
        awk -F': ' '/public key:/{ print $2; exit }' "${identity}"
    )"

    backup_recipient_is_public "${recipient}" \
        || fail "age-keygen did not produce a public recipient."

    stage="$(mktemp -d "${work}/stage.XXXXXX")"
    backup_create_private_file "${stage}/payload"
    printf 'stream-marker\n' > "${stage}/payload"
    pending="$(mktemp -d "${work}/pending.XXXXXX")"
    final="${work}/publish/sample.tar.gz.age"

    status=0
    backup_store_encrypted_stage \
        "${stage}" \
        "${final}" \
        "${recipient}" \
        "${pending}" \
        || status=$?

    [[ "${status}" -eq 0 ]] \
        || fail "Streaming encryption failed with status ${status}."

    [[ -f "${final}" ]] \
        || fail "The checksummed archive was not published."

    mode="$(stat -c '%a' "${final}")"
    [[ "${mode}" == "600" ]] \
        || fail "Published archive mode is ${mode}, expected 600."

    backup_verify_sidecar "${final}" \
        || fail "Published archive checksum does not match."

    [[ ! -d "${pending}" ]] \
        || fail "Temporary ciphertext directory remained after publish."

    leftover="$(
        find "${work}" \( -name 'plain.tar.gz' -o -name '*.tar.gz' \) -print
    )"
    [[ -z "${leftover}" ]] \
        || fail "A plaintext tar was created: ${leftover}"

    restored="${work}/decrypted.bin"
    backup_decrypt_file "${final}" "${restored}" "${identity}" \
        || fail "The streamed archive could not be decrypted."

    mkdir -m 700 "${work}/out"
    tar -C "${work}/out" -xzf "${restored}"
    [[ "$(cat "${work}/out/payload")" == "stream-marker" ]] \
        || fail "Decrypted stream does not contain the stage payload."

    if ! printf '' | age -r "${recipient}" -o "${work}/empty-input.age" >/dev/null; then
        fail "age rejected empty input, so a tar failure would not prove pipefail."
    fi

    [[ -s "${work}/empty-input.age" ]] \
        || fail "age did not encrypt empty input."

    rm -f "${work}/empty-input.age"

    fake_bin="${work}/fake-tar-bin"
    mkdir -m 700 "${fake_bin}"
    cat > "${fake_bin}/tar" << 'EOF'
#!/bin/sh
printf '%s\n' 'tar: forced failure' >&2
exit 1
EOF
    chmod 755 "${fake_bin}/tar"

    tar_stage="$(mktemp -d "${work}/tarfail.XXXXXX")"
    stage="${tar_stage}"
    backup_create_private_file "${stage}/secret"
    printf 'readable\n' > "${stage}/secret"
    pending="$(mktemp -d "${work}/pending-tar.XXXXXX")"
    final="${work}/publish/tar-fail.tar.gz.age"
    status=0

    #
    # hash -r stays in the subshell. The parent keeps the real tar
    # for the age failure below.
    #

    (
        hash -r
        PATH="${fake_bin}:${PATH}" backup_store_encrypted_stage \
            "${stage}" \
            "${final}" \
            "${recipient}" \
            "${pending}"
    ) >"${work}/tar.out" 2>"${work}/tar.err" || status=$?

    [[ "${status}" -eq 1 ]] \
        || fail "A tar failure was stored with status ${status}."

    [[ ! -e "${final}" && ! -e "${final}.sha256" ]] \
        || fail "A tar failure left a published archive."

    [[ ! -e "${pending}/stream.tar.gz.age" ]] \
        || fail "A tar failure left temporary ciphertext."

    [[ "$(cat "${work}/tar.err")" == *'tar: forced failure'* ]] \
        || fail "The isolated fake tar did not fail the pipeline."

    bad_recipient="age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq"
    backup_recipient_is_public "${bad_recipient}" \
        || fail "The age failure fixture was rejected before age ran."

    stage="$(mktemp -d "${work}/agefail.XXXXXX")"
    backup_create_private_file "${stage}/payload"
    printf 'x\n' > "${stage}/payload"
    pending="$(mktemp -d "${work}/pending-age.XXXXXX")"
    final="${work}/publish/age-fail.tar.gz.age"
    status=0

    backup_store_encrypted_stage \
        "${stage}" \
        "${final}" \
        "${bad_recipient}" \
        "${pending}" \
        >"${work}/age.out" 2>"${work}/age.err" \
        || status=$?

    [[ "${status}" -eq 1 ]] \
        || fail "An age failure was stored with status ${status}."

    [[ ! -e "${final}" && ! -e "${final}.sha256" ]] \
        || fail "An age failure left a published archive."

    [[ ! -e "${pending}/stream.tar.gz.age" ]] \
        || fail "An age failure left temporary ciphertext."

    [[ "$(cat "${work}/age.err")" == *'age:'* ]] \
        || fail "age did not report the recipient failure."

    [[ "$(cat "${work}/age.err")" != *'AGE-SECRET-KEY'* ]] \
        || fail "An age error included identity material."

    [[ "$(cat "${work}/age.out")" != *"mounted host directory"* ]] \
        || fail "An age failure was announced as a host-directory copy."

    leftover="$(
        find "${work}" \( -name 'plain.tar.gz' -o -name '*.tar.gz' \) -print
    )"
    [[ -z "${leftover}" ]] \
        || fail "A plaintext tar was created: ${leftover}"

    rm -rf "${work}"

    ok "Streamed age encryption publishes only after the pipeline and checksum succeed."
}

###############################################################################
# Ordinary directory on this filesystem
#
# No bind mount is created here. A mode 700 directory that shares the
# device with the local backup directory is still not a mountpoint.
#
###############################################################################

test_backup_destination()
{
    print_section "Backup destination"

    local work
    local local_dir
    local same
    local loose
    local kind
    local rejected

    work="$(mktemp -d)"
    local_dir="${work}/local"
    same="${work}/backups"
    loose="${work}/loose"

    mkdir -m 700 "${local_dir}" "${same}"
    mkdir -m 755 "${loose}"

    kind="$(backup_classify_destination "${same}" "${local_dir}")"

    [[ "${kind}" == "not-mounted" ]] \
        || fail "A plain directory was classed as ${kind}."

    rejected="$(backup_publish_encrypted "${work}/missing" "${same}" "${local_dir}" 2>&1)" || true

    [[ "${rejected}" == *"not a mounted mountpoint"* ]] \
        || fail "A plain directory was copied: ${rejected}"

    [[ "${rejected}" == *"Refusing to write"* ]] \
        || fail "A plain directory was not refused: ${rejected}"

    [[ "${rejected}" != *"mounted host directory"* ]] \
        || fail "A plain directory was called a host-directory copy: ${rejected}"

    [[ ! -e "${same}/missing" ]] \
        || fail "A refused destination received a file."

    rejected="$(backup_classify_destination "${loose}" "${local_dir}" 2>&1)" || true

    [[ "${rejected}" == *"mode 700"* ]] \
        || fail "A mode 755 destination was accepted: ${rejected}"

    if backup_path_is_forbidden "${STACK_DIR}/age.key"; then
        true
    else
        fail "An identity under the stack directory was allowed."
    fi

    if backup_path_is_forbidden "${work}/identity"; then
        fail "An identity in a temporary directory was forbidden."
    fi

    printf 'not-a-key\n' > "${work}/identity"
    chmod 644 "${work}/identity"

    rejected="$(backup_require_identity "${work}/identity" 2>&1)" || true

    [[ "${rejected}" == *"mode 600 or 400"* ]] \
        || fail "A mode 644 identity was accepted: ${rejected}"

    chmod 600 "${work}/identity"

    backup_require_identity "${work}/identity"

    rm -rf "${work}"

    ok "A plain directory and a loose destination are refused."
}

###############################################################################
# Bind mount is a host mountpoint even on the same device
#
# unshare creates a private mount namespace and a real bind mount in
# the temporary directory. /backups on the workstation and the VPS
# are not touched. backup.sh is not executed.
#
###############################################################################

backup_host_mount_checks()
{
    local work="$1"
    local mounted
    local plain
    local local_dir
    local archive
    local broken
    local kind
    local rejected
    local base
    local copied

    mounted="${work}/backups"
    plain="${work}/plain"
    local_dir="${work}/local"
    archive="${local_dir}/sample.tar.gz.age"
    broken="${local_dir}/broken.tar.gz.age"

    mkdir -m 700 "${work}/src" "${mounted}" "${plain}" "${local_dir}"
    printf 'payload\n' > "${work}/src/file"
    mount --bind "${work}/src" "${mounted}"

    [[ "$(stat -c '%d' "${mounted}")" == "$(stat -c '%d' "${plain}")" ]] \
        || fail "The bind mount fixture is not on the same device as the plain directory."

    kind="$(backup_classify_destination "${mounted}" "${local_dir}")"

    [[ "${kind}" == "host-mount" ]] \
        || fail "A bind mount on the same device was classed as ${kind}."

    printf 'ciphertext\n' > "${archive}"
    backup_write_checksum "${archive}"

    backup_publish_encrypted "${archive}" "${mounted}" "${local_dir}"

    base="$(basename "${archive}")"
    copied="${mounted}/${base}"

    [[ "$(stat -c '%a' "${copied}")" == "600" ]] \
        || fail "The copied archive is not mode 600."

    [[ "$(stat -c '%a' "${copied}.sha256")" == "600" ]] \
        || fail "The copied checksum is not mode 600."

    [[ "$(stat -c '%a' "${mounted}")" == "700" ]] \
        || fail "The mounted directory is not mode 700."

    backup_verify_sidecar "${copied}" \
        || fail "The checksum was not verified on the mounted directory."

    rejected="$(backup_publish_encrypted "${archive}" "${plain}" "${local_dir}" 2>&1)" || true

    [[ "${rejected}" == *"not a mounted mountpoint"* ]] \
        || fail "A plain directory beside the bind mount was accepted: ${rejected}"

    [[ "${rejected}" == *"Refusing to write"* ]] \
        || fail "A plain directory beside the bind mount was not refused: ${rejected}"

    [[ ! -e "${plain}/${base}" && ! -e "${plain}/${base}.sha256" ]] \
        || fail "A plain directory received the archive."

    rejected="$(backup_classify_destination "${work}/absent" "${local_dir}" 2>&1)" || true

    [[ "${rejected}" == *"not a directory"* ]] \
        || fail "A missing mountpoint was accepted: ${rejected}"

    [[ ! -e "${work}/absent" ]] \
        || fail "A missing mountpoint was created."

    printf 'ciphertext\n' > "${broken}"
    backup_write_checksum "${broken}"
    printf '0000000000000000000000000000000000000000000000000000000000000000  broken.tar.gz.age\n' \
        > "${broken}.sha256"

    rejected="$(backup_publish_encrypted "${broken}" "${mounted}" "${local_dir}" 2>&1)" || true

    [[ "${rejected}" == *"not a verified backup"* ]] \
        || fail "A bad checksum was accepted: ${rejected}"

    [[ "${rejected}" != *"mounted host directory"* ]] \
        || fail "A bad checksum was announced as a host-directory copy: ${rejected}"
}

test_backup_host_mount()
{
    print_section "Host backup mount"

    local work
    local status
    local output

    work="$(mktemp -d)"
    status=0

    output="$(
        unshare --mount --propagation private --user --map-root-user \
            bash -c '
                set -Eeuo pipefail
                SCRIPT_DIR="$1"
                work="$2"
                source "${SCRIPT_DIR}/config.sh"
                source "${SCRIPT_DIR}/lib/common.sh"
                source "${SCRIPT_DIR}/lib/logging.sh"
                source "${SCRIPT_DIR}/lib/filesystem.sh"
                source "${SCRIPT_DIR}/lib/env/load.sh"
                source "${SCRIPT_DIR}/lib/backup/private.sh"
                source "${SCRIPT_DIR}/lib/backup/archive.sh"
                source "${SCRIPT_DIR}/lib/backup/crypto.sh"
                source "${SCRIPT_DIR}/lib/tests/backup.sh"
                backup_host_mount_checks "${work}"
            ' \
            bash "${SCRIPT_DIR}" "${work}" 2>&1
    )" || status=$?

    [[ "${status}" -eq 0 ]] \
        || fail "Host mount checks failed with status ${status}: ${output}"

    rm -rf "${work}"

    ok "A bind mount is a host directory and a plain directory on the same device is refused."
}

###############################################################################
# Cleanup failure must not look like success
#
# backup_destroy_tree is replaced in a subshell. shred is not asked
# to fail on a real file; the replacement returns 1 immediately.
#
###############################################################################

test_backup_cleanup_failure()
{
    print_section "Backup cleanup failure"

    local work
    local rejected
    local status

    work="$(mktemp -d)"
    mkdir -m 700 "${work}/plain"
    printf 'secret\n' > "${work}/plain/payload"

    status=0

    rejected="$(
        backup_destroy_tree()
        {
            return 1
        }

        backup_discard_plaintext "${work}/plain"
    )" || status=$?

    [[ "${status}" -ne 0 ]] \
        || fail "A failed plaintext cleanup was treated as success."

    [[ "${rejected}" == *"not a completed backup"* ]] \
        || fail "Cleanup failure was reported as a completed backup: ${rejected}"

    [[ -f "${work}/plain/payload" ]] \
        || fail "The simulated cleanup failure removed the plaintext file."

    rm -rf "${work}"

    ok "A failed plaintext cleanup is not a completed backup."
}

###############################################################################
# SIGTERM during the destructive phase keeps the snapshot
#
# A subshell installs the same EXIT handler as restore.sh and then
# receives a real SIGTERM. pg_restore is a stub that returns 0. No
# database is contacted.
#
###############################################################################

test_restore_signal()
{
    print_section "Restore signal"

    local work
    local live
    local rollback
    local env_file
    local status

    work="$(mktemp -d)"
    live="${work}/live"
    rollback="${work}/rollback"
    env_file="${work}/runtime.env"

    mkdir -m 700 -p "${live}/config" "${live}/custom_apps" "${live}/themes"
    mkdir -m 700 -p "${rollback}/nextcloud/config" "${rollback}/nextcloud/custom_apps" "${rollback}/nextcloud/themes" "${rollback}/postgresql"

    printf 'original\n' > "${live}/config/icon.txt"
    printf 'original\n' > "${rollback}/nextcloud/config/icon.txt"
    printf 'template\n' > "${live}/custom_apps/custom.html"
    printf 'template\n' > "${rollback}/nextcloud/custom_apps/custom.html"
    printf 'cert\n' > "${live}/themes/cert.pem"
    printf 'cert\n' > "${rollback}/nextcloud/themes/cert.pem"
    printf 'NEXTCLOUD_ADMIN_PASSWORD=%s\n' "$(test_secret_value a)" > "${env_file}"
    install -m 600 "${env_file}" "${rollback}/runtime.env"
    printf '600\n' > "${rollback}/env.mode"
    printf 'snapshot\n' > "${rollback}/postgresql/nextcloud.dump"

    status=0

    (
        stage=""
        secret_tmp=""
        RESTORE_VERIFIED=no
        RESTORE_ROLLBACK_DONE=no
        RESTORE_ROLLBACK_ATTEMPTED=no
        RESTORE_KEEP_ROLLBACK=yes
        RESTORE_MUTATION_STARTED=yes
        RESTORE_LIVE_ROOT="${live}"
        RESTORE_ENV_FILE="${env_file}"
        RESTORE_ROLLBACK_DIR="${rollback}"

        restore_load_database()
        {
            return 0
        }

        printf 'destroyed\n' > "${live}/config/icon.txt"

        trap 'restore_on_exit' EXIT
        trap 'exit 143' TERM
        kill -TERM "${BASHPID}"
        sleep 2
    ) || status=$?

    [[ "${status}" -ne 0 ]] \
        || fail "SIGTERM during restore was reported as success."

    [[ -d "${rollback}" ]] \
        || fail "SIGTERM removed the rollback snapshot."

    [[ "$(cat "${live}/config/icon.txt")" == "original" ]] \
        || fail "SIGTERM left the destructive file change in place."

    rm -rf "${work}"

    ok "SIGTERM during the destructive phase kept the snapshot and restored the file."
}
