#!/usr/bin/env bash
#
# File: scripts/lib/deploy/stack.sh
#
# Description:
#   Synchronize the deployment stack with the Git repository.
#
#   This is the only synchronization implementation. init.sh uses the
#   same path guards for its first copy.
#
# Responsibilities:
#   - synchronize every path in DEPLOY_ITEMS
#   - remove files that were deleted from those Git paths
#   - leave runtime .env, .env.bak-*, DATA_DIR and backups untouched
#
# rsync --delete applies only inside a directory item
# (compose/ and configs/). It does not receive STACK_DIR as the
# destination root, so a sibling such as STACK_DIR/.env is outside
# the deletion set.
#
# If rsync fails, the script stops. It does not fall through to cp.
# The cp fallback runs only when the rsync command is not installed,
# and only after the destination has been checked to be one item
# inside STACK_DIR.

###############################################################################
# Refuse dangerous project paths
###############################################################################

assert_sync_paths()
{
    [[ -n "${GIT_DIR}" && -n "${STACK_DIR}" && -n "${STACKS_DIR}" \
        && -n "${DATA_DIR}" && -n "${STACK_NAME}" ]] \
        || fail "A project path is empty."

    [[ "${GIT_DIR}" == /* && "${STACK_DIR}" == /* && "${DATA_DIR}" == /* \
        && "${STACKS_DIR}" == /* ]] \
        || fail "Project paths must be absolute."

    [[ "${GIT_DIR}" != "/" && "${STACK_DIR}" != "/" \
        && "${DATA_DIR}" != "/" && "${STACKS_DIR}" != "/" ]] \
        || fail "Refusing to use '/' as a project path."

    [[ "${GIT_DIR}" != "${STACK_DIR}" ]] \
        || fail "GIT_DIR and STACK_DIR must be different directories."

    [[ "${STACK_DIR}" == "${STACKS_DIR}/${STACK_NAME}" ]] \
        || fail "STACK_DIR is not ${STACKS_DIR}/${STACK_NAME}."

    [[ "${STACK_DIR}" != "${DATA_DIR}" \
        && "${DATA_DIR}" != "${STACK_DIR}/"* \
        && "${STACK_DIR}" != "${DATA_DIR}/"* ]] \
        || fail "Persistent data must stay outside the runtime stack."

    [[ "${BACKUP_LOCAL_DIR}" != "${STACK_DIR}/"* \
        && "${STACK_DIR}" != "${BACKUP_LOCAL_DIR}/"* ]] \
        || fail "Backups must stay outside the runtime stack."

    ok "Sync paths OK."
}

###############################################################################
# Destination must be one child of the stack root
#
# Arguments:
#   $1 - Destination path
#   $2 - Stack root (defaults to STACK_DIR)
#
###############################################################################

sync_destination_is_safe()
{
    local dst="$1"
    local stack_root="${2:-${STACK_DIR}}"

    [[ -n "${dst}" && -n "${stack_root}" ]] || return 1
    [[ "${dst}" == /* && "${stack_root}" == /* ]] || return 1
    [[ "${dst}" != "/" && "${stack_root}" != "/" ]] || return 1
    [[ "${dst}" == "${stack_root}/"* ]] || return 1
    [[ "${dst}" != "${stack_root}" ]] || return 1
    [[ "${dst}" != *..* && "${stack_root}" != *..* ]] || return 1

    return 0
}

###############################################################################
# Synchronize one file or directory
#
# Arguments:
#   $1 - Source path
#   $2 - Destination path
#   $3 - Stack root used for the safety check
#
# A directory is copied with rsync -a --delete. Files that exist in the
# destination directory and no longer exist in the source are removed.
# A regular file is installed over the destination file only.
#
###############################################################################

sync_item_contents()
{
    local src="$1"
    local dst="$2"
    local stack_root="$3"

    [[ -e "${src}" ]] \
        || fail "Missing deployment item: ${src}"

    sync_destination_is_safe "${dst}" "${stack_root}" \
        || fail "Refusing to synchronize outside the stack: ${dst}"

    if [[ -d "${src}" ]]; then

        mkdir -p "${dst}"

        if command -v rsync >/dev/null 2>&1; then

            rsync -a --delete "${src}/" "${dst}/" \
                || fail "rsync failed for ${src}. No fallback copy was started."

        else

            rm -rf "${dst}"
            mkdir -p "${dst}"
            cp -a "${src}/." "${dst}/"

        fi

    else

        if command -v rsync >/dev/null 2>&1; then

            rsync -a "${src}" "${dst}" \
                || fail "rsync failed for ${src}. No fallback copy was started."

        else

            install -Dm644 "${src}" "${dst}"

        fi

    fi
}

###############################################################################
# Copy one deployment item with replacement
#
# Used by init.sh. Removes only the destination item inside the stack,
# then copies the Git item. Does not use rsync --delete and does not
# touch any other path.
#
# Arguments:
#   $1 - Source path
#   $2 - Destination path
#   $3 - Stack root
#
###############################################################################

sync_replace_item()
{
    local src="$1"
    local dst="$2"
    local stack_root="$3"

    [[ -e "${src}" ]] \
        || fail "Missing deployment item: ${src}"

    sync_destination_is_safe "${dst}" "${stack_root}" \
        || fail "Refusing to replace a path outside the stack: ${dst}"

    rm -rf "${dst}"
    cp -a "${src}" "${dst}"
}

###############################################################################
# Synchronize DEPLOY_ITEMS into STACK_DIR
###############################################################################

deploy_sync_stack()
{
    print_section "Synchronize stack"

    assert_sync_paths

    log_info "Synchronizing Authentik-netcup stack..."
    log_info "rsync --delete is limited to directory items inside ${STACK_DIR}."

    mkdir -p "${STACK_DIR}"

    local item
    local src
    local dst

    for item in "${DEPLOY_ITEMS[@]}"; do

        [[ "${item}" != /* && "${item}" != *..* && "${item}" != */* ]] \
            || fail "DEPLOY_ITEMS entry is not a single path name: ${item}"

        src="${GIT_DIR}/${item}"
        dst="${STACK_DIR}/${item}"

        sync_item_contents "${src}" "${dst}" "${STACK_DIR}"

        log_info "Synchronized ${item}"

    done

    log_success "Authentik-netcup stack synchronized."
}
